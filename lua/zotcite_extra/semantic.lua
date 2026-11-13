--- Semantic search inside Zotero, through the ZotSeek plugin.
---
--- ZotSeek (introfini/zotseek) indexes the library with embeddings and — with
--- `zotseek.mcpServer.enabled = true` — exposes read-only endpoints on Zotero's
--- own local server:
---   GET /zotseek/stats                      index status
---   GET /zotseek/search?q=…&topK=&minSimilarity=   hybrid semantic+keyword hits
--- Results carry `itemKey` (Zotero key), title/authors/year, `semanticScore`,
--- `keywordScore`, `source`, a matched chunk snippet and `zotero://` links.
---
--- This module is deliberately thin: query, map to picker entries, cache stats.
local cfg = require("zotcite_extra.config")

local M = {}

local stats_cache

--- Semantic search settings.
local function opts()
    return cfg.get().semantic or {}
end

--- Is the user asking for it? (`semantic = { enabled = false }` switches it off)
function M.enabled()
    return opts().enabled ~= false
end

--- ZotSeek's index status (`/zotseek/stats`), cached for a minute.
--- nil when ZotSeek is not installed / the endpoint is off.
--- @param force? boolean
--- @return table?
function M.stats(force)
    if not M.enabled() then return nil end
    local now = vim.uv.now()
    if not force and stats_cache and (now - stats_cache.time) < 60000 then
        return stats_cache.data ~= false and stats_cache.data or nil
    end
    local api = require("zotcite_extra.api")
    local data = api.endpoint_json("/zotseek/stats", 4000)
    stats_cache = { time = now, data = data or false }
    return data
end

--- Can we search semantically right now? (ZotSeek installed, index non-empty)
--- @return boolean, string? reason
function M.available()
    if not M.enabled() then return false, "semantic search is disabled in the config" end
    local s = M.stats()
    if not s then return false, "ZotSeek is not reachable (is zotseek.mcpServer.enabled on?)" end
    if s.ready ~= true then return false, "ZotSeek index is not ready" end
    if (s.indexedPapers or 0) == 0 then return false, "ZotSeek has indexed no papers yet" end
    return true
end

--- Index summary for :ZPing / the picker footer.
--- @return string
function M.status_line()
    local s = M.stats()
    if not s then return "semantic: unavailable" end
    return string.format("semantic: %s, %d papers (%s)", s.ready and "ready" or "not ready",
        s.indexedPapers or 0, tostring(s.modelId or "?"))
end

--- Collapse whitespace (abstracts/snippets contain hard line breaks).
local function one_line(s)
    return (tostring(s or ""):gsub("%s+", " "))
end

--- Map one ZotSeek result to a picker entry.
--- Pure function: `resolve` turns a Zotero key into a citekey (data.citekey).
--- @param r table ZotSeek result
--- @param resolve? fun(zotkey: string): string?
--- @return table|nil entry, boolean unresolved
function M.to_entry(r, resolve)
    if type(r) ~= "table" then return nil, false end
    local zotkey = r.itemKey or (r.links and r.links.select or ""):match("items/(%w+)")
    if not zotkey or zotkey == "" then return nil, false end
    local citekey = resolve and resolve(zotkey) or nil
    local unresolved = false
    if not citekey or citekey == "" or citekey == zotkey then
        citekey = zotkey
        unresolved = true
    end
    local authors = one_line(r.authors)
    local year = r.year and tostring(r.year) or ""
    local title = one_line(r.title)
    local score = tonumber(r.semanticScore) or tonumber(r.score) or 0
    local chunk = r.matchedChunk
    if type(chunk) ~= "table" then chunk = {} end
    return {
        citekey = citekey,
        zotkey = zotkey,
        authors = authors,
        year = year,
        title = title,
        score = score,
        keyword_score = tonumber(r.keywordScore),
        source = r.source or "",
        snippet = chunk.snippet and one_line(chunk.snippet) or nil,
        page = chunk.page,
        semantic = true,
        unresolved = unresolved,
        -- ZotSeek hands us ready-made links, including the PDF page of the match
        open_pdf = r.links and r.links.openPdf or nil,
        open_http = r.links and r.links.openPdfHttp or nil,
        select_uri = r.links and r.links.select or nil,
        line = string.format("%s (%s) %s", authors, year, title),
    }, unresolved
end

--- Turn a `/zotseek/search` payload into picker entries (pure).
--- @param payload table decoded JSON
--- @param resolve? fun(zotkey: string): string?
--- @return table[] entries, string[] unresolved keys
function M.parse(payload, resolve)
    local out, unresolved, seen = {}, {}, {}
    for _, r in ipairs((payload and payload.results) or {}) do
        local e, bad = M.to_entry(r, resolve)
        -- one row per *item*: two library items may share a citekey
        if e and not seen[e.zotkey] then
            seen[e.zotkey] = true
            out[#out + 1] = e
            if bad then unresolved[#unresolved + 1] = e.zotkey end
        end
    end
    return out, unresolved
end

--- Resolve Zotero keys to citekeys + display fields with *one* HTTP request.
--- (Per-hit `zotcite.zotero.get_ref_data` would spawn one sqlite query each.)
--- @param zotkeys string[]
--- @return table<string, { citekey: string?, authors: string?, year: string? }>
local function lookup(zotkeys)
    local api = require("zotcite_extra.api")
    local out = {}
    if #zotkeys == 0 then return out end
    local ok, items = pcall(api.items, zotkeys)
    if not ok or type(items) ~= "table" then return out end
    for _, it in ipairs(items) do
        local d = it.data or {}
        local authors = ""
        if type(d.creators) == "table" and d.creators[1] then
            local names = {}
            for i, c in ipairs(d.creators) do
                names[i] = c.lastName or c.name or ""
                if i >= 3 then break end
            end
            authors = #d.creators > 2 and (names[1] .. " et al.") or table.concat(names, " & ")
        end
        out[it.key] = {
            citekey = it.bbt,
            authors = authors ~= "" and authors or nil,
            year = (tostring(d.date or ""):match("(%d%d%d%d)")) or nil,
        }
    end
    return out
end

--- Items similar to `zotkey` (`/zotseek/similar`), i.e. literature snowballing
--- from the citation under the cursor. Metadata (authors, year) comes from the
--- local database, so the rows look like semantic-search rows.
--- @param zotkey string
--- @param o? { top_k?: integer, min_similarity?: number }
--- @return table[]|nil entries, string? err
function M.similar(zotkey, o)
    o = o or {}
    if not zotkey or zotkey == "" then return nil, "no item" end
    local avail, why = M.available()
    if not avail then return nil, why end
    local api = require("zotcite_extra.api")
    local conf = opts()
    local top_k = o.top_k or conf.top_k or 25
    local min = o.min_similarity or conf.min_similarity or 0.3
    local path = string.format("/zotseek/similar?itemKey=%s&topK=%d&minSimilarity=%s",
        api.urlencode(zotkey), math.floor(top_k), tostring(min))
    local payload, err = api.endpoint_json(path, 15000)
    if not payload then return nil, err end
    local keys = {}
    for _, r in ipairs(payload.results or {}) do
        if r.itemKey then keys[#keys + 1] = r.itemKey end
    end
    local meta = lookup(keys)
    local out = {}
    for _, r in ipairs(payload.results or {}) do
        local m = meta[r.itemKey] or {}
        local e = M.to_entry({
            itemKey = r.itemKey, title = r.title,
            authors = m.authors, year = m.year,
            score = r.score, semanticScore = r.score, source = "similar",
            matchedChunk = r.matchedChunk, links = r.links,
        }, function() return m.citekey end)
        if e then out[#out + 1] = e end
    end
    return out
end

--- Small per-session cache: the picker re-queries on every prompt pause.
local query_cache = {}

--- Semantic search for `prompt`.
--- @param prompt string
--- @param o? { top_k?: integer, min_similarity?: number, library?: string,
---             mode?: "semantic"|"hybrid"|"keyword", bypass_cache?: boolean }
--- @return table[]|nil entries, string? err
function M.query(prompt, o)
    o = o or {}
    prompt = vim.trim(prompt or "")
    if #prompt < 2 then return {} end
    local api = require("zotcite_extra.api")
    local ok = M.available()
    if not ok then return nil, "ZotSeek is not available" end
    local conf = opts()
    local top_k = o.top_k or conf.top_k or 40
    local min = o.min_similarity or conf.min_similarity or 0.3
    local mode = o.mode or conf.mode or "semantic"
    local path = string.format("/zotseek/search?q=%s&topK=%d&minSimilarity=%s&mode=%s",
        api.urlencode(prompt), math.floor(top_k), tostring(min), mode)
    if o.library and o.library ~= "" then path = path .. "&library=" .. api.urlencode(o.library) end
    local key = path
    if not o.bypass_cache and query_cache[key] then return query_cache[key] end
    local payload, err = api.endpoint_json(path, 20000)
    if not payload then return nil, err end
    local keys = {}
    for _, r in ipairs(payload.results or {}) do
        if r.itemKey then keys[#keys + 1] = r.itemKey end
    end
    local meta = lookup(keys)
    local entries, unresolved = M.parse(payload, function(zotkey)
        local m = meta[zotkey]
        return m and m.citekey or nil
    end)
    for _, e in ipairs(entries) do
        local m = meta[e.zotkey]
        if m then
            if m.authors and m.authors ~= "" then e.authors = m.authors end
            if m.year and m.year ~= "" then e.year = m.year end
            e.line = string.format("%s (%s) %s", e.authors, e.year, e.title)
        end
    end
    if #unresolved > 0 then
        vim.notify(string.format("[zotcite-extra] %d semantic hit(s) have no citekey (missing"
            .. " in better-bibtex?): %s", #unresolved, table.concat(unresolved, ", ")),
            vim.log.levels.INFO)
    end
    query_cache[key] = entries
    return entries
end

return M
