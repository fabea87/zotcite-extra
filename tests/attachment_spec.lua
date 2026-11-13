-- Headless spec:  nvim --headless -l tests/attachment_spec.lua
-- Attachment resolution for <leader>zo / :ZOpen. Needs Zotero running for the
-- API part; the pure helpers are checked unconditionally.
vim.opt.rtp:append(vim.fn.getcwd())
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.cmd("enew")
vim.bo.filetype = "markdown"

local failed, passed, skipped = 0, 0, 0

local function ok(cond, label)
    if cond then
        passed = passed + 1
        print("  ok   " .. label)
    else
        failed = failed + 1
        print("  FAIL " .. label)
    end
end

local function skip(label)
    skipped = skipped + 1
    print("  skip " .. label)
end

local att = require("zotcite_extra.attachment")
local cfg = require("zotcite_extra.config")

print("== linked-attachment directory ==")
do
    local base = att.base_dir()
    ok(base == nil or vim.fn.isdirectory(base) == 1,
        "base_dir() is either nil or a real directory: " .. tostring(base))
    local pref = att.pref_base()
    ok(pref == nil or type(pref) == "string", "pref_base() readable: " .. tostring(pref))
    if pref and base and pref ~= base then
        print("       note: Zotero's pref is stale (" .. pref .. ")")
    end
end

print("== stored / linked path shapes ==")
do
    cfg.get().storage_dir = "~/Zotero"
    local storage = att.fs_path({ key = "ABCD1234", path = "storage:file.pdf", filename = "file.pdf" })
    ok(storage == cfg.expand("~/Zotero") .. "/storage/ABCD1234/file.pdf", "storage: -> <storage_dir>/<key>/<file>")
    local no_path = att.fs_path({ key = "ABCD1234", filename = "snap.html" })
    ok(no_path ~= nil and no_path:find("/storage/ABCD1234/snap.html$") ~= nil,
        "attachment without path falls back to storage/<key>/<file>")
    local linked = att.fs_path({ key = "ABCD1234", path = "attachments:sub/dir/a.pdf" })
    if att.base_dir() then
        ok(linked ~= nil and linked:find("^/") ~= nil and linked:find("sub/dir/a.pdf$") ~= nil,
            "attachments: -> <base_dir>/<relative>")
    else
        skip("attachments: -> base_dir (none configured)")
    end
    ok(att.fs_path({ key = "ABCD1234", path = "/abs/path/x.pdf" }) == "/abs/path/x.pdf",
        "absolute path kept")
end

print("== relink plan (stale Zotero base dir) ==")
do
    local plan = att.symlink_plan(
        "/u/Library/CloudStorage/OneDrive-Personal 2/备份/zotero-storage",
        "/u/Library/CloudStorage/OneDrive-Personal/备份/zotero-storage")
    ok(plan ~= nil, "a stale base dir gets a plan")
    if plan then
        ok(plan.link:find("OneDrive%-Personal 2") ~= nil, "link goes at the path Zotero asks for")
        ok(plan.target:find("OneDrive%-Personal/") ~= nil, "link points at the real folder")
    end
    ok(att.symlink_plan("/a/b", "/a/b") == nil, "identical paths -> no plan")
    ok(att.symlink_plan("/a/b", "/a/b/c/d") == nil, "stale is a prefix of real -> no plan")
    ok(att.symlink_plan(nil, "/a/b") == nil, "no pref -> no plan")
end

print("== opener targets ==")
do
    ok(att.zotero_url("pdf", "KEY") == "zotero://open-pdf/library/items/KEY", "pdf URL")
    ok(att.zotero_url("select", "KEY") == "zotero://select/library/items/KEY", "select URL")
end

print("== live item (needs Zotero) ==")
do
    local data = require("zotcite_extra.data")
    local citekey, zotkey
    if data.ready() then
        for _, r in ipairs(data.search("") or {}) do
            citekey, zotkey = r.citekey, r.zotkey
            break
        end
    end
    if not zotkey then
        skip("live attachment resolution (Zotero not reachable)")
    else
        local okapi, children = pcall(att.children, zotkey)
        ok(okapi and type(children) == "table", "children() returns a list for " .. tostring(citekey))
        local lines = att.describe(zotkey)
        ok(#lines > 0 and table.concat(lines, "\n"):find("linked%-file base dir") ~= nil,
            "describe() reports the base directory")
        if children and #children > 0 then
            local path, how = att.real_path(children[1])
            ok(how == "zotero" or how == "repaired" or how == "missing",
                "real_path() classifies as zotero/repaired/missing (" .. tostring(how) .. ")")
            ok(path == nil or vim.uv.fs_stat(path) ~= nil,
                "real_path() only returns existing files")
        else
            skip("first library item has no attachment")
        end
    end
end

print(string.format("\n%d passed, %d failed, %d skipped", passed, failed, skipped))
os.exit(failed == 0 and 0 or 1)
