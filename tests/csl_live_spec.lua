-- nvim --headless -l tests/csl_live_spec.lua   (needs Zotero running)
vim.opt.rtp:append(vim.fn.getcwd())
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local api = require("zotcite_extra.api")
local csl = require("zotcite_extra.csl")
local style = require("zotcite_extra.style")

if not api.ping() then print("SKIP: Zotero not running"); os.exit(0) end

local keys = { "CRD2UAJG", "YRYUWGMQ", "G5ZLR2IY" }
local items, err = api.items(keys, { style = "apa" })
assert(#items > 0, "no items: " .. tostring(err))
print(("Zotero: %d items, style=%s"):format(#items, style.get(0)))
for _, it in ipairs(items) do
    print(("  %s -> %s"):format(it.bbt or it.key, it.citation))
end

local function show(label, res) print(("%-28s %s"):format(label, res.text)) end

show("parenthetical:", csl.build(items, { mode = "parenthetical" }))
show("narrative:", csl.build({ items[1] }, { mode = "narrative" }))
show("suppress:", csl.build({ items[1] }, { mode = "suppress" }))
show("locator:", csl.build({ items[1] }, { mode = "parenthetical", locator = "14" }))
show("locator range:", csl.build({ items[1] }, { mode = "parenthetical", locator = "14-16" }))
show("prefix+suffix:", csl.build({ items[1] }, { mode = "parenthetical", locator = "3", prefix = "see", suffix = "for a review" }))
show("cluster (sorted):", csl.build({ items[1], items[2] }, { mode = "parenthetical" }))
show("cluster reverse order:", csl.build({ items[2], items[1] }, { mode = "parenthetical" }))

-- bibliography
local html = api.bib_html(keys, { style = "apa" })
local biblio = require("zotcite_extra.biblio").html_to_markdown(html)
print(("\nbibliography (%d entries):"):format(#biblio))
for _, e in ipairs(biblio) do print("  - " .. e:sub(1, 120)) end

-- numeric style
local num = api.items({ keys[1] }, { style = "chinese-gb7714-2005-numeric" })
if num[1] then show("numeric [1]:", csl.build(num, { mode = "parenthetical" })) end
os.exit(0)
