--- "Open the document" for the citation under the cursor.
---
--- Does not ask the user anything: the item's children come from Zotero's own
--- API, and links are handed to Zotero (`zotero://…`) or to the OS opener, so
--- stored *and* linked attachments both work. The linked-attachment base
--- directory is read from Zotero's `prefs.js` when a filesystem path is really
--- needed (`base_dir()`), never from a prompt.
local cfg = require("zotcite_extra.config")

local M = {}

local base_cache
local children_cache = {}

local function dir_exists(p)
    return type(p) == "string" and p ~= "" and vim.fn.isdirectory(p) == 1
end

--- Value Zotero itself has in its preferences (may point at a mount that has
--- been renamed since, e.g. "OneDrive-Personal 2" -> "OneDrive-Personal").
function M.pref_base()
    local ok, dir = pcall(function()
        local files = vim.fn.glob(vim.env.HOME
            .. "/Library/Application Support/Zotero/Profiles/*/prefs.js", false, true)
        vim.list_extend(files, vim.fn.glob(vim.env.HOME .. "/Zotero/prefs.js", false, true))
        for _, f in ipairs(files) do
            local fh = io.open(f, "r")
            if fh then
                local body = fh:read("*a")
                fh:close()
                local p = body:match('baseAttachmentPath",%s*"([^"]+)"')
                if p and p ~= "" then return p end
            end
        end
        return nil
    end)
    if ok then return dir end
    return nil
end

--- Where linked attachments really live.
--- 1. the directory Zotero's prefs name, when it exists;
--- 2. `zotcite_extra`'s `attach_dir`, when set;
--- 3. any `zotero-storage` folder under a cloud mount (Zotero's pref goes stale
---    when a sync account is re-added and the mount is renamed).
--- @return string?
function M.base_dir()
    if base_cache ~= nil then return base_cache ~= false and base_cache or nil end
    local found
    local pref = M.pref_base()
    if dir_exists(pref) then found = pref end
    if not found then
        local configured = cfg.get().attach_dir
        if dir_exists(configured) then found = configured end
    end
    if not found then
        local roots = vim.fn.glob(vim.env.HOME .. "/Library/CloudStorage/*", false, true)
        for _, root in ipairs(roots) do
            for _, pat in ipairs({ "/zotero-storage", "/*/zotero-storage" }) do
                local hit = vim.fn.glob(root .. pat, false, true)[1]
                if dir_exists(hit) then
                    found = hit
                    break
                end
            end
            if found then break end
        end
    end
    base_cache = found or (pref and false) or false
    return found
end

--- Tell zotcite about the linked-attachment directory so its own commands stop
--- asking ("Are you using a base directory for linked attachments?").
--- Only when the directory is real; otherwise zotcite prints a scary warning.
--- @return string?
function M.sync_zotcite()
    local base = M.base_dir()
    if not base then return nil end
    pcall(function()
        local c = require("zotcite.config").get_config()
        if c and not c.attach_dir then c.attach_dir = base end
    end)
    return base
end

--- Attachments of an item, from Zotero's API (cached per item).
--- @param zotkey string
--- @return table[] { key, title, filename, contentType, path, linkMode }
function M.children(zotkey)
    if not zotkey or zotkey == "" then return {} end
    if children_cache[zotkey] then return children_cache[zotkey] end
    local api = require("zotcite_extra.api")
    local data, err = api.get_json("/items/" .. zotkey .. "/children")
    if not data then
        vim.notify("[zotcite-extra] cannot list attachments: " .. tostring(err), vim.log.levels.WARN)
        return {}
    end
    local out = {}
    for _, it in ipairs(data) do
        local d = it.data or {}
        if d.itemType == "attachment" then
            out[#out + 1] = {
                key = it.key,
                title = d.title or d.filename or "",
                filename = d.filename or (d.path and tostring(d.path):match("([^/]+)$")) or "",
                contentType = d.contentType or "",
                path = d.path,
                linkMode = d.linkMode,
            }
        end
    end
    children_cache[zotkey] = out
    return out
end

local function is_pdf(a)
    return (a.contentType or ""):find("pdf", 1, true) ~= nil
        or (a.filename or ""):lower():match("%.pdf$") ~= nil
end

--- Filesystem path of an attachment, or nil when it is not reachable.
--- @param att table
--- @return string?
function M.fs_path(att)
    local p = att.path and tostring(att.path) or ""
    if p == "" then
        -- stored attachments without a path live at storage/<key>/<filename>
        if att.filename and att.filename ~= "" then
            local o = cfg.get()
            return string.format("%s/storage/%s/%s", cfg.expand(o.storage_dir), att.key, att.filename)
        end
        return nil
    end
    if p:find("storage:", 1, true) then
        local rel = p:gsub(".*storage:", "")
        local o = cfg.get()
        return string.format("%s/storage/%s/%s", cfg.expand(o.storage_dir), att.key, rel)
    end
    if p:find("attachments:", 1, true) then
        local rel = p:gsub(".*attachments:", ""):gsub("^/", "")
        local base = M.base_dir()
        if not base then return nil end
        return string.format("%s/%s", base, rel)
    end
    if p:find("^%a:[/\\]") or p:find("^/") then return p end
    return nil
end

--- Percent-decode a file:// URL from Zotero's `/file` redirect.
local function decode_file_url(url)
    local p = url:match("^file://(.*)$")
    if not p then return nil end
    p = p:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
    return p
end

--- How *Zotero itself* resolves this attachment (its `/file` endpoint redirects
--- to a file:// URL). nil when Zotero cannot resolve it either — which is what
--- happens when the linked-attachment base directory in Zotero's preferences is
--- stale, e.g. after a cloud account was re-added under a new name.
--- @param att table
--- @return string? path
function M.zotero_path(att)
    if not att or not att.key then return nil end
    if att._zpath ~= nil then return att._zpath ~= false and att._zpath or nil end
    local o = cfg.get()
    local url = string.format("http://127.0.0.1:%d/api/%s/items/%s/file", o.port, o.library, att.key)
    local res = vim.system({ "curl", "-sS", "-m", "3", "-o", "/dev/null", "-D", "-", url },
        { text = true }):wait(4000)
    local loc = res.code == 0 and (res.stdout or ""):match("[Ll]ocation:%s*([^\r\n]+)")
    local path = loc and decode_file_url(vim.trim(loc)) or nil
    att._zpath = path or false
    return path
end

--- The file to open: Zotero's own resolution when the file is really there,
--- otherwise our repaired path for linked attachments.
--- @param att table
--- @return string? path, string how  ("zotero" | "repaired")
function M.real_path(att)
    local zp = M.zotero_path(att)
    if zp and vim.uv.fs_stat(zp) then return zp, "zotero" end
    local mine = M.fs_path(att)
    if mine and vim.uv.fs_stat(mine) then return mine, "repaired" end
    return nil, "missing"
end

--- Hand a URL or path to the OS (macOS: `open`, so `zotero://` URLs reach
--- Zotero). `open_cmd` overrides the opener.
local function launch(target)
    local cmd = cfg.get().open_cmd
    if cmd then
        pcall(vim.system, { cmd, target }, { detach = true })
        return
    end
    local ok, err = pcall(vim.ui.open, target)
    if not ok and err then
        vim.notify("[zotcite-extra] cannot open " .. tostring(target) .. ": " .. tostring(err),
            vim.log.levels.ERROR)
    end
end

M.launch = launch

--- Open something in Zotero itself (reader / select in the item list).
function M.zotero_url(kind, key)
    if kind == "pdf" then return "zotero://open-pdf/library/items/" .. key end
    return "zotero://select/library/items/" .. key
end

--- Pick one of several attachments.
local function choose(list, prompt, cb)
    if #list == 1 then return cb(list[1]) end
    vim.ui.select(list, {
        prompt = prompt,
        format_item = function(a)
            local tag = a.title ~= "" and a.title or a.filename
            return string.format("%s  [%s]", tag, (a.contentType or ""):gsub("application/", ""))
        end,
    }, function(choice)
        if choice then cb(choice) end
    end)
end

--- Open the document of an item: the PDF in Zotero's reader, any other
--- attachment through Zotero, and the item itself in Zotero when there is no
--- attachment at all. `force = "system"` asks the OS to open the file.
--- @param zotkey string
--- @param opts? { force?: "system" }
--- @return boolean opened
function M.open_item(zotkey, opts)
    opts = opts or {}
    if not zotkey or zotkey == "" then return false end
    local external = opts.force == "system"
    local pdfs, others, seen_name = {}, {}, {}
    for _, a in ipairs(M.children(zotkey)) do
        if is_pdf(a) then
            -- the same PDF often exists twice ("… .pdf" and "… 1.pdf"): open one
            -- instead of asking, but keep genuinely different files apart
            local name = (a.filename or a.title or a.key):gsub("%s+%d*%.pdf$", ".pdf")
            if not seen_name[name] then
                seen_name[name] = true
                pdfs[#pdfs + 1] = a
            end
        else
            others[#others + 1] = a
        end
    end

    -- Zotero is the nicer place to read a PDF (annotations, linked highlights),
    -- but it silently does nothing when *its* path is stale: in that case open
    -- the file we can actually reach instead of failing.
    local function open(att, zurl)
        local path, how = M.real_path(att)
        if how == "zotero" and not external then return launch(zurl) end
        if path then
            if how == "repaired" then
                vim.notify("[zotcite-extra] Zotero cannot reach this attachment (its linked-file"
                    .. " base directory looks stale) — opening the file directly. Run"
                    .. " :ZFixAttachDir to let Zotero open it again.", vim.log.levels.INFO)
            end
            return launch(path)
        end
        vim.notify("[zotcite-extra] attachment file is missing — opening the item in Zotero",
            vim.log.levels.WARN)
        launch(zurl)
    end

    if #pdfs > 0 then
        choose(pdfs, external and "Open PDF (external app)" or "Open PDF", function(a)
            open(a, M.zotero_url("pdf", a.key))
        end)
        return true
    end
    if #others > 0 then
        choose(others, external and "Open attachment (external app)" or "Open attachment", function(a)
            open(a, M.zotero_url("select", a.key))
        end)
        return true
    end
    launch(M.zotero_url("select", zotkey))
    vim.notify("[zotcite-extra] no attachment — selected the item in Zotero",
        vim.log.levels.INFO)
    return true
end

--- Open the document of the citation under the cursor (anywhere on the line).
--- @return boolean
function M.open_under_cursor(opts)
    local cluster = require("zotcite_extra.cluster")
    local data = require("zotcite_extra.data")
    local pos = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_buf_get_lines(0, pos[1] - 1, pos[1], false)[1] or ""
    local group = cluster.nearest(line, pos[2])
    local items = group and cluster.items_of(group) or {}
    local citekey = items[1] and items[1].key
    if not citekey then
        vim.notify("[zotcite-extra] no citation on this line", vim.log.levels.WARN)
        return false
    end
    local zotkey = data.zotkey(citekey)
    if not zotkey then
        vim.notify("[zotcite-extra] '" .. citekey .. "' is not in the Zotero library",
            vim.log.levels.WARN)
        return false
    end
    return M.open_item(zotkey, opts)
end

--- Where to put a symlink so that a stale base directory resolves again.
--- Pure path arithmetic (no filesystem writes), so it is testable.
---
--- The link is always placed *at* the directory Zotero has configured (its
--- parents are created as plain directories), never on a shallower component:
--- shadowing e.g. "OneDrive-Personal" or "Dropbox" with a link would be far more
--- invasive than repairing the path Zotero actually asks for.
--- @param stale string directory Zotero has in its preferences
--- @param real string directory where the files actually are
--- @return nil|{ link: string, target: string, reason: string }
function M.symlink_plan(stale, real)
    if not stale or not real or stale == "" or real == "" then return nil end
    stale, real = stale:gsub("/+$", ""), real:gsub("/+$", "")
    if stale == real then return nil end
    -- stale being a prefix of real means a parent already exists: nothing to do
    if real:sub(1, #stale + 1) == stale .. "/" then return nil end
    return {
        link = stale,
        target = real,
        reason = "Zotero's base directory is missing, the files are elsewhere",
    }
end

--- Make Zotero's configured linked-attachment directory resolve again by
--- symlinking the stale component to the real folder. Zotero then opens linked
--- PDFs itself again (`zotero://open-pdf/…`), with its reader and annotations.
--- @return boolean ok, string message
function M.fix_base()
    local stale, real = M.pref_base(), M.base_dir()
    if not stale then return false, "Zotero has no linked-attachment base directory configured" end
    if not real then return false, "no existing attachment directory found to link to" end
    if vim.fn.isdirectory(stale) == 1 then
        return true, "Zotero's base directory already resolves: " .. stale
    end
    local plan = M.symlink_plan(stale, real)
    if not plan then return false, "nothing to repair (paths are identical)" end
    if vim.uv.fs_stat(plan.link) or vim.uv.fs_lstat(plan.link) then
        return false, "refusing to touch " .. plan.link .. " — something already exists there"
    end
    local parent = plan.link:match("^(.*)/[^/]+$")
    if parent and vim.fn.isdirectory(parent) == 0 then
        if vim.fn.mkdir(parent, "p") == 0 then
            return false, "cannot create " .. parent
        end
    end
    local res = vim.system({ "ln", "-s", plan.target, plan.link }, { text = true }):wait(4000)
    if res.code ~= 0 then
        return false, "ln failed: " .. vim.trim(res.stderr or ("exit " .. res.code))
    end
    base_cache = nil -- re-resolve
    base_cache = real
    return true, string.format("linked %s -> %s (%s)", plan.link, plan.target, plan.reason)
end

--- Human-readable resolution report for an item, for :ZAttachments.
--- @param zotkey string
--- @return string[]
function M.describe(zotkey)
    local lines = {}
    local pref = M.pref_base()
    local base = M.base_dir()
    lines[#lines + 1] = "Zotero linked-file base dir: " .. tostring(pref)
    if pref and base and pref ~= base then
        lines[#lines + 1] = "  ✗ stale — zotcite-extra uses " .. base
    end
    local atts = M.children(zotkey)
    if #atts == 0 then
        lines[#lines + 1] = "no attachment"
        return lines
    end
    for _, a in ipairs(atts) do
        local zp = M.zotero_path(a)
        local rp, how = M.real_path(a)
        lines[#lines + 1] = string.format("%s  %s  [%s]", a.key,
            a.filename ~= "" and a.filename or (a.title ~= "" and a.title or "?"),
            a.contentType ~= "" and a.contentType or (a.linkMode or "?"))
        lines[#lines + 1] = string.format("  zotero:   %s%s", tostring(zp),
            zp and (vim.uv.fs_stat(zp) and "  ✓" or "  ✗ missing") or "")
        lines[#lines + 1] = string.format("  resolved: %s  (%s)", tostring(rp), how)
    end
    return lines
end

--- Forget cached attachment lists (after adding an attachment in Zotero).
function M.invalidate(zotkey)
    if zotkey then children_cache[zotkey] = nil else children_cache = {} end
end

return M
