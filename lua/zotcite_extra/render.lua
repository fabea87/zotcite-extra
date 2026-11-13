--- In-buffer rendering: replace the pandoc syntax with Zotero's own CSL text
--- (the nvim equivalent of the ONLYOFFICE plugin's live citation field).
--- The underlying text stays `[@key]`, so the swap between modes is lossless.
local cfg = require("zotcite_extra.config")
local cluster = require("zotcite_extra.cluster")

local M = {}

local ns = vim.api.nvim_create_namespace("zotcite_extra_cite")
local enabled = true
--- buffers explicitly attached by zotcite-extra (markdown by default, anything
--- after :ZAttach)
local attached_bufs = {}
local timer
local pending = {}

M.namespace = ns

function M.enabled()
    return enabled
end

function M.setup_hl()
    vim.api.nvim_set_hl(0, "ZotciteExtraCite", { link = "@markup.link", default = true })
    vim.api.nvim_set_hl(0, "ZotciteExtraMissing", { link = "DiagnosticWarn", default = true })
end

local function attached(bufnr)
    bufnr = bufnr or 0
    if attached_bufs[bufnr] ~= nil then return attached_bufs[bufnr] end
    return cfg.is_markdown(bufnr)
end

--- Collect citation groups in a line range, in document order.
--- @return table[] { row, group, items, keys }
function M.collect(bufnr, first, last)
    bufnr = bufnr or 0
    first = first or 0
    last = last or (vim.api.nvim_buf_line_count(bufnr) - 1)
    local lines = vim.api.nvim_buf_get_lines(bufnr, first, last + 1, false)
    local out = {}
    for i, line in ipairs(lines) do
        for _, g in ipairs(cluster.groups_on_line(line)) do
            local items = cluster.items_of(g)
            local keys = {}
            for _, it in ipairs(items) do
                local k = it.key:gsub("^%-", "")
                if k ~= "" then table.insert(keys, k) end
            end
            if #keys > 0 then
                table.insert(out, { row = first + i - 1, group = g, items = items, keys = keys })
            end
        end
    end
    return out
end

--- Are we in a mode where the text under the cursor must stay raw?
local function typing()
    return vim.fn.mode():match("^[iR]") ~= nil
end

M.typing = typing

--- Cursor row (0-based) / col of this buffer, or nil when it is not shown.
local function cursor_pos(bufnr)
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) ~= bufnr then return nil end
    local pos = vim.api.nvim_win_get_cursor(win)
    return pos[1] - 1, pos[2]
end

--- Can extmark conceal be *displayed* right now?
--- nvim hides all conceal in a mode that 'concealcursor' does not list, but an
--- inline virt_text is still drawn — the raw `[@key]` would stay on screen
--- next to the rendered text. So insert-mode rendering needs 'i'.
function M.insert_conceal_ok()
    return (vim.wo.concealcursor or ""):find("i", 1, true) ~= nil
end

--- Make insert-mode conceal possible in this window (idempotent).
--- Rendering a citation must never force the user out of insert mode, so 'i'
--- is added to 'concealcursor' for the window showing an attached buffer.
function M.ensure_conceal_cursor()
    if M.insert_conceal_ok() then return end
    vim.wo.concealcursor = (vim.wo.concealcursor or "") .. "i"
end

--- Render the visible window.
function M.update(bufnr)
    bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
    if not enabled or not vim.api.nvim_buf_is_valid(bufnr) then return end
    if not attached(bufnr) then return end
    -- rendering must never force the user out of insert mode
    if cfg.get().insert_conceal and bufnr == vim.api.nvim_get_current_buf() then
        pcall(M.ensure_conceal_cursor)
    end

    local typing_now = typing()
    if typing_now and not M.insert_conceal_ok() then return end

    local crow, ccol = cursor_pos(bufnr)
    -- Concealing the group the cursor sits in would rewrite the characters
    -- under the cursor mid-word; every *other* group is fair game, so a
    -- citation picked a second ago renders without leaving insert mode.
    local guard = typing_now and crow ~= nil

    local win = vim.api.nvim_get_current_win()
    local first, last
    if vim.api.nvim_win_get_buf(win) == bufnr then
        first = vim.fn.line("w0", win) - 1
        last = vim.fn.line("w$", win) - 1
    else
        first, last = 0, vim.api.nvim_buf_line_count(bufnr) - 1
    end

    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    local groups = M.collect(bufnr, first, last)
    if #groups == 0 then return end

    local data = require("zotcite_extra.data")
    local api = require("zotcite_extra.api")

    -- citekey -> zotero key, and the batched citation lookup
    local map, missing = {}, {}
    for _, g in ipairs(groups) do
        for _, k in ipairs(g.keys) do
            if not map[k] then
                local zk = data.zotkey(k)
                if zk then
                    map[k] = zk
                else
                    missing[k] = true
                end
            end
        end
    end

    local zkeys = {}
    for _, zk in pairs(map) do table.insert(zkeys, zk) end
    local citations = #zkeys > 0 and api.citation_map(zkeys) or {}

    -- numeric styles: Zotero numbers every item "1", so the document order has
    -- to supply the numbers (see numeric.lua)
    local numeric = require("zotcite_extra.numeric")
    local force = (cfg.get().numeric or {}).force
    local is_numeric = force == "numeric"
    if not force then
        for _, zk in ipairs(zkeys) do
            local t = citations[zk]
            if t and t ~= "" then
                is_numeric = numeric.is_numeric(t)
                break
            end
        end
    end
    local numbering = is_numeric and numeric.numbering(bufnr) or nil

    for _, g in ipairs(groups) do
        local items = {}
        local ok_all = true
        for _, it in ipairs(g.items) do
            local k = it.key:gsub("^%-", "")
            local zk = map[k]
            if not zk or not citations[zk] then
                ok_all = false
                break
            end
            local rec = data.by_citekey(k)
            local item = {
                key = zk,
                citation = citations[zk],
                bbt = k,
                data = {
                    title = rec and rec.title,
                    date = rec and rec.date,
                    creators = rec and data.creators(rec) or nil,
                },
            }
            local mode = cluster.mode_of(g.group, g.items)
            if mode == "suppress" then item.citation = "(" .. (citations[zk]:match("%d%d%d%d%a?") or "") .. ")" end
            table.insert(items, item)
        end

        local mode = cluster.mode_of(g.group, g.items)
        -- the group the cursor is inside (or leaning on) stays raw while typing
        local under_cursor = guard
            and crow == g.row
            and ccol >= g.group.start - 1
            and ccol < g.group["end"]

        local text, hl
        if under_cursor then
            -- nothing to do: leave the raw `@key` alone
        elseif not ok_all then
            -- incomplete or unknown key (typing in progress, typo, or an item
            -- missing from Zotero): keep the raw text readable, just flag it
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, g.row, g.group.start - 1, {
                end_col = g.group["end"],
                hl_group = "ZotciteExtraMissing",
                priority = 110,
            })
        elseif ok_all and is_numeric then
            text, hl = numeric.cluster_text(g.items, numbering), "ZotciteExtraCite"
        elseif ok_all then
            local res = require("zotcite_extra.csl").build(items, {
                mode = mode,
                locator = g.items[1].locator,
                prefix = g.items[1].prefix,
                suffix = g.items[1].suffix,
                sort = false,
            })
            text, hl = res.text, "ZotciteExtraCite"
        end

        if ok_all then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, g.row, g.group.start - 1, {
            end_col = g.group["end"],
            conceal = "",
            virt_text = { { text, hl } },
            virt_text_pos = "inline",
            hl_group = "Comment",
            priority = 110,
        })
        end
    end
end

function M.schedule(bufnr)
    bufnr = bufnr or 0
    pending[bufnr] = true
    if timer then timer:stop() end
    timer = timer or vim.uv.new_timer()
    timer:start(cfg.get().render_debounce_ms, 0, function()
        vim.schedule(function()
            for buf in pairs(pending) do
                pending[buf] = nil
                pcall(M.update, buf)
            end
        end)
    end)
end

--- Render right now: used after a programmatic edit (a picker just closed and
--- nobody is typing), so the citation shows up without an <Esc> round trip.
function M.refresh(bufnr)
    bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
    pending[bufnr] = nil
    vim.schedule(function() pcall(M.update, bufnr) end)
end

function M.toggle()
    enabled = not enabled
    if enabled then
        M.schedule()
    else
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
        end
    end
    vim.notify("[zotcite-extra] rendering " .. (enabled and "on" or "off"), vim.log.levels.INFO)
end

function M.attach(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    attached_bufs[bufnr] = true
    if not attached(bufnr) then return end
    local group = vim.api.nvim_create_augroup("ZotciteExtraRender" .. bufnr, { clear = true })
    for _, ev in ipairs(cfg.get().render_events) do
        vim.api.nvim_create_autocmd(ev, {
            group = group,
            buffer = bufnr,
            callback = function() M.schedule(bufnr) end,
        })
    end
    M.schedule(bufnr)
end

return M
