--- Numeric citation styles (`[1]`, nature, GB/T 7714, IEEE, Vancouver).
---
--- Zotero formats one item at a time through `/items?include=citation`, so for a
--- numeric style every citation comes back as "[1]" — the number carries no
--- meaning. Numbers have to come from *document order*, which only the document
--- knows, so this module owns them:
---
---   numbering(bufnr)      citekey -> N, by first appearance in the buffer
---   cluster_text(items)   "[1, 3–5]" for a cluster, ranges collapsed
---   bib_order(bufnr)      the zotkeys in citation order, for the reference list
---
--- Works on plain parsed groups (`cluster.json`), so it is fully testable.
local cfg = require("zotcite_extra.config")
local cluster = require("zotcite_extra.cluster")

local M = {}

--- Does Zotero's (style-specific) citation text look numeric? Author-date output
--- is "(Author, 2020)" / "Author (2020)", numeric output is "1", "[1]", "[1,2]".
--- @param text string
--- @return boolean
function M.is_numeric(text)
    if not text or text == "" then return false end
    local bracketed, digits = text:match("^%[%s*(%d+)%s*%]$"), text:match("^(%d+)$")
    if bracketed then return true end
    if not digits then return false end
    -- a bare four-digit "1990..2099" is a year (author-date year-only form),
    -- everything else is a citation number
    local n = tonumber(digits)
    return not (n and n >= 1900 and n <= 2099)
end

--- Collapse a sorted list of numbers into `1, 3–5, 9`.
--- `min_range` = how many consecutive numbers make a range (3 keeps `1, 2`).
--- @param nums integer[]
--- @param min_range? integer
--- @return string
function M.format_numbers(nums, min_range)
    min_range = min_range or 3
    local sorted, seen = {}, {}
    for _, n in ipairs(nums or {}) do
        if type(n) == "number" and not seen[n] then
            seen[n] = true
            sorted[#sorted + 1] = n
        end
    end
    table.sort(sorted)
    local parts, i = {}, 1
    while i <= #sorted do
        local first, last = sorted[i], sorted[i]
        local n = 1
        while i + n <= #sorted and sorted[i + n] == last + 1 do
            last = sorted[i + n]
            n = n + 1
        end
        if n >= min_range then
            parts[#parts + 1] = first .. "–" .. last
        else
            for k = i, i + n - 1 do parts[#parts + 1] = tostring(sorted[k]) end
        end
        i = i + n
    end
    return table.concat(parts, ", ")
end

--- Number every citekey of a buffer by first appearance, in document order.
--- @param bufnr? integer
--- @return table<string, integer> map
function M.numbering(bufnr)
    local render = require("zotcite_extra.render")
    local map, n = {}, 0
    for _, g in ipairs(render.collect(bufnr or 0)) do
        for _, k in ipairs(g.keys) do
            if not map[k] then
                n = n + 1
                map[k] = n
            end
        end
    end
    return map
end

--- Rendered text of one cluster in a numeric style.
--- Locators are appended to the numbers of the items that carry them.
--- @param items table[] parsed cluster items (see cluster.parse_body)
--- @param map table<string, integer>
--- @param opts? { bracket?: boolean, locator?: string }
--- @return string
function M.cluster_text(items, map, opts)
    opts = opts or {}
    if not items or #items == 0 then return "" end
    local conf = cfg.get().numeric or {}
    local nums, locs, n_locs = {}, {}, 0
    for _, it in ipairs(items) do
        local key = (it.key or ""):gsub("^%-", "")
        local n = map[key]
        if n then
            nums[#nums + 1] = n
            if it.locator and it.locator ~= "" then
                if not locs[n] then n_locs = n_locs + 1 end
                locs[n] = cluster.canon_locator(it.locator)
            end
        end
    end
    if #nums == 0 then return "" end
    local text = M.format_numbers(nums, conf.range)
    local suffixes, seen = {}, {}
    for _, n in ipairs(nums) do
        if locs[n] and not seen[n] then
            seen[n] = true
            suffixes[#suffixes + 1] = string.format("%d, %s", n, locs[n])
        end
    end
    -- a single item with a locator reads "[1, p. 3]"; several items keep the
    -- compact range form and append their locators
    if n_locs == 1 then
        -- one locator for the whole cluster: "[1, p. 3]" / "[1, 2, p. 3]"
        local only
        for _, l in pairs(locs) do only = l end
        text = text .. ", " .. only
    elseif n_locs > 1 then
        -- one locator per item: "[1, p. 3; 2, p. 9]"
        text = table.concat(suffixes, "; ")
    end
    local bracket = opts.bracket
    if bracket == nil then bracket = conf.bracket ~= false end
    if bracket then return "[" .. text .. "]" end
    return text
end

--- Citation order of the document, as zotkeys (for the reference list).
--- @param bufnr? integer
--- @return table[] { citekey = string, zotkey = string|nil } in citation order
function M.bib_order(bufnr)
    return require("zotcite_extra.biblio").cited_keys(bufnr)
end

--- Reference-list marker for entry `n` (e.g. "[1] " or "1. ").
--- @param n integer
--- @return string
function M.bib_marker(n)
    local conf = cfg.get().numeric or {}
    local fmt = conf.marker or "[%d] "
    local ok, out = pcall(string.format, fmt, n)
    return ok and out or (n .. ". ")
end

return M
