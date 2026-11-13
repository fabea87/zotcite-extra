-- Headless spec:  nvim --headless -l tests/token_spec.lua
-- Covers: what `<Tab>` considers the half-typed `@token`, and that picking a
-- reference *replaces* that token (including capitals/digits, which zotcite's
-- own scanner ignores) instead of appending after it.
vim.opt.rtp:append(vim.fn.getcwd())
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

vim.cmd("enew")
vim.bo.filetype = "markdown"

local complete = require("zotcite_extra.complete")
local insert = require("zotcite_extra.insert")

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

print("== token scanning ==")
do
    local function tok(line, col)
        local t = complete.token(line, col, 1)
        if not t then return nil end
        return string.format("%s@%d-%d", t.text, t.start0, t.end0)
    end
    -- col is the insert-mode column: one past the last typed byte
    eq(tok("see @ted", 8), "ted@4-8", "lowercase prefix")
    eq(tok("see @ted.", 8), "ted@4-8", "trailing period stays outside the token")
    eq(tok("see @Ted2020", 12), "Ted2020@4-12", "capitals and digits")
    eq(tok("see @pan-dero_x", 15), "pan-dero_x@4-15", "hyphen and underscore")
    eq(tok("@ted", 2), "ted@0-4", "cursor inside the token: whole token wins")
    eq(tok("mail me@example.com", 12), nil, "email is not a citation")
    eq(tok("no citation here", 5), nil, "plain prose")
    eq(tok("@", 1), "@0-1", "bare @ opens the whole library")
end

print("== picking replaces the typed token ==")
do
    local A = { { citekey = "yan2020" } }
    local B = { { citekey = "yan2020" }, { citekey = "wang2021" } }

    --- Insert `refs` at the end of the token, the way the picker does.
    local function pick_into(line, col, refs, opts)
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })
        vim.api.nvim_win_set_cursor(0, { 1, col })
        opts = opts or {}
        opts.replace = complete.token(line, col, 1)
        insert.cite(refs, opts)
        return vim.api.nvim_buf_get_lines(0, 0, -1, false)[1],
            vim.api.nvim_win_get_cursor(0)[2]
    end

    local out, cur = pick_into("see @ted.", 8, A)
    eq(out, "see [@yan2020].", "the typed tail is gone")
    eq(cur, 14, "cursor parked after the cluster (renderer can conceal it)")

    out = pick_into("see @ted.", 8, B)
    eq(out, "see [@yan2020; @wang2021].", "multi-selection = one cluster")

    out = pick_into("see @ted.", 8, A, { mode = "narrative" })
    eq(out, "see @yan2020.", "narrative mode")

    out = pick_into("see @Ted2020.", 12, A)
    eq(out, "see [@yan2020].", "capitals + digits, no leftovers")

    out = pick_into("see @pan-dero.", 13, A)
    eq(out, "see [@yan2020].", "hyphenated prefix, no leftovers")

    out = pick_into("see [see @ted, p. 3] here", 13, A)
    eq(out, "see [see @yan2020, p. 3] here", "inside a cluster: key swapped, locator kept")

    out = pick_into("see [see @ted, p. 3] here", 13, B)
    eq(out, "see [see @yan2020, p. 3; @wang2021] here", "inside a cluster: extras appended")

    out = pick_into("see [@ted] here", 9, A)
    eq(out, "see [@yan2020] here", "single-item cluster rewritten in place")
end

print("== picking next to a finished citation ==")
do
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "as shown [@chen2020]." })
    vim.api.nvim_win_set_cursor(0, { 1, 14 })
    insert.cite({ { citekey = "yan2020" } }, {})
    eq(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1], "as shown [@chen2020; @yan2020].",
        "appends to the cluster under the cursor")
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
