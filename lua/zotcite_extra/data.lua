--- Bridge to zotcite's Zotero database layer.
--- All access goes through zotcite's public functions; when zotcite is not
--- loaded we degrade to Zotero's HTTP quick search.
local M = {}

local warned = false

local function zotero_mod()
    local ok, mod = pcall(require, "zotcite.zotero")
    if ok and mod then return mod end
    if not warned then
        warned = true
        vim.notify("[zotcite-extra] zotcite.zotero unavailable: key resolution disabled",
            vim.log.levels.WARN)
    end
    return nil
end

local loaded = false

--- Make sure zotcite has actually read Zotero's database.
--- zotcite loads it from a scheduled `global_init`; depending on how nvim is
--- started (and on lazy.nvim's load order) that may not have happened yet, in
--- which case every lookup silently returns nothing.
function M.ensure()
    local mod = zotero_mod()
    if not mod then return false end
    if loaded then return true end
    local ok, map = pcall(mod.get_all_citations)
    if not ok or type(map) ~= "table" or next(map) == nil then
        pcall(mod.init)
    end
    loaded = true
    return true
end

--- Is zotcite's database loaded and non-empty? Loads it if necessary.
function M.ready()
    local mod = zotero_mod()
    if not mod then return false end
    M.ensure()
    local ok, map = pcall(mod.get_all_citations)
    return ok and type(map) == "table" and next(map) ~= nil
end

--- citekey (as written in the document) -> full zotcite record (has .zotkey)
function M.by_citekey(citekey)
    M.ensure()
    local mod = zotero_mod()
    if not mod then return nil end
    local ok, rec = pcall(mod.get_ref_data, citekey)
    if ok then return rec end
    return nil
end

--- Zotero item key for a citekey.
function M.zotkey(citekey)
    M.ensure()
    local rec = M.by_citekey(citekey)
    if rec and rec.zotkey then return rec.zotkey end
    if citekey:match("^[0-9A-Za-z]+$") and #citekey > 8 then return nil end
    -- last resort: assume the author used bare Zotero keys
    if citekey:match("^[0-9A-Z]%w+$") and #citekey <= 12 then return citekey end
    return nil
end

--- citekey for a Zotero item key.
function M.citekey(zotkey)
    M.ensure()
    local mod = zotero_mod()
    if mod then
        local ok, map = pcall(mod.get_all_citations)
        if ok and type(map) == "table" then
            for k, v in pairs(map) do
                if v == zotkey and k ~= zotkey then return k end
                if k == zotkey then return k end
            end
        end
    end
    return zotkey
end

--- Candidate references for a search string, as zotcite records.
function M.search(pattern)
    M.ensure()
    local mod = zotero_mod()
    if mod and M.ready() then
        local ok, list = pcall(mod.get_match, pattern, vim.api.nvim_buf_get_name(0))
        if ok and type(list) == "table" and #list > 0 then return list, "zotcite" end
    end
    return nil, "none"
end

--- Normalised creator list for a zotcite record (zotcite stores
--- `author = {{last, first}, …}`, but some records only carry a string).
function M.creators(rec)
    local cr = rec and rec.author
    if type(cr) ~= "table" then return nil end
    local out = {}
    for _, a in ipairs(cr) do
        if type(a) == "table" then
            out[#out + 1] = { lastName = a[1], firstName = a[2] }
        elseif type(a) == "string" then
            out[#out + 1] = { lastName = a }
        end
    end
    return #out > 0 and out or nil
end

--- Display line for a zotcite record.
function M.label(rec)
    local authors = ""
    if type(rec.alastnm) == "table" then
        authors = table.concat(rec.alastnm, " & ")
    elseif type(rec.alastnm) == "string" then
        authors = rec.alastnm
    end
    if authors == "" and type(rec.author) == "table" and rec.author[1] then
        authors = #rec.author == 1 and rec.author[1][1]
            or (rec.author[1][1] .. (#rec.author == 2 and " & " or " et al."))
    end
    local year = ""
    if rec.date then year = tostring(rec.date):match("(%d%d%d%d)") or "" end
    if year == "" then
        local d = rec.issued and rec.issued["date-parts"]
        if d and d[1] then year = tostring(d[1][1] or "") end
    end
    local title = rec.title or ""
    return string.format("%s (%s) %s", authors, year, title)
end

--- Convert a zotcite record to the { key, citation, data } shape used by csl.lua.
function M.to_item(rec, citation)
    return {
        key = rec.zotkey,
        citation = citation or "",
        bbt = rec.citekey,
        data = {
            itemType = rec.etype,
            title = rec.title,
            date = rec.date,
            creators = M.creators(rec),
        },
    }
end

return M
