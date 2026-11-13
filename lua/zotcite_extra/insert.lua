--- Insertion / rewriting of pandoc citations in the buffer.
--- This is the nvim counterpart of the ONLYOFFICE plugin's field writer:
--- the "field" is the pandoc group, the "document style" is the YAML `csl:`.
local cfg = require("zotcite_extra.config")
local cluster = require("zotcite_extra.cluster")

local M = {}

local MODES = { "parenthetical", "narrative", "suppress" }

M.MODES = MODES

--- Next mode in the swap cycle.
function M.next_mode(mode)
    local idx = 1
    for i, m in ipairs(MODES) do
        if m == mode then idx = i end
    end
    return MODES[idx % #MODES + 1]
end

--- Apply a mode transition to a parsed item list, in place.
--- `to == "suppress"`   -> every item gets `-`
--- `to == "narrative"`  -> only the head is un-suppressed (it cannot be suppressed)
--- `to == "parenthetical"` -> coming from suppress restores the plain form
function M.apply_mode(items, from, to)
    if to == "suppress" then
        for _, it in ipairs(items) do it.suppress = true end
    elseif to == "narrative" then
        if items[1] then items[1].suppress = false end
    elseif to == "parenthetical" and from == "suppress" then
        for _, it in ipairs(items) do it.suppress = false end
    end
    return items
end

--- Parse the citation under the cursor.
--- @return nil|{ line: integer, group: table, items: table[] }
function M.at_cursor()
    local pos = vim.api.nvim_win_get_cursor(0)
    local row, col = pos[1], pos[2]
    local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""
    local group = cluster.nearest(line, col)
    if not group then return nil end
    local items = cluster.items_of(group)
    return { line = row, group = group, items = items }
end

--- Drop (or rewrite) the half-typed `@token` the picker was opened from, so
--- the chosen citekey replaces what the user typed instead of being appended
--- after it. Two shapes:
---   `@ted|`            -> delete `@ted`, insert the citation there
---   `[see @ted, p. 3]` -> swap the key in place, keep prefix/locator/suffix
--- @param rep { row: integer, start0: integer, end0: integer }
--- @param refs table[] picked references
local function consume_token(rep, refs)
    if not rep or not rep.start0 or not rep.end0 then return end
    local row = rep.row or vim.api.nvim_win_get_cursor(0)[1]
    local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""
    local s0, e0 = rep.start0, rep.end0
    if e0 <= s0 or s0 > #line then return end
    local group = cluster.group_at(line, s0)
    local first = refs[1] and refs[1].citekey
    if group and group.bracketed and first and first ~= "" then
        -- inside a live cluster: only the key changes, everything else stays
        local ks = (line:sub(s0 + 1, s0 + 1) == "@") and s0 + 1 or s0
        vim.api.nvim_buf_set_text(0, row - 1, ks, row - 1, e0, { first })
        vim.api.nvim_win_set_cursor(0, { row, ks + #first })
        return
    end
    vim.api.nvim_buf_set_text(0, row - 1, s0, row - 1, e0, { "" })
    vim.api.nvim_win_set_cursor(0, { row, s0 })
end

--- Merge the picked references into the citation under the cursor (or create
--- a new one). Appending to an existing cluster mirrors how Word/Zotero
--- behave when the cursor sits inside a live citation field.
--- @param refs table[] { citekey = string, zotkey = string, label = string }
--- @param opts { mode?: string, locator?: string, prefix?: string, suffix?: string, footnote?: boolean, force_new?: boolean, replace?: table, resume_insert?: boolean }
function M.cite(refs, opts)
    opts = opts or {}
    if not refs or #refs == 0 then return end
    if opts.replace then consume_token(opts.replace, refs) end
    local at = (not opts.force_new) and M.at_cursor() or nil
    local items = at and vim.deepcopy(at.items) or {}
    local mode = opts.mode

    if not mode then
        if at then
            mode = cluster.mode_of(at.group, items)
        else
            mode = "parenthetical"
        end
    end

    -- append the new keys
    for _, r in ipairs(refs) do
        local exists
        for _, it in ipairs(items) do
            if it.key == r.citekey then exists = it end
        end
        if exists then
            if opts.locator and opts.locator ~= "" then exists.locator = opts.locator end
        else
            table.insert(items, {
                key = r.citekey,
                suppress = (mode == "suppress"),
                locator = nil,
                suffix = nil,
                prefix = nil,
            })
        end
    end

    if opts.locator and opts.locator ~= "" then items[1].locator = opts.locator end
    if opts.prefix and opts.prefix ~= "" then items[1].prefix = opts.prefix end
    if opts.suffix and opts.suffix ~= "" then items[1].suffix = opts.suffix end
    if opts.mode then
        local from = at and cluster.mode_of(at.group, at.items) or nil
        M.apply_mode(items, from, mode)
    elseif items[1] then
        items[1].suppress = (mode == "suppress")
    end

    local group = at and at.group or { bracketed = mode ~= "narrative" }
    local text = cluster.render(group, items, mode)

    if opts.footnote then
        M.insert_footnote(text)
        return
    end

    if at then
        vim.api.nvim_buf_set_text(0, at.line - 1, at.group.start - 1, at.line - 1, at.group["end"], { text })
        -- park the cursor after the cluster: anything inside it stays raw while
        -- the renderer refuses to conceal text under the cursor
        vim.api.nvim_win_set_cursor(0, { at.line, at.group.start - 1 + #text })
    else
        local pos = vim.api.nvim_win_get_cursor(0)
        local row, col = pos[1] - 1, pos[2]
        local line = vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1] or ""
        -- keep the cursor position meaningful: a citation glued to the
        -- preceding word needs a separating space
        local lead = ""
        if col > 0 then
            local before = line:sub(col, col)
            if not before:match("%s") and not text:match("^%s") then lead = " " end
        end
        vim.api.nvim_buf_set_text(0, row, col, row, col, { lead .. text })
        vim.api.nvim_win_set_cursor(0, { pos[1], col + #lead + #text })
    end
    local ok, render = pcall(require, "zotcite_extra.render")
    if not ok then return end
    render.refresh()
    if opts.resume_insert and not vim.fn.mode():match("^[iR]") then
        -- the picker took the window out of insert mode: park the cursor after
        -- the citation and keep writing
        vim.api.nvim_feedkeys("a", "n", false)
        return
    end
    -- 'concealcursor' without 'i' hides nothing in insert mode, so the citation
    -- would stay raw until <Esc>: leave insert mode and let it render now.
    if cfg.get().leave_insert_after_pick and not render.insert_conceal_ok()
        and vim.fn.mode():match("^[iR]") then
        vim.api.nvim_feedkeys(
            vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    end
end

--- `[^zotN]` marker plus its definition at the end of the buffer.
function M.insert_footnote(citation_text)
    local o = cfg.get()
    local n = 1
    local body = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local prefix = o.footnote_prefix
    local used = {}
    for _, l in ipairs(body) do
        local i = l:match("%[%^" .. prefix .. "(%d+)%]")
        if i then used[tonumber(i)] = true end
    end
    while used[n] do n = n + 1 end
    local label = prefix .. n
    local pos = vim.api.nvim_win_get_cursor(0)
    vim.api.nvim_buf_set_text(0, pos[1] - 1, pos[2], pos[1] - 1, pos[2], { "[^" .. label .. "]" })
    local last = vim.api.nvim_buf_line_count(0)
    local tail = vim.api.nvim_buf_get_lines(0, last - 1, last, false)[1] or ""
    local definition = "[^" .. label .. "]: " .. citation_text
    if vim.trim(tail) == "" then
        vim.api.nvim_buf_set_lines(0, last - 1, last, false, { definition })
    else
        vim.api.nvim_buf_set_lines(0, last, last, false, { "", definition })
    end
    vim.api.nvim_win_set_cursor(0, { pos[1], pos[2] + #("[^" .. label .. "]") })
end

--- Cycle parenthetical -> narrative -> suppress -> parenthetical.
--- This is the ONLYOFFICE plugin's Alt+P / Alt+N / Alt+Y, applied to an
--- existing citation instead of a fresh one: nothing is retyped, the locator
--- and the prefix/suffix survive the swap.
function M.cycle_mode()
    local at = M.at_cursor()
    if not at then
        vim.notify("[zotcite-extra] no citation under cursor", vim.log.levels.WARN)
        return
    end
    local from = cluster.mode_of(at.group, at.items)
    local to = M.next_mode(from)
    local items = M.apply_mode(at.items, from, to)
    local text = cluster.render(at.group, items, to)
    vim.api.nvim_buf_set_text(0, at.line - 1, at.group.start - 1, at.line - 1, at.group["end"], { text })
    local ok, render = pcall(require, "zotcite_extra.render")
    if ok then render.refresh() end
    vim.notify("[zotcite-extra] " .. from .. " -> " .. to, vim.log.levels.INFO)
end

--- Set/clear the locator on the first item of the citation under the cursor.
function M.set_locator(loc)
    local at = M.at_cursor()
    if not at then
        vim.notify("[zotcite-extra] no citation under cursor", vim.log.levels.WARN)
        return
    end
    at.items[1].locator = (loc ~= nil and loc ~= "") and loc or nil
    local mode = cluster.mode_of(at.group, at.items)
    local text = cluster.render(at.group, at.items, mode)
    vim.api.nvim_buf_set_text(0, at.line - 1, at.group.start - 1, at.line - 1, at.group["end"], { text })
    local ok, render = pcall(require, "zotcite_extra.render")
    if ok then render.refresh() end
end

--- Remove the citation under the cursor.
function M.remove_citation()
    local at = M.at_cursor()
    if not at then return end
    vim.api.nvim_buf_set_text(0, at.line - 1, at.group.start - 1, at.line - 1, at.group["end"], { "" })
    local ok, render = pcall(require, "zotcite_extra.render")
    if ok then render.refresh() end
end

return M
