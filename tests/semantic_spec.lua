-- Headless spec:  nvim --headless -l tests/semantic_spec.lua
-- ZotSeek semantic search: pure payload mapping, highlight setup, and (when
-- ZotSeek is running) one live query.
vim.opt.rtp:append(vim.fn.getcwd())
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.cmd("enew")
vim.bo.filetype = "markdown"

local failed, passed, skipped = 0, 0, 0
local function ok(cond, label)
    if cond then passed = passed + 1; print("  ok   " .. label)
    else failed = failed + 1; print("  FAIL " .. label) end
end
local function skip(label) skipped = skipped + 1; print("  skip " .. label) end

local sem = require("zotcite_extra.semantic")
local picker = require("zotcite_extra.picker")

print("== payload mapping (pure) ==")
do
    local payload = {
        results = {
            {
                itemKey = "AAA11111", title = "Feedback and self-regulated\nlearning",
                authors = "Butler & Winne", year = 1995, semanticScore = 0.857,
                keywordScore = 0.95, source = "both",
                matchedChunk = { snippet = "SRL is a pivot\nupon which achievement turns", page = 3 },
            },
            {
                itemKey = "BBB22222", title = "Second hit", authors = "He et al.",
                year = 2023, score = 0.016, semanticScore = 0.826, source = "semantic",
            },
            -- duplicate of the first hit: deduped
            { itemKey = "AAA11111", title = "dup", semanticScore = 0.5 },
        },
    }
    local resolve = function(zotkey)
        return zotkey == "AAA11111" and "butlerFeedback1995" or "heFeedback2023"
    end
    local entries, unresolved = sem.parse(payload, resolve)
    ok(#entries == 2, "one row per item (duplicate itemKey dropped)")
    ok(entries[1].citekey == "butlerFeedback1995", "zotkey resolved to a citekey")
    ok(entries[2].citekey == "heFeedback2023", "second hit resolved separately")
    ok(entries[1].score > 0.85, "semantic score kept")
    ok(entries[1].source == "both", "source kept")
    ok(not entries[1].title:find("\n"), "title newlines collapsed")
    ok(not entries[1].snippet:find("\n"), "snippet newlines collapsed")
    ok(entries[1].page == 3, "page kept")
    ok(entries[1].line:find("Butler & Winne") ~= nil, "display line built")
    ok(#unresolved == 0, "resolved hits report no problem")

    local raw = sem.parse(payload, nil)
    ok(raw[1].citekey == "AAA11111" and raw[1].unresolved, "no resolver -> zotkey kept, flagged")
end

print("== highlight setup (mode decoration) ==")
do
    picker.setup_hl()
    local function fg(name)
        local hl = vim.api.nvim_get_hl(0, { name = name })
        return hl and (hl.fg or (hl.link and ("link:" .. hl.link))) or nil
    end
    ok(fg("ZotciteExtraSemBorder") ~= nil, "ZotciteExtraSemBorder defined")
    ok(fg("ZotciteExtraSemStrong") ~= nil, "score tiers defined")
    local ns = vim.api.nvim_create_namespace("zotcite_extra_picker_semantic")
    local border = vim.api.nvim_get_hl(ns, { name = "TelescopePromptBorder" })
    ok(border ~= nil and (border.fg ~= nil or border.link ~= nil),
        "semantic namespace overrides TelescopePromptBorder")
    -- applying the namespace is what colours the frame (no getter before nvim 0.13)
    local win = vim.api.nvim_get_current_win()
    ok(pcall(vim.api.nvim_win_set_hl_ns, win, ns), "window accepts the semantic palette")
    pcall(vim.api.nvim_win_set_hl_ns, win, 0)
end

print("== live ZotSeek (optional) ==")
do
    local avail, why = sem.available()
    if not avail then
        skip("ZotSeek not available: " .. tostring(why))
    else
        ok(true, "ZotSeek reachable (" .. sem.status_line() .. ")")
        local t0 = vim.uv.hrtime()
        local entries, err = sem.query("feedback and self-regulated learning", { top_k = 5 })
        local ms = (vim.uv.hrtime() - t0) / 1e6
        ok(err == nil and entries ~= nil, string.format("query returned (%0.f ms)", ms))
        if entries and #entries > 0 then
            ok(#entries <= 5, "top_k respected")
            ok(entries[1].score > 0, "top hit carries a similarity")
            ok(entries[1].citekey ~= nil and entries[1].citekey ~= "", "top hit has a citekey")
            -- cached repeat must be instant
            local t1 = vim.uv.hrtime()
            sem.query("feedback and self-regulated learning", { top_k = 5 })
            local ms2 = (vim.uv.hrtime() - t1) / 1e6
            ok(ms2 < ms / 2 + 5, string.format("repeat served from cache (%0.1f ms)", ms2))
        else
            skip("no hits for the probe query")
        end
    end
end

print("== live :ZSimilar (optional) ==")
do
    local avail = sem.available()
    if not avail then
        skip("ZotSeek not available")
    else
        local entries, err = sem.similar("Q7W45D35", { top_k = 5 })
        ok(err == nil and entries ~= nil, "similar() returned")
        if entries and #entries > 0 then
            ok(#entries <= 5, "top_k respected")
            ok(entries[1].citekey ~= nil and entries[1].citekey ~= "", "hit has a citekey")
            ok(entries[1].authors ~= nil, "authors filled from the local library")
            ok(entries[1].score >= entries[#entries].score, "ordered by similarity")
        else
            skip("no similar items for the probe")
        end
    end
end

print(string.format("\n%d passed, %d failed, %d skipped", passed, failed, skipped))
os.exit(failed == 0 and 0 or 1)
