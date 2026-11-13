--- In-document bibliography: renders Zotero's `format=bib` output under a
--- "# References" heading — the ONLYOFFICE "Insert/Update Bibliography"
--- button, but writing Markdown instead of Word paragraphs.
local cfg = require("zotcite_extra.config")
local api = require("zotcite_extra.api")

local M = {}

--- Markdown text of one CSL bibliography entry.
--- `keep_marker = false` drops Zotero's own "1." / "1" prefix (numeric styles:
--- we number the list ourselves, in citation order).
local function entry_to_md(html, keep_marker)
    local s = html
    local marker = s:match('<div class="csl%-left%-margin"[^>]*>(.-)</div>')
    s = s:gsub('<div class="csl%-left%-margin"[^>]*>.-</div>', "")
    s = s:gsub('<div class="csl%-right%-inline"[^>]*>(.*)%s*$', "%1")
    s = s:gsub("</?div[^>]*>", "")
    s = s:gsub("</?span[^>]*>", "")
    s = s:gsub("<i>", "*"):gsub("</i>", "*")
    s = s:gsub("<em>", "*"):gsub("</em>", "*")
    s = s:gsub("<b>", "**"):gsub("</b>", "**")
    s = s:gsub("<strong>", "**"):gsub("</strong>", "**")
    s = s:gsub("<sup>", "^"):gsub("</sup>", "")
    s = s:gsub("<sub>", "_"):gsub("</sub>", "")
    s = api.clean(s)
    if marker and keep_marker ~= false then
        marker = api.clean(marker:gsub("<[^>]->", ""))
        if marker ~= "" then s = marker .. " " .. s end
    end
    return s
end

--- Split Zotero's csl-bib-body HTML into markdown entries.
function M.html_to_markdown(html, opts)
    opts = opts or {}
    local out = {}
    if not html then return out end
    html = html:gsub('<span class="Z3988".-</span>', "")
    local pos = 1
    while true do
        local s = html:find('<div class="csl%-entry"', pos)
        if not s then break end
        local body_start = html:find(">", s, true) + 1
        local next_entry = html:find('<div class="csl%-entry"', body_start)
        local chunk = html:sub(body_start, (next_entry and (next_entry - 1)) or #html)
        local md = entry_to_md(chunk, opts.keep_marker)
        if md ~= "" then table.insert(out, md) end
        if not next_entry then break end
        pos = next_entry
    end
    return out
end

--- All keys cited in the buffer, in order of first appearance.
function M.cited_keys(bufnr)
    local render = require("zotcite_extra.render")
    local data = require("zotcite_extra.data")
    local seen, out = {}, {}
    for _, g in ipairs(render.collect(bufnr or 0)) do
        for _, k in ipairs(g.keys) do
            if not seen[k] then
                seen[k] = true
                local zk = data.zotkey(k)
                table.insert(out, { citekey = k, zotkey = zk })
            end
        end
    end
    return out
end

local function find_heading(bufnr)
    local o = cfg.get()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, l in ipairs(lines) do
        if l:match(o.bib_heading) then return i end
    end
    return nil
end

--- Insert or refresh the bibliography. When `only_cited` is false the whole
--- library selection is rendered; by default only cited works appear.
function M.update(opts)
    opts = opts or {}
    local bufnr = vim.api.nvim_get_current_buf()
    local keys = M.cited_keys(bufnr)
    if #keys == 0 then
        vim.notify("[zotcite-extra] no citations found in this buffer", vim.log.levels.WARN)
        return
    end
    local zkeys = {}
    for _, k in ipairs(keys) do
        if k.zotkey then table.insert(zkeys, k.zotkey) end
    end
    if #zkeys == 0 then
        vim.notify("[zotcite-extra] cannot resolve Zotero keys (is zotcite initialised?)", vim.log.levels.WARN)
        return
    end

    local style = require("zotcite_extra.style").get(bufnr)

    -- numeric styles: Zotero numbers a list by its own sort order, which is not
    -- the citation order, so we take each entry bare and number it ourselves
    local numeric, is_numeric = require("zotcite_extra.numeric"), false
    local forced = (cfg.get().numeric or {}).force
    if forced then
        is_numeric = forced == "numeric"
    elseif #zkeys > 0 then
        local probe = api.citation_map({ zkeys[1] })
        is_numeric = numeric.is_numeric(probe[zkeys[1]])
    end

    local entries = {}
    if is_numeric then
        for i, zk in ipairs(zkeys) do
            local html = api.bib_html({ zk }, { style = style })
            for _, md in ipairs(M.html_to_markdown(html, { keep_marker = false })) do
                entries[#entries + 1] = numeric.bib_marker(i) .. md
            end
        end
    else
        entries = M.html_to_markdown(api.bib_html(zkeys, { style = style }))
    end
    if #entries == 0 then
        vim.notify("[zotcite-extra] Zotero returned an empty bibliography", vim.log.levels.WARN)
        return
    end

    local block = {}
    for _, e in ipairs(entries) do
        table.insert(block, e)
        table.insert(block, "")
    end

    local heading = find_heading(bufnr)
    if heading then
        -- replace everything after the heading, up to the next heading of the
        -- same or a higher level (0-based indices: heading line is h0)
        local h0 = heading - 1
        local count = vim.api.nvim_buf_line_count(bufnr)
        local level = (vim.api.nvim_buf_get_lines(bufnr, h0, h0 + 1, false)[1] or "")
            :match("^(#+)") or "#"
        local stop = count
        for i = h0 + 1, count - 1 do
            local lv = (vim.api.nvim_buf_get_lines(bufnr, i, i + 1, false)[1] or ""):match("^(#+)%s")
            if lv and #lv <= #level then
                stop = i
                break
            end
        end
        local body = { "" }
        for _, e in ipairs(entries) do
            table.insert(body, e)
            table.insert(body, "")
        end
        vim.api.nvim_buf_set_lines(bufnr, h0 + 1, stop, false, body)
    else
        local line_count = vim.api.nvim_buf_line_count(bufnr)
        local tail = vim.api.nvim_buf_get_lines(bufnr, line_count - 1, line_count, false)[1] or ""
        local new = {}
        if vim.trim(tail) ~= "" then table.insert(new, "") end
        table.insert(new, cfg.get().bib_heading_insert)
        table.insert(new, "")
        vim.list_extend(new, block)
        vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false, new)
    end
    vim.notify(string.format("[zotcite-extra] bibliography: %d entries (%s)", #entries, style),
        vim.log.levels.INFO)
end

return M
