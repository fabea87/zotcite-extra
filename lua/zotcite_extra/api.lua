--- Zotero Desktop local HTTP API client.
--- Mirrors `scripts/zotero-api.js` of zotero-quickcite-onlyoffice:
---   * Zotero's own CSL output is the single source of truth for formatting
---   * HTML entities / bidi isolates are normalised the same way
---   * every response is memoised for `cache_ttl_ms`
local cfg = require("zotcite_extra.config")

local M = {}

local cache = {}

local ISOLATES = {
    "\226\129\166", -- U+2066 LRI
    "\226\129\167", -- U+2067 RLI
    "\226\129\168", -- U+2068 FSI
    "\226\129\169", -- U+2069 PDI
    "\226\128\139", -- U+200B ZWSP
    "\226\128\142", -- U+200E LRM
    "\226\128\143", -- U+200F RLM
}

--- Same normalisation as the ONLYOFFICE plugin's cleanText().
function M.clean(str)
    if not str or str == "" then return "" end
    local s = str
    s = s:gsub("&#38;", "&"):gsub("&amp;", "&")
    s = s:gsub("&#60;", "<"):gsub("&lt;", "<")
    s = s:gsub("&#62;", ">"):gsub("&gt;", ">")
    s = s:gsub("&#34;", '"'):gsub("&quot;", '"')
    s = s:gsub("&#39;", "'"):gsub("&apos;", "'")
    s = s:gsub("&nbsp;", " ")
    for _, iso in ipairs(ISOLATES) do
        s = s:gsub(iso, "")
    end
    s = s:gsub("%s+", " ")
    return vim.trim(s)
end

--- Citation text as Zotero returns it, minus markup.
--- Numeric styles come back as `<sup>[1]</sup>` (GB/T 7714) or `<sup>1</sup>`
--- (nature) while author-date styles come back as plain text.
function M.clean_citation(str)
    local s = str or ""
    s = s:gsub("<sup>", ""):gsub("</sup>", "")
    s = s:gsub("<i>", ""):gsub("</i>", "")
    s = s:gsub("<b>", ""):gsub("</b>", "")
    s = s:gsub("<span[^>]*>", ""):gsub("</span>", "")
    s = s:gsub("<[^>]+>", "")
    return M.clean(s)
end

local function base()
    local o = cfg.get()
    return string.format("http://127.0.0.1:%d/api/%s", o.port, o.library)
end

M.base = base

--- Raw GET, returns (body, err)
function M.get(path, timeout)
    local o = cfg.get()
    local now = vim.uv.now()
    local hit = cache[path]
    if hit and (now - hit.time) < o.cache_ttl_ms then
        return hit.body
    end
    local url = base() .. path
    local res = vim.system(
        { "curl", "-sS", "-m", tostring(math.ceil((timeout or o.request_timeout_ms) / 1000)), url },
        { text = true }
    ):wait(timeout or o.request_timeout_ms)
    if res.code ~= 0 then
        return nil, vim.trim(res.stderr or ("curl exit " .. res.code))
    end
    local body = res.stdout or ""
    if body == "" then return nil, "empty response" end
    cache[path] = { time = now, body = body }
    return body
end

function M.get_json(path, timeout)
    local body, err = M.get(path, timeout)
    if not body then return nil, err end
    -- `luanil` maps JSON null to real nil: otherwise every null arrives as the
    -- truthy `vim.NIL` and `x or {}` / `x.y` explode on it
    local ok, decoded = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
    if not ok then return nil, "invalid JSON: " .. tostring(decoded) end
    return decoded
end

function M.clear_cache()
    cache = {}
end

--- GET a path on Zotero's local server *outside* the `/api/…` namespace — the
--- endpoints plugins register themselves (e.g. ZotSeek's `/zotseek/search`).
--- No caching: callers own their cache lifetime.
--- @param path string e.g. "/zotseek/stats"
--- @return string? body, string? err
function M.endpoint(path, timeout)
    local o = cfg.get()
    local url = string.format("http://127.0.0.1:%d%s", o.port, path)
    local ms = timeout or 8000
    local job = vim.system(
        { "curl", "-sS", "-m", tostring(math.ceil(ms / 1000)), url }, { text = true })
    local res = job:wait(ms + 1000)
    if res.code ~= 0 then
        return nil, vim.trim(res.stderr or ("curl exit " .. res.code))
    end
    return res.stdout or ""
end

--- Same, decoded.
function M.endpoint_json(path, timeout)
    local body, err = M.endpoint(path, timeout)
    if not body then return nil, err end
    local ok, decoded = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
    if not ok then return nil, "invalid JSON: " .. tostring(decoded) end
    return decoded
end

--- Is Zotero's local server answering?
function M.ping()
    local o = cfg.get()
    local res = vim.system(
        { "curl", "-sS", "-m", "2", string.format("http://127.0.0.1:%d/api/", o.port) },
        { text = true }
    ):wait(3000)
    return res.code == 0 and (res.stdout or "") ~= ""
end

local function urlencode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

M.urlencode = urlencode

--- Fetch items by Zotero item keys, with Zotero-formatted citations.
--- @param keys string[] alphanumeric Zotero item keys
--- @param opts? { style?: string }
--- @return table[] items ordered like `keys`, each { key, citation, data }
function M.items(keys, opts)
    opts = opts or {}
    if not keys or #keys == 0 then return {} end
    local style = cfg.style_url(opts.style or M.current_style())
    local seen, uniq = {}, {}
    for _, k in ipairs(keys) do
        if k and k ~= "" and not seen[k] then
            seen[k] = true
            table.insert(uniq, k)
        end
    end
    local q = "/items?itemKey=" .. table.concat(uniq, ",")
        .. "&itemType=-attachment&include=citation,data&limit=100"
    if style then q = q .. "&style=" .. urlencode(style) end
    local data, err = M.get_json(q)
    if not data then return {}, err end
    local by_key, order = {}, {}
    for _, it in ipairs(data) do
        local k = it.key or (it.data and it.data.key)
        -- keep only rows that are real bibliographic items
        if k and (it.citation and it.citation ~= "") and it.data and it.data.itemType then
            by_key[k] = {
                key = k,
                citation = M.clean_citation(it.citation),
                bbt = it.data.citationKey,
                data = it.data,
                version = it.version,
            }
        end
    end
    for _, k in ipairs(uniq) do
        if by_key[k] then table.insert(order, by_key[k]) end
    end
    return order
end

--- Single item by Zotero key.
function M.item(key, opts)
    local items = M.items({ key }, opts)
    return items[1]
end

--- Quick search (Zotero's own `q=` quick search).
function M.search(q, opts)
    opts = opts or {}
    local style = cfg.style_url(opts.style or M.current_style())
    local query = "/items?itemType=-attachment&include=citation,data&limit="
        .. tostring(opts.limit or 25)
    if q and q ~= "" then query = query .. "&q=" .. urlencode(q) end
    if style then query = query .. "&style=" .. urlencode(style) end
    local data, err = M.get_json(query)
    if not data then return {}, err end
    local out = {}
    for _, it in ipairs(data) do
        if it.key and it.data and it.data.itemType and it.citation and it.citation ~= "" then
            table.insert(out, {
                key = it.key,
                citation = M.clean_citation(it.citation),
                bbt = it.data.citationKey,
                data = it.data,
            })
        end
    end
    return out
end

--- Bibliography HTML for the given keys, in the given style.
function M.bib_html(keys, opts)
    opts = opts or {}
    if not keys or #keys == 0 then return nil end
    local style = cfg.style_url(opts.style or M.current_style())
    local q = "/items?itemKey=" .. table.concat(keys, ",") .. "&itemType=-attachment&format=bib&limit=100"
    if style then q = q .. "&style=" .. urlencode(style) end
    return M.get(q)
end

--- Validate a style id against Zotero (400 + message when unknown).
--- @return boolean ok, string? err
function M.validate_style(style)
    local url = cfg.style_url(style)
    if not url then return false, "no style" end
    local q = "/items?limit=1&format=bib&style=" .. urlencode(url)
    local body, err = M.get(q, 8000)
    if not body then return false, err end
    if body:match("^Invalid style") then return false, body end
    return true
end

--- Style id currently in force for this buffer (YAML `csl:` wins).
function M.current_style(bufnr)
    local ok, style = pcall(require, "zotcite_extra.style")
    if ok then
        local s = style.get(bufnr)
        if s and s ~= "" then return s end
    end
    return cfg.get().style or cfg.get().default_style
end

--- Citation objects grouped for a whole buffer, one request per batch.
--- @param keys string[] zotero keys
--- @return table<string, string> map zotero key -> formatted citation
function M.citation_map(keys, opts)
    local map = {}
    for _, it in ipairs(M.items(keys, opts)) do
        map[it.key] = it.citation
    end
    return map
end

return M
