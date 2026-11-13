--- Compatibility with upstream zotcite.
---
--- zotcite-extra is a *companion*, not a fork: zotcite owns the database layer
--- (sqlite copies, citekeys, collections, notes, PDF notes) and keeps updating.
--- Everything we borrow from it is therefore version-sensitive, and a few of its
--- key bindings are deliberately shadowed. Both facts are made explicit here:
---   * `M.report()` / `:ZDoctor` lists which of zotcite's internals exist and
---     which of its keys we take over;
---   * `M.check()` warns once at setup when something we rely on has moved;
---   * every call into zotcite elsewhere is wrapped in `pcall` and degrades to
---     Zotero's HTTP API, so a breaking change never takes the buffer down.
local M = {}

--- zotcite internals we call, and why.
M.deps = {
    { mod = "zotcite.config", field = "get_config", why = "library/key_type/attach_dir" },
    { mod = "zotcite.config", field = "get_key_type", why = "citekey flavour per buffer" },
    { mod = "zotcite.config", field = "init", why = "initialise a buffer that its ftplugin missed" },
    { mod = "zotcite.zotero", field = "get_match", why = "completion + picker candidates" },
    { mod = "zotcite.zotero", field = "get_ref_data", why = "citekey -> zotkey, creator names" },
    { mod = "zotcite.zotero", field = "get_all_citations", why = "citekey <-> zotkey maps" },
    { mod = "zotcite.zotero", field = "init", why = "load the database on demand" },
    { mod = "zotcite.zotero", field = "get_attachment", why = "optional: attachment lookup fallback" },
    { mod = "zotcite.get", field = "abstract", why = "passed through on <leader>zA" },
    { mod = "zotcite.seek", field = "refs", why = "optional: <C-x><C-b> box" },
}

--- Keys of zotcite's own that we shadow (documentation + doctor output).
function M.shadowed()
    local o = require("zotcite_extra.config").get()
    local maps = o.maps or {}
    local out = {}
    local function add(key, ours, theirs)
        if key and key ~= false then
            table.insert(out, string.format("%s -> %s (zotcite: %s)", key, ours, theirs))
        end
    end
    if o.shadow_zotcite_keys == false then
        table.insert(out, "  (shadow_zotcite_keys = false: zotcite keeps <leader>zb and <leader>zo)")
    else
        add(maps.bib or "<leader>zb", "update bibliography", "paste abstract note")
        add(maps.open or "<leader>zo", "open the document (via Zotero)",
            "open attachment (needs attach_dir)")
    end
    table.insert(out, "<Tab> in insert mode -> our picker (zotcite: inline menu / <C-x><C-b>)")
    return out
end

--- Probe one dependency.
--- @return boolean ok, string detail
function M.probe(dep)
    local ok, mod = pcall(require, dep.mod)
    if not ok or type(mod) ~= "table" then return false, "module missing" end
    if mod[dep.field] == nil then return false, "field missing" end
    return true, "ok"
end

--- Full compatibility report, as lines.
function M.report()
    local lines = {}
    local missing = {}
    for _, dep in ipairs(M.deps) do
        local ok, detail = M.probe(dep)
        lines[#lines + 1] = string.format("%s %-24s %-16s %s", ok and "✓" or "✗",
            dep.mod, dep.field, detail ~= "ok" and detail or dep.why)
        if not ok then missing[#missing + 1] = dep.mod .. "." .. dep.field end
    end

    local cfg = require("zotcite_extra.config").get()
    lines[#lines + 1] = ""

    -- settings that our rendering depends on
    local okc, zcfg = pcall(function()
        return require("zotcite.config").get_config()
    end)
    if okc and zcfg then
        lines[#lines + 1] = string.format("%s hl_cite_key = %s (zotcite-extra renders instead: needs false)",
            zcfg.hl_cite_key and "✗" or "✓", tostring(zcfg.hl_cite_key))
        lines[#lines + 1] = string.format("  key_type = %s, attach_dir = %s",
            tostring(zcfg.key_type), tostring(zcfg.attach_dir))
        if zcfg.conceallevel and zcfg.conceallevel > 0 then
            lines[#lines + 1] = string.format("  conceallevel = %s (we use our own extmarks)",
                tostring(zcfg.conceallevel))
        end
    else
        lines[#lines + 1] = "✗ zotcite.config.get_config() unavailable: hl_cite_key / key_type"
            .. " / attach_dir cannot be checked, citekey resolution is disabled"
    end

    local function mark(ok) return ok and "✓" or "✗" end
    local ts = pcall(require, "telescope")
    lines[#lines + 1] = string.format("optional: telescope %s  sqlite3 %s  curl %s",
        mark(ts), mark(vim.fn.executable("sqlite3") == 1),
        mark(vim.fn.executable("curl") == 1))

    lines[#lines + 1] = ""
    lines[#lines + 1] = "shadowed zotcite keys (set maps.bib / maps.open = false to keep zotcite's):"
    vim.list_extend(lines, M.shadowed())
    if #missing > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "missing: " .. table.concat(missing, ", ")
        lines[#lines + 1] = "zotcite-extra still works through Zotero's HTTP API, but citekey"
            .. " resolution and completion degrade; check the zotcite version."
    end
    return lines
end

--- Warn once when something we depend on is gone.
--- @return table[] missing dependency records
function M.check()
    local missing = {}
    for _, dep in ipairs(M.deps) do
        local ok = M.probe(dep)
        if not ok then missing[#missing + 1] = dep end
    end
    local opts = require("zotcite_extra.config").get()
    if opts.warn_on_zotcite_changes ~= false and #missing > 0 then
        local names = {}
        for _, dep in ipairs(missing) do
            names[#names + 1] = dep.mod .. "." .. dep.field
        end
        vim.notify("[zotcite-extra] zotcite changed: " .. table.concat(names, ", ")
            .. ". Falling back to Zotero's HTTP API where possible (see :ZDoctor).",
            vim.log.levels.WARN)
    end
    -- zotcite's config table is built once, on the first require: when the user
    -- has asked for hl_cite_key = false in zotcite's opts, honour that even if an
    -- early load left the stale default in the table.
    local uopts = select(2, pcall(function() return require("zotcite").user_opts end))
    local requested_off = type(uopts) == "table" and uopts.hl_cite_key == false
    local okc, zcfg = pcall(function() return require("zotcite.config").get_config() end)
    if okc and zcfg and zcfg.hl_cite_key and not requested_off
        and opts.warn_on_zotcite_changes ~= false then
        vim.notify("[zotcite-extra] set hl_cite_key = false in zotcite's opts, otherwise its"
            .. " highlighting fights our rendering", vim.log.levels.WARN)
    end
    return missing
end

return M
