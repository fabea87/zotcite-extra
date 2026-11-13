--- Pandoc citation cluster parsing / rewriting.
--- The ONLYOFFICE plugin manipulates an invisible `ADDIN ZOTERO_ITEM` field;
--- here the equivalent document object is the pandoc citation itself:
---   [@key]            parenthetical
---   @key              in-text (narrative)
---   [-@key]           suppress-author
---   [see @k1, p. 3; @k2, for a review]
--- so every mode/prefix/suffix/locator operation is a pure text rewrite.
local M = {}

local KEY = "[%w][%w%p]-"
local function is_key_char(c)
    return c:match("^[%w_%-:%.%+%/]$") ~= nil
end

--- Parse one item chunk, e.g. "-@smith2020, p. 3" or "@doe99, for a review".
local function parse_item(chunk)
    chunk = vim.trim(chunk)
    if chunk == "" then return nil end
    local i = chunk:find("%-?@%s*[%w_%-:%.%+%/]")
    if not i then return nil end
    local suppress = chunk:sub(i, i) == "-"
    local prefix = vim.trim(chunk:sub(1, i - 1))
    -- tolerate a sloppy paste ("[@ key]"): allow blanks after the sigil
    local key, rest = chunk:sub(i + (suppress and 2 or 1)):match("^%s*([%w_%-:%.%+%/]+)(.*)$")
    if not key then return nil end
    rest = vim.trim(rest or "")
    if rest:sub(1, 1) == "," then rest = vim.trim(rest:sub(2)) end

    local locator, suffix = nil, nil
    if rest ~= "" then
        local head, tail = rest:match("^([^,]*)(.*)$")
        head = vim.trim(head)
        tail = vim.trim(tail)
        if tail:sub(1, 1) == "," then tail = vim.trim(tail:sub(2)) end
        if head:match("^%.*[Pp][Pp]?j?%.?%s*[%d%ivxlcIVXLCnN%-–—]+$")
            or head:match("^[%d%-–—]+$")
            or head:match("^[Cc]h%.")
            or head:match("^[Ss]ec%.")
            or head:match("^[Pp]ara?%.")
            or head:match("^[Vv]ol%.")
            or head:match("^[Cc]hap%.") then
            locator = head
            suffix = tail ~= "" and tail or nil
        else
            suffix = rest
        end
    end
    return {
        key = key,
        suppress = suppress,        prefix = prefix ~= "" and prefix or nil,
        locator = locator,
        suffix = suffix,
    }
end

M.parse_item = parse_item

--- Split a cluster body on top-level semicolons.
local function split_semicolons(body)
    local out, depth, cur = {}, 0, {}
    local i = 1
    while i <= #body do
        local c = body:sub(i, i)
        if c == "{" then
            depth = depth + 1
        elseif c == "}" then
            depth = depth - 1
        end
        if c == ";" and depth == 0 then
            table.insert(out, table.concat(cur))
            cur = {}
        else
            table.insert(cur, c)
        end
        i = i + 1
    end
    table.insert(out, table.concat(cur))
    return out
end

--- Parse a citation group body (without the brackets).
function M.parse_body(body)
    local items, prefix = {}, nil
    for _, chunk in ipairs(split_semicolons(body)) do
        local it = parse_item(chunk)
        if it then
            if not prefix and it.prefix then prefix = it.prefix end
            table.insert(items, it)
        end
    end
    return items, prefix
end

--- Find the citation group that contains (or touches) the cursor.
--- @param line string
--- @param col integer 0-based byte column
--- @return nil|{ start: integer, ["end"]: integer, bracketed: boolean, body: string, from: integer, to: integer }
function M.group_at(line, col)
    -- 1) bracketed group: find an unmatched '[' before col and its ']'
    local search_end = math.min(#line, col + 1)
    local open
    local depth = 0
    local i = search_end
    while i >= 1 do
        local c = line:sub(i, i)
        if c == "]" then
            depth = depth + 1
        elseif c == "[" then
            if depth == 0 then
                open = i
                break
            end
            depth = depth - 1
        end
        i = i - 1
    end
    if open then
        local close
        depth = 0
        for j = open, #line do
            local c = line:sub(j, j)
            if c == "[" then
                depth = depth + 1
            elseif c == "]" then
                depth = depth - 1
                if depth == 0 then
                    close = j
                    break
                end
            end
        end
        if close and close >= col + 1 and close > open + 1 then
            local body = line:sub(open + 1, close - 1)
            if body:match("%-?@%s*[%w_%-]") then
                return {
                    start = open,
                    ["end"] = close,
                    bracketed = true,
                    body = body,
                    from = open + 1,
                    to = close - 1,
                }
            end
        end
    end

    -- 2) bare in-text citation "@key" (pandoc narrative form)
    local at = col + 1
    if line:sub(at, at) ~= "@" then
        -- cursor is inside the key: walk back to its sigil
        local i = at
        while i >= 1 and is_key_char(line:sub(i, i)) do i = i - 1 end
        at = i
    end
    if at >= 1 and line:sub(at, at) == "@" then
        local e = at + 1
        while e <= #line and is_key_char(line:sub(e, e)) do e = e + 1 end
        if e > at + 1 then
            local key = line:sub(at + 1, e - 1)
            local suppress = at > 1 and line:sub(at - 1, at - 1) == "-"
            local start = suppress and at - 1 or at
            -- swallow a trailing pandoc locator: @key [p. 3]
            local tail = line:sub(e):match("^%s*%[[^%]]*%]")
            local locator_hint = tail and tail:match("^%s*%[(.-)%]$") or nil
            local close = tail and (e + #tail - 1) or (e - 1)
            return {
                start = start,
                ["end"] = close,
                bracketed = false,
                body = (suppress and "-" or "") .. "@" .. key,
                from = at,
                to = e - 1,
                tail = tail,
                locator_hint = locator_hint,
            }
        end
    end
    return nil
end

--- Parsed items of a group, with a bare `@key [p. 3]` locator folded in.
function M.items_of(group)
    local items = M.parse_body(group.body)
    if group.locator_hint and items[1] and (not items[1].locator or items[1].locator == "") then
        items[1].locator = group.locator_hint
    end
    return items
end

--- Citation group containing the cursor, or the nearest one on the line.
--- Being anywhere on the citation's line is enough (paragraph-level UX).
function M.nearest(line, col)
    local g = M.group_at(line, col)
    if g then return g end
    local best, bestd
    for _, cand in ipairs(M.groups_on_line(line)) do
        local d
        if col + 1 < cand.start then
            d = cand.start - (col + 1)
        elseif col + 1 > cand["end"] then
            d = (col + 1) - cand["end"]
        else
            d = 0
        end
        if not bestd or d < bestd then best, bestd = cand, d end
    end
    return best
end

--- Every citation group on a line (for rendering).
function M.groups_on_line(line)
    local out = {}
    local i = 1
    while i <= #line do
        local c = line:sub(i, i)
        if c == "@" and (i == 1 or not is_key_char(line:sub(i - 1, i - 1))) then
            local g = M.group_at(line, i - 1)
            if g then
                table.insert(out, g)
                i = g["end"] + 1
            else
                i = i + 1
            end
        elseif c == "[" then
            local g = M.group_at(line, i)
            if g and g.start == i then
                table.insert(out, g)
                i = g["end"] + 1
            else
                i = i + 1
            end
        else
            i = i + 1
        end
    end
    return out
end

--- Render the parsed items back to pandoc markdown.
--- The bracketed/bare distinction is driven by `mode`, so the same rewrite
--- path handles (Author, 2020) -> Author (2020) -> (2020) and back.
--- @param group table parsed group (unused except for the tail hint)
--- @param items table[] { key, suppress, locator, suffix, prefix }
--- @param mode "parenthetical"|"narrative"|"suppress"
function M.render(group, items, mode)
    if #items == 0 then return "" end

    local function item_text(it, first)
        local sigil = (it.suppress and not (mode == "narrative" and first)) and "-" or ""
        local k = sigil .. "@" .. it.key
        local tail = {}
        if first and not (mode == "narrative") and it.prefix and it.prefix ~= "" then
            k = it.prefix .. " " .. k
        end
        if it.locator and it.locator ~= "" then
            table.insert(tail, it.locator)
        end
        if first and not (mode == "narrative") and it.suffix and it.suffix ~= "" then
            table.insert(tail, it.suffix)
        end
        if #tail == 0 then return k end
        return k .. ", " .. table.concat(tail, ", ")
    end

    if mode == "narrative" then
        local first = items[1]
        local text = "@" .. first.key
        if first.prefix and first.prefix ~= "" then
            text = first.prefix .. " " .. text
        end
        if first.locator and first.locator ~= "" then
            text = text .. " [" .. first.locator .. "]"
        end
        local rest = {}
        for i = 2, #items do
            table.insert(rest, item_text(items[i], false))
        end
        if #rest > 0 then
            text = text .. "; [" .. table.concat(rest, "; ") .. "]"
        end
        if first.suffix and first.suffix ~= "" then
            text = text .. ", " .. first.suffix
        end
        return text
    end

    local parts = {}
    for i, it in ipairs(items) do
        table.insert(parts, item_text(it, i == 1))
    end
    return "[" .. table.concat(parts, "; ") .. "]"
end

--- Canonical form of one line's citations: `[@a;@b]` -> `[@a; @b]`, `[@ a]` ->
--- `[@a]`, `@key [p.3]` -> `@key [p. 3]`, `[@a,p.3]` -> `[@a, p. 3]`, and every
--- group re-rendered through `M.render` so the shape never drifts.
--- @param line string
--- @return string line, integer changed  (changed = number of groups rewritten)
local function canon_locator(loc)
    if not loc or loc == "" then return loc end
    loc = vim.trim(loc)
    -- "p.3" -> "p. 3", "pp .3" -> "pp. 3"; numeric ranges get an en dash
    loc = loc:gsub("^(%a+)%s*%.?%s*(%d)", function(w, n) return w .. ". " .. n end)
    loc = loc:gsub("(%d)%s*[%-–—]%s*(%d)", "%1–%2")
    return loc
end

M.canon_locator = canon_locator

function M.normalize_line(line)
    local groups = M.groups_on_line(line)
    if #groups == 0 then return line, 0 end
    local out, pos, changed = {}, 1, 0
    for _, g in ipairs(groups) do
        local items = M.items_of(g)
        if #items == 0 and g.bracketed then
            -- sloppy paste like "[@ key ]": close the gap and try again
            items = M.parse_body((g.body:gsub("@%s+", "@")))
        end
        if #items > 0 then
            for _, it in ipairs(items) do it.locator = canon_locator(it.locator) end
            local mode = M.mode_of(g, items)
            local text = M.render(g, items, mode)
            out[#out + 1] = line:sub(pos, g.start - 1)
            if text ~= line:sub(g.start, g["end"]) then changed = changed + 1 end
            out[#out + 1] = text
            pos = g["end"] + 1
        else
            out[#out + 1] = line:sub(pos, g["end"])
            pos = g["end"] + 1
        end
    end
    out[#out + 1] = line:sub(pos)
    return table.concat(out), changed
end

--- Mode of a parsed group.
function M.mode_of(group, items)
    if not group.bracketed then return "narrative" end
    if #items == 1 and items[1].suppress then return "suppress" end
    return "parenthetical"
end

return M
