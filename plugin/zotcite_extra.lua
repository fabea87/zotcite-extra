-- zotcite-extra: load only, no side effects before setup()
if vim.g.loaded_zotcite_extra == 1 then return end
vim.g.loaded_zotcite_extra = 1

-- Deliberately no commands/keymaps here: call require("zotcite_extra").setup{}
