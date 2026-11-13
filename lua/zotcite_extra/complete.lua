--- Completion for citekeys: plain insert-mode completion, no LSP in the loop.
---
--- Two facts made the LSP route a dead end: nvim does not open insert-mode
--- completion for `@` (not a keyword character) unless you opt in, and
--- zotcite's server answers with the *whole* library (438 items) expecting the
--- client to filter — nvim's built-in menu does not. zotcite's own sqlite
--- layer is faster and already carries author/year/title, so the candidates
--- come from there and we filter + rank ourselves.
local M = {}

local cache = {} -- bufnr -> { time, records }
local TTL = 10000

--- All records of the library (cached per buffer for TTL), for the picker's
--- fuzzy sorter: filtering is the picker's job, not the sqlite query's.
--- @return table[] zotcite records
function M.records(bufnr, force)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local hit = cache[bufnr]
    if not force and hit and (vim.uv.now() - hit.time) < TTL then return hit.records end
    local data = require("zotcite_extra.data")
    data.ensure()
    local ok, zot = pcall(require, "zotcite.zotero")
    local list = {}
    if ok then
        local ok2, res = pcall(zot.get_match, "", vim.api.nvim_buf_get_name(bufnr))
        if ok2 and type(res) == "table" then list = res end
    end
    cache[bufnr] = { time = vim.uv.now(), records = list }
    return list
end

--- Author (Year) label for a zotcite record.
local function label(rec)
    local ok, data = pcall(require, "zotcite_extra.data")
    if ok then return data.label(rec) end
    return rec.citekey or ""
end

--- Characters that may appear in a citekey as we scan `@token`.
--- Deliberately narrow: a trailing `.` or `,` belongs to the sentence, not to
--- the key, so it must survive the picker.
local function is_key_char(c)
    if c == "" then return false end
    if c:byte() > 127 then return true end
    return c:match("^[%w_%-]$") ~= nil
end

--- The `@token` the cursor sits in (or right after), as typed.
--- Deliberately more permissive than zotcite's own scanner, which only walks
--- back over lowercase ASCII: `@Ted`, `@pan2020`, `@pan-dero` and `@Pan_20`
--- have to be recognised too, otherwise the picker leaves the tail behind.
--- @param line? string
--- @param col? integer 0-based byte column (insert mode: one past the last char)
--- @param row? integer 1-based row, for the returned descriptor
--- @return nil|{ text: string, start0: integer, end0: integer, at0: integer, row: integer }
function M.token(line, col, row)
    line = line or vim.api.nvim_get_current_line()
    col = col or vim.api.nvim_win_get_cursor(0)[2]
    row = row or vim.api.nvim_win_get_cursor(0)[1]
    -- walk back to the `@`
    local i = col
    while i >= 1 and is_key_char(line:sub(i, i)) do i = i - 1 end
    if i < 1 or line:sub(i, i) ~= "@" then return nil end
    -- an `@` glued to a word is an email, not a citation
    if i > 1 and is_key_char(line:sub(i - 1, i - 1)) then return nil end
    -- walk forward as well: the cursor may sit inside the token
    local e = col + 1
    while e <= #line and is_key_char(line:sub(e, e)) do e = e + 1 end
    return {
        text = line:sub(i + 1, e - 1),
        start0 = i - 1, -- 0-based offset of the `@`
        end0 = e - 1,   -- 0-based, exclusive: end of the typed tail
        at0 = i - 1,
        row = row,
    }
end

--- Ranked candidates for a typed base (the text after `@`).
function M.matches(base, bufnr, limit)
    limit = limit or 200
    local needle = (base or ""):gsub("^@", ""):lower()
    local p1, p2, p3, p4 = {}, {}, {}, {}
    for _, rec in ipairs(M.records(bufnr)) do
        local key = (rec.citekey or ""):lower()
        if key ~= "" then
            local authors = ""
            if type(rec.alastnm) == "table" then
                authors = (rec.alastnm[1] or ""):lower()
            elseif type(rec.alastnm) == "string" then
                authors = rec.alastnm:lower()
            end
            local title = (rec.title or ""):lower()
            local entry = { word = rec.citekey, abbr = label(rec), menu = "[zotero]", icase = 1 }
            if needle == "" then
                p1[#p1 + 1] = entry
            elseif key:sub(1, #needle) == needle then
                p1[#p1 + 1] = entry
            elseif authors:sub(1, #needle) == needle then
                p2[#p2 + 1] = entry
            elseif title:sub(1, #needle) == needle then
                p3[#p3 + 1] = entry
            elseif key:find(needle, 1, true) or authors:find(needle, 1, true)
                or title:find(needle, 1, true) then
                p4[#p4 + 1] = entry
            end
        end
    end
    local out = {}
    for _, tier in ipairs({ p1, p2, p3, p4 }) do
        for _, e in ipairs(tier) do
            if #out >= limit then return out end
            out[#out + 1] = e
        end
    end
    return out
end

--- omnifunc: start right after the `@`, then hand back filtered candidates.
function M.omnifunc(findstart, base)
    if findstart == 1 then
        local tok = M.token()
        -- start *after* the @ so accepting a candidate keeps it
        if tok then return tok.start0 + 1 end
        local line = vim.api.nvim_get_current_line()
        local col = vim.api.nvim_win_get_cursor(0)[2]
        local word = line:sub(1, col):match(".*()%W")
        return word or col
    end
    return M.matches(base)
end

function M.invalidate(bufnr)
    if bufnr then
        cache[bufnr] = nil
    else
        cache = {}
    end
end

return M
