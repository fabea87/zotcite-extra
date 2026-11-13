-- Headless spec:  nvim --headless -l tests/mode_swap_spec.lua
vim.opt.rtp:append(vim.fn.getcwd())
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local cluster = require("zotcite_extra.cluster")
local failed, passed = 0, 0

local function eq(got, want, label)
    if got == want then
        passed = passed + 1
        print(string.format("  ok   %s", label))
    else
        failed = failed + 1
        print(string.format("  FAIL %s\n         got  %q\n         want %q", label, got, want))
    end
end

local insert = require("zotcite_extra.insert")

--- Cycle the citation on `line` exactly the way <leader>zm does.
local function cycle(line, col)
    local g = cluster.nearest(line, col or 5)
    assert(g, "no group in: " .. line)
    local items = cluster.items_of(g)
    local from = cluster.mode_of(g, items)
    local to = insert.next_mode(from)
    insert.apply_mode(items, from, to)
    return cluster.render(g, items, to), from, to
end

print("== mode swap: single citation ==")
do
    local line = "This holds [@chen2020]. Next sentence."
    local out, from, to = cycle(line)
    eq(from, "parenthetical", "detect parenthetical")
    eq(out, "@chen2020", "parenthetical -> narrative")
    local out2 = cycle(out .. " Next.", 1)
    eq(out2, "[-@chen2020]", "narrative -> suppress")
    local out3 = cycle(out2 .. " Next.", 1)
    eq(out3, "[@chen2020]", "suppress -> parenthetical")
end

print("== locator survives the swap ==")
do
    local out = cycle("see [@chen2020, p. 14] here.")
    eq(out, "@chen2020 [p. 14]", "parenthetical+locator -> narrative")
    local out2 = cycle(out .. " more.", 1)
    eq(out2, "[-@chen2020, p. 14]", "narrative+locator -> suppress")
    local out3 = cycle(out2 .. " more.", 1)
    eq(out3, "[@chen2020, p. 14]", "suppress+locator -> parenthetical")
end

print("== prefix and suffix survive ==")
do
    local g = cluster.group_at("[see @chen2020, p. 3, for a review]", 10)
    local items = cluster.parse_body(g.body)
    eq(#items, 1, "one item")
    eq(items[1].prefix, "see", "prefix parsed")
    eq(items[1].locator, "p. 3", "locator parsed")
    eq(items[1].suffix, "for a review", "suffix parsed")
    local round = cluster.render(g, items, "parenthetical")
    eq(round, "[see @chen2020, p. 3, for a review]", "parenthetical round trip")
end

print("== clusters ==")
do
    local line = "Both [@chen2020; -@wang2021] hold."
    local g = cluster.group_at(line, 8)
    local items = cluster.parse_body(g.body)
    eq(#items, 2, "two items")
    eq(items[2].suppress, true, "second item suppresses author")
    local out = cycle(line)
    eq(out, "@chen2020; [-@wang2021]", "cluster -> narrative form")
end

print("== bare in-text citation is detected ==")
do
    local line = "As @chen2020 shows, the effect is real."
    local g = cluster.group_at(line, 5)
    eq(g ~= nil, true, "group found")
    eq(g.bracketed, false, "not bracketed")
    eq(cluster.mode_of(g, cluster.parse_body(g.body)), "narrative", "mode = narrative")
end

print("== missing year / fallbacks ==")
do
    local g = cluster.group_at("[@chen2020, pp. 3-4]", 4)
    local items = cluster.parse_body(g.body)
    eq(items[1].locator, "pp. 3-4", "page range locator")
    eq(require("zotcite_extra.csl").format_locator("pp. 3-4"), "pp. 3-4", "locator label kept")
    eq(require("zotcite_extra.csl").format_locator("3-4"), "pp. 3-4", "range -> pp.")
    eq(require("zotcite_extra.csl").format_locator("14"), "p. 14", "single -> p.")
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
