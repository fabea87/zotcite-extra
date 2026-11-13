-- nvim --headless -l tests/e2e_swap_spec.lua  (needs Zotero)
vim.opt.rtp:append(vim.fn.getcwd())
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local insert = require("zotcite_extra.insert")
local api = require("zotcite_extra.api")
if not api.ping() then print("SKIP: Zotero not running"); os.exit(0) end

local key = "panaderoTrackingSelfregulatedLearning2025"

-- a real buffer: swap the mode with the plugin, keep the rendered results
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.bo[buf].filetype = "markdown"
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "The study reports a strong effect " .. "[@" .. key .. ", p. 14] and closes.",
})

local forms = {}
for i = 1, 4 do
    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    local col = (line:find("@") or 1) - 1
    vim.api.nvim_win_set_cursor(0, { 1, col })
    table.insert(forms, line)
    insert.cycle_mode()
end

local out = { "--- markdown produced by <leader>zm ---" }
for i, l in ipairs(forms) do table.insert(out, ("%d. %s"):format(i, l)) end
print(table.concat(out, "\n"))

-- render each form with pandoc --citeproc and compare semantics
local fixture = vim.fn.getcwd() .. "/tests/fixtures.csl.json"
for i, l in ipairs(forms) do
    local tmp = vim.fn.tempname() .. ".md"
    vim.fn.writefile({ l }, tmp)
    local res = vim.system({ "pandoc", tmp, "--citeproc", "--bibliography=" .. fixture,
        "-t", "plain", "--wrap=none" }, { text = true }):wait(20000)
    print(("%d. %s"):format(i, vim.trim(res.stdout or res.stderr or "")))
    vim.fn.delete(tmp)
end
os.exit(0)
