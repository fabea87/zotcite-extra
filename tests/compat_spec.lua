-- Headless spec:  nvim --headless -l tests/compat_spec.lua
--
-- Runs in two worlds and must pass in both:
--   * with zotcite (and telescope) on the runtime path -> every internal we
--     borrow resolves;
--   * zotcite-extra alone -> nothing explodes, the picker falls back to Zotero's
--     HTTP API and the doctor says exactly what is missing.
vim.opt.rtp:append(vim.fn.getcwd())
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.cmd("enew")
vim.bo.filetype = "markdown"

local failed, passed = 0, 0

local function ok(cond, label)
    if cond then
        passed = passed + 1
        print("  ok   " .. label)
    else
        failed = failed + 1
        print("  FAIL " .. label)
    end
end

local compat = require("zotcite_extra.compat")
local cfg = require("zotcite_extra.config")

local has_zotcite = pcall(require, "zotcite.config")
print(has_zotcite and "== world: zotcite present ==" or "== world: zotcite-extra alone ==")

print("== dependency probe ==")
do
    local missing, present = {}, {}
    for _, dep in ipairs(compat.deps) do
        if compat.probe(dep) then table.insert(present, dep) else table.insert(missing, dep) end
    end
    if has_zotcite then
        ok(#missing == 0, "all zotcite internals resolve (" .. #compat.deps .. " probes)")
        for _, dep in ipairs(missing) do
            print("       missing: " .. dep.mod .. "." .. dep.field)
        end
    else
        ok(#missing == #compat.deps, "every probe reports missing without zotcite")
    end
end

print("== report ==")
do
    local lines = compat.report()
    local text = table.concat(lines, "\n")
    ok(#lines > 5, "report has content")
    ok(text:find("hl_cite_key") ~= nil, "report mentions hl_cite_key")
    ok(text:find("shadowed zotcite keys") ~= nil, "report lists the shadowed keys")
    local missing = compat.check() -- must not throw
    ok(type(missing) == "table", "check() returns the missing set")
end

print("== shadowing is switchable ==")
do
    cfg.get().shadow_zotcite_keys = false
    local text = table.concat(compat.shadowed(), "\n")
    ok(text:find("shadow_zotcite_keys = false") ~= nil, "opt-out is visible in the report")
    cfg.get().shadow_zotcite_keys = true
    text = table.concat(compat.shadowed(), "\n")
    ok(text:find("<leader>zb") ~= nil and text:find("<leader>zo") ~= nil,
        "both shadowed keys are documented")
end

print("== our own surface ==")
do
    -- setup must survive whatever is loaded
    local ok_setup = pcall(function()
        require("zotcite_extra").setup({ picker = has_zotcite and nil or "ui" })
    end)
    ok(ok_setup, "setup() succeeds")
    local cmds = vim.fn.getcompletion("Z", "command")
    for _, c in ipairs({ "ZCite", "ZCiteN", "ZCiteY", "ZMode", "ZDel", "ZBiblio", "ZStyle",
        "ZLocator", "ZOpen", "ZRender", "ZDoctor", "ZPing", "ZAttach", "ZLsp" }) do
        ok(vim.tbl_contains(cmds, c), "command " .. c)
    end
end

print("== picker fallback ==")
do
    local entries = require("zotcite_extra.picker").entries("reliab")
    if has_zotcite then
        ok(#entries > 0, "candidates from zotcite's database")
    else
        ok(#entries > 0, "candidates from Zotero's HTTP API")
    end
    local e = entries[1]
    ok(e ~= nil and e.citekey ~= nil and e.line ~= nil, "entry has citekey + line")
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
