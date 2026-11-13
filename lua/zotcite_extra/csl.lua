--- CSL cluster assembly.
--- Faithful Lua port of `buildCitation()` from
--- zotero-quickcite-onlyoffice/scripts/citation-manager.js:
---   * parenthetical: Zotero's `/items?include=citation` output is used verbatim
---   * narrative: author part re-derived from the same CSL string ("&" -> "and")
---   * suppress-author (year only): year comes from the CSL string
---   * cluster auto-sorting (APA 7 §8.12 / Chicago §15.30)
---   * locator / prefix / suffix applied locally, exactly like the plugin
local cfg = require("zotcite_extra.config")
local api = require("zotcite_extra.api")

local M = {}

local function pad_year(s)
    return s
end

--- "p. 42" / "pp. 42-44", leaving explicit labels alone.
function M.format_locator(raw)
    if not raw then return "" end
    local loc = vim.trim(raw)
    if loc == "" then return "" end
    if loc:match("^[Pp][Pp]?%.") or loc:match("^[Cc]hap%.")
        or loc:match("^[Ss]ec%.") or loc:match("^[Pp]ara%.") then
        return loc
    end
    if loc:match("[%-%,]") or loc:match("%f[%a]to%f[%A]") then
        return "pp. " .. loc
    end
    return "p. " .. loc
end

--- Year as rendered by the style, taken from the formatted citation.
function M.year(item)
    local cit = item.citation or ""
    local y = cit:match("(%d%d%d%d%a?)") -- first 4-digit year in the CSL string
    if y then return y end
    local d = item.data and item.data.date or ""
    y = d:match("(%d%d%d%d)")
    return y or ""
end

local function first_creator(item)
    local d = item.data or {}
    local cr = d.creators
    if type(cr) == "table" and cr[1] then
        local c = cr[1]
        return vim.trim(c.lastName or c.name or ""), #cr
    end
    return "", 0
end

M.first_creator = first_creator

function M.author_label(item)
    local name, n = first_creator(item)
    if name == "" then
        local cit = item.citation or ""
        local inner = cit:gsub("^%p+", ""):gsub("%p+$", "")
        local a = inner:match("^(.-),%s*%d%d%d%d")
            or inner:match("^(.-)%s+%d%d%d%d")
            or inner
        return a
    end
    if n == 1 then return name end
    if n == 2 then
        local cr = (item.data or {}).creators
        local second = cr[2] or {}
        return name .. " & " .. vim.trim(second.lastName or second.name or "")
    end
    return name .. " et al."
end

--- Strip the surrounding parentheses/brackets of a CSL citation.
local function unwrap(text)
    local s = text or ""
    s = vim.trim(s)
    local a, b = s:sub(1, 1), s:sub(-1)
    if (a == "(" and b == ")") or (a == "[" and b == "]") then
        return vim.trim(s:sub(2, -2)), a
    end
    return s, nil
end

--- Narrative form: "<Author> (<year><, p. X>)".
function M.narrative(item, locator, prefix, suffix)
    local raw = unwrap(item.citation or "")
    local author, year = raw:match("^(.-),%s*(%d%d%d%d%a?)$")
    if not author then author, year = raw:match("^(.-):%s*(%d%d%d%d%a?)$") end
    if not author then author, year = raw:match("^(.-)%s+(%d%d%d%d%a?)$") end
    if not author then
        author, year = raw, M.year(item)
    end
    author = vim.trim(author):gsub("%s*&%s*", " and ") -- APA 7 §8.11

    local in_paren = year or ""
    if locator and locator ~= "" then
        in_paren = in_paren .. (in_paren ~= "" and ", " or "") .. M.format_locator(locator)
    end
    if suffix and suffix ~= "" then
        in_paren = in_paren .. (suffix:sub(1, 1) == "," and "" or " ") .. vim.trim(suffix)
    end
    local full = author .. (in_paren ~= "" and (" (" .. in_paren .. ")") or "")
    if prefix and prefix ~= "" then
        full = vim.trim(prefix) .. " " .. full
    end
    return full, author, year
end

local function cmp_items(a, b)
    local an = M.first_creator(a):lower()
    local bn = M.first_creator(b):lower()
    if an ~= bn then return an < bn end
    local ay = tonumber(M.year(a)) or 0
    local by = tonumber(M.year(b)) or 0
    if ay ~= by then return ay < by end
    local at = ((a.data or {}).title or ""):lower()
    local bt = ((b.data or {}).title or ""):lower()
    return at < bt
end

--- Build the formatted citation text for a cluster.
--- @param items table[] item records from zotcite_extra.api
--- @param opts { mode?: "parenthetical"|"narrative"|"suppress", locator?: string, prefix?: string, suffix?: string, sort?: boolean }
--- @return { text: string, mode: string, items: table[], author?: string, year?: string }
function M.build(items, opts)
    opts = opts or {}
    local o = cfg.get()
    local mode = opts.mode or "parenthetical"
    local locator = vim.trim(opts.locator or "")
    local prefix = opts.prefix or ""
    local suffix = opts.suffix or ""
    items = items or {}

    if #items == 0 then
        return { text = "", mode = mode, items = {} }
    end

    local cluster = {}
    for i, it in ipairs(items) do
        local c = vim.deepcopy(it)
        if i == 1 then
            c.locator = locator
            c.prefix = prefix
            c.suffix = suffix
        end
        table.insert(cluster, c)
    end

    local sort = opts.sort
    if sort == nil then sort = o.sort_cluster end
    if mode ~= "narrative" and #cluster > 1 and sort then
        table.sort(cluster, cmp_items)
    end

    if mode == "narrative" then
        local text, author, year = M.narrative(cluster[1], locator, prefix, suffix)
        local rest = {}
        for i = 2, #cluster do
            table.insert(rest, M.build({ cluster[i] }, { mode = "parenthetical", sort = false }).text)
        end
        if #rest > 0 then text = text .. "; " .. table.concat(rest, "; ") end
        return { text = text, mode = mode, items = cluster, author = author, year = year }
    end

    if mode == "suppress" then
        local parts = {}
        for _, it in ipairs(cluster) do
            local y = M.year(it)
            if it.locator and it.locator ~= "" then
                y = y .. ", " .. M.format_locator(it.locator)
            end
            if it.prefix and it.prefix ~= "" then
                y = vim.trim(it.prefix) .. " " .. y
            end
            if it.suffix and it.suffix ~= "" then
                y = y .. (it.suffix:sub(1, 1) == "," and "" or " ") .. vim.trim(it.suffix)
            end
            table.insert(parts, y)
        end
        return { text = "(" .. table.concat(parts, "; ") .. ")", mode = mode, items = cluster }
    end

    -- parenthetical: Zotero's CSL output, reassembled
    local numeric = false
    local parts = {}
    for _, it in ipairs(cluster) do
        local cit = it.citation or ""
        if cit:sub(1, 1) == "[" then numeric = true end
        local inner = unwrap(cit)
        if inner == "" then inner = M.author_label(it) end
        if it.prefix and it.prefix ~= "" then
            inner = vim.trim(it.prefix) .. " " .. inner
        end
        if it.locator and it.locator ~= "" then
            inner = inner .. ", "
                .. (numeric and vim.trim(it.locator) or M.format_locator(it.locator))
        end
        if it.suffix and it.suffix ~= "" then
            inner = inner .. (it.suffix:sub(1, 1) == "," and "" or " ") .. vim.trim(it.suffix)
        end
        table.insert(parts, inner)
    end
    local text
    if numeric then
        text = "[" .. table.concat(parts, ", ") .. "]"
    else
        text = "(" .. table.concat(parts, "; ") .. ")"
    end
    return { text = text, mode = mode, items = cluster }
end

--- Build straight from Zotero keys: fetch, assemble, return both text and items.
function M.build_from_keys(zkeys, opts)
    local items = api.items(zkeys, { style = opts and opts.style })
    if #items == 0 then return nil, "Zotero returned no items for: " .. table.concat(zkeys, ",") end
    local res = M.build(items, opts)
    res.raw_items = items
    return res
end

return M
