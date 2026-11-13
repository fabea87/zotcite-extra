-- End-to-end check inside a real nvim session (needs Zotero running):
--   nvim --headless examples/test.md -c "luafile tests/integration_spec.lua" -c "qa!"
-- or interactively:  :luafile tests/integration_spec.lua
local pass, fail = 0, 0
local function ok(cond, label, extra)
    if cond then
        pass = pass + 1
        print(("  ok   %s"):format(label))
    else
        fail = fail + 1
        print(("  FAIL %s%s"):format(label, extra and ("\n         " .. tostring(extra)) or ""))
    end
end

local function eq(got, want, label)
    ok(got == want, label, ("got [%s] want [%s]"):format(tostring(got), tostring(want)))
end

local BBT = "panaderoTrackingSelfregulatedLearning2025"
local BBT2 = "tengQuestionnaireBasedValidationMultidimensional2016"

print("== environment ==")
local api = require("zotcite_extra.api")
local data = require("zotcite_extra.data")
ok(api.ping(), "Zotero reachable on 127.0.0.1:" .. require("zotcite_extra.config").get().port)
ok(data.ready(), "zotcite database loaded")
eq(data.zotkey(BBT), "CRD2UAJG", "citekey -> Zotero key")
ok(#(data.search("panadero") or {}) > 0, "zotcite search returns candidates")
ok(#(require("zotcite_extra.style").available()) > 0, "CSL styles on disk")

print("== insert / swap in a buffer ==")
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.bo[buf].filetype = "markdown"
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Prior work is mixed.", "" })
vim.api.nvim_win_set_cursor(0, { 1, 19 })  -- end of line
require("zotcite_extra.insert").cite({ { citekey = BBT } }, { mode = "parenthetical", locator = "14" })
local l1 = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
eq(l1, "Prior work is mixed [@" .. BBT .. ", 14].", "insert parenthetical + locator")
ok(l1:find("%[@" .. BBT .. ", 14%]") ~= nil, "pandoc group written")

vim.api.nvim_win_set_cursor(0, { 1, (l1:find("@") or 1) - 1 })
require("zotcite_extra.insert").cycle_mode()
local l2 = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
ok(l2:find("^Prior work is mixed @" .. BBT) ~= nil, "swap -> narrative: " .. l2)

vim.api.nvim_win_set_cursor(0, { 1, (l2:find("@") or 1) - 1 })
require("zotcite_extra.insert").cycle_mode()
local l3 = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
ok(l3:find("%[-@" .. BBT .. ", 14%]") ~= nil, "swap -> year only: " .. l3)

vim.api.nvim_win_set_cursor(0, { 1, (l3:find("@") or 1) - 1 })
require("zotcite_extra.insert").cycle_mode()
local l4 = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
eq(l4, l1, "swap -> parenthetical (lossless round trip)")

print("== append to an existing cluster ==")
vim.api.nvim_win_set_cursor(0, { 1, (l4:find("@") or 1) - 1 })
require("zotcite_extra.insert").cite({ { citekey = BBT2 } }, {})
local l5 = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
ok(l5:find("@" .. BBT) and l5:find("@" .. BBT2), "second key added to the same group: " .. l5)

print("== CSL rendering ==")
require("zotcite_extra.render").update(buf)
local marks = vim.api.nvim_buf_get_extmarks(buf, require("zotcite_extra.render").namespace, 0, -1, { details = true })
ok(#marks > 0, "extmarks placed: " .. #marks)
if marks[1] then
    local txt = marks[1][4].virt_text and marks[1][4].virt_text[1][1] or ""
    ok(txt:match("Panadero") ~= nil, "rendered text: " .. txt)
end

print("== bibliography ==")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "First [@" .. BBT .. "].",
    "",
    "Second [@" .. BBT2 .. "].",
    "",
})
require("zotcite_extra.biblio").update({})
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local body = table.concat(lines, "\n")
ok(body:find("References") ~= nil, "References heading added")
ok(body:find("Panadero, E%.") ~= nil, "APA entry rendered")
ok(body:find("Teng, L%. S%.") ~= nil, "second entry rendered")
ok(body:find("doi%.org") ~= nil, "DOI kept")

print("== style switching (YAML csl:) ==")
local style = require("zotcite_extra.style")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "---", "title: t", "---", "", "Text [@" .. BBT .. "]." })
eq(style.set(buf, "chicago-author-date"), "chicago-author-date", "style written to YAML")
eq(style.get(buf), "chicago-author-date", "style read back")
local items = api.items({ "CRD2UAJG" }, { style = "chicago-author-date" })
eq(items[1].citation, "(Panadero et al. 2025)", "Zotero re-renders in the new style")

print(("\n%d passed, %d failed"):format(pass, fail))
if fail > 0 then vim.cmd("cquit 1") end
