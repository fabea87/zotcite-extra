-- Headless spec:  nvim --headless -l tests/numeric_spec.lua
-- Numeric CSL styles (document-order numbering) + :ZNormalize canonicalisation.
-- Pure logic: no Zotero needed.
vim.opt.rtp:append(vim.fn.getcwd())
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.cmd("enew")
vim.bo.filetype = "markdown"

local failed, passed = 0, 0
local function eq(got, want, label)
    if got == want then passed = passed + 1; print("  ok   " .. label)
    else failed = failed + 1
        print(string.format("  FAIL %s\n         got  %q\n         want %q", label, tostring(got), tostring(want)))
    end
end

local numeric = require("zotcite_extra.numeric")
local cluster = require("zotcite_extra.cluster")

print("== number ranges ==")
do
    eq(numeric.format_numbers({ 1 }), "1", "single")
    eq(numeric.format_numbers({ 2, 1 }), "1, 2", "sorted, two")
    eq(numeric.format_numbers({ 1, 2, 3 }), "1–3", "three collapse")
    eq(numeric.format_numbers({ 1, 3, 4, 5, 9 }), "1, 3–5, 9", "range inside a list")
    eq(numeric.format_numbers({ 1, 2, 3, 4 }), "1–4", "four collapse")
    eq(numeric.format_numbers({ 2, 2, 2 }), "2", "duplicates dropped")
    eq(numeric.format_numbers({}), "", "empty")
    eq(numeric.format_numbers({ 1, 2 }, 2), "1–2", "min_range 2")
end

print("== numeric detection ==")
do
    eq(numeric.is_numeric("1"), true, "bare number")
    eq(numeric.is_numeric("[2]"), true, "bracketed")
    eq(numeric.is_numeric("(Author, 2020)"), false, "author-date")
    eq(numeric.is_numeric("Author (2020)"), false, "narrative")
    eq(numeric.is_numeric("2020"), false, "a year is not a citation number")
    eq(numeric.is_numeric(""), false, "empty")
end

print("== cluster text ==")
do
    local map = { a2020 = 1, b2021 = 2, c2022 = 3, z2029 = 12 }
    local function it(key, loc) return { key = key, locator = loc } end
    eq(numeric.cluster_text({ it("a2020") }, map), "[1]", "single")
    eq(numeric.cluster_text({ it("a2020"), it("b2021") }, map), "[1, 2]", "two items")
    eq(numeric.cluster_text({ it("a2020"), it("b2021"), it("c2022") }, map), "[1–3]", "range")
    eq(numeric.cluster_text({ it("z2029"), it("a2020") }, map), "[1, 12]", "sorts numerically")
    eq(numeric.cluster_text({ it("a2020", "p.3") }, map), "[1, p. 3]", "locator canonicalised")
    eq(numeric.cluster_text({ it("a2020"), it("b2021", "pp.3-4") }, map), "[1, 2, pp. 3–4]",
        "one locator for the cluster")
    eq(numeric.cluster_text({ it("a2020", "p. 3"), it("b2021", "p. 9") }, map),
        "[1, p. 3; 2, p. 9]", "a locator per item")
    eq(numeric.cluster_text({ it("a2020") }, map, { bracket = false }), "1", "no brackets")
    eq(numeric.cluster_text({ it("nope2019") }, map), "", "unknown key contributes nothing")
end

print("== bibliography markers ==")
do
    local cfg = require("zotcite_extra.config")
    cfg.get().numeric.marker = "[%d] "
    eq(numeric.bib_marker(7), "[7] ", "default marker")
    cfg.get().numeric.marker = "%d. "
    eq(numeric.bib_marker(7), "7. ", "custom marker")
    cfg.get().numeric.marker = "[%d] "
end

print("== :ZNormalize ==")
do
    local cases = {
        { "see [@a2020;@b2021].", "see [@a2020; @b2021]." },
        { "As @a2020[p.3] shows", "As @a2020 [p. 3] shows" },
        { "[@a2020,p.4]", "[@a2020, p. 4]" },
        { "[see @a2020, p. 3, for a review]", "[see @a2020, p. 3, for a review]" },
        { "[@a2020; -@b2021]", "[@a2020; -@b2021]" },
        { "[@ a2020 ]", "[@a2020]" },
        { "no [keyword] here", "no [keyword] here" },
        { "[@a2020, pp.3-4]", "[@a2020, pp. 3–4]" },
    }
    for _, c in ipairs(cases) do
        local out = cluster.normalize_line(c[1])
        eq(out, c[2], "normalize " .. c[1])
    end
    local _, n = cluster.normalize_line("already fine [@a2020]")
    eq(n, 0, "canonical text reports no change")
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
