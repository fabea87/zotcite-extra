--- Reference picker with two search modes.
---
---   metadata  the library, fuzzy-matched on author/year/title/citekey (sqlite)
---   semantic  ZotSeek's embeddings inside Zotero (`/zotseek/search`)
---
--- The two modes are visually distinct on purpose: semantic mode wears an amber
--- frame plus a source badge and a similarity column, metadata mode keeps the
--- plain Telescope look and shows the citekey instead.
---
--- Telescope is the picker (both search modes). `vim.ui.select` remains only as
--- a dependency-free fallback for setups without telescope — metadata mode,
--- single selection.
--- Keys: <CR> parenthetical, <C-n> narrative, <C-y> year only, <C-l> locator,
--- <Tab> multi-select, <C-o> open the document, <Esc>/<C-c> cancel,
--- <C-s> switch search mode, <C-h> semantic+keyword (hybrid), <C-r> re-query.
local cfg = require("zotcite_extra.config")

local M = {}

local ns_semantic

--- Amber frame + coloured scores for semantic mode, so it can never be confused
--- with the plain metadata list.
function M.setup_hl()
    local function hl(name, val) vim.api.nvim_set_hl(0, name, val) end
    hl("ZotciteExtraSemStrong", { link = "DiagnosticOk", default = true })
    hl("ZotciteExtraSemMid", { link = "DiagnosticWarn", default = true })
    hl("ZotciteExtraSemWeak", { link = "Comment", default = true })
    hl("ZotciteExtraSemBadge", { link = "Identifier", default = true })
    hl("ZotciteExtraCiteKey", { link = "Comment", default = true })
    hl("ZotciteExtraSemTitle", { fg = "#ffc600", bold = true, default = true })
    hl("ZotciteExtraSemBorder", { fg = "#ffc600", default = true })
    hl("ZotciteExtraMetaTitle", { link = "TelescopeResultsTitle", default = true })

    ns_semantic = vim.api.nvim_create_namespace("zotcite_extra_picker_semantic")
    local function ns(name, val) vim.api.nvim_set_hl(ns_semantic, name, val) end
    ns("TelescopePromptTitle", { link = "ZotciteExtraSemTitle" })
    ns("TelescopeResultsTitle", { link = "ZotciteExtraSemTitle" })
    ns("TelescopePreviewTitle", { link = "ZotciteExtraSemTitle" })
    ns("TelescopePromptBorder", { link = "ZotciteExtraSemBorder" })
    ns("TelescopeResultsBorder", { link = "ZotciteExtraSemBorder" })
    ns("TelescopePreviewBorder", { link = "ZotciteExtraSemBorder" })
    ns("TelescopeBorder", { link = "ZotciteExtraSemBorder" })
end

local function post(action, refs, opts)
    vim.schedule(function() action(refs, opts or {}) end)
end

--- Collapse whitespace: abstracts/titles/snippets carry hard line breaks, which
--- virt_text and nvim_buf_set_lines both reject.
local function one_line(s)
    return (tostring(s or ""):gsub("%s+", " "))
end

--------------------------------------------------------------------- metadata --

local function year_of(rec)
    local y = rec.date and tostring(rec.date):match("(%d%d%d%d)")
    if y then return y end
    local d = rec.issued and rec.issued["date-parts"]
    if d and d[1] then return tostring(d[1][1] or "") end
    return ""
end

local function line_of(rec)
    local data = require("zotcite_extra.data")
    local authors = ""
    if type(rec.alastnm) == "table" then
        authors = table.concat(rec.alastnm, " & ")
    elseif type(rec.alastnm) == "string" then
        authors = rec.alastnm
    end
    if authors == "" then
        local ok, lbl = pcall(data.label, rec)
        if ok then authors = lbl:match("^(.-)%s*%(") or "" end
    end
    return string.format("%s (%s) %s", authors, year_of(rec), one_line(rec.title)), one_line(authors)
end

local function venue_of(rec)
    for _, f in ipairs({ "publicationTitle", "bookTitle", "proceedingsTitle", "conferenceName",
        "websiteTitle", "blogTitle", "dictionaryTitle", "encyclopediaTitle", "programTitle",
        "series", "publisher" }) do
        if rec[f] and rec[f] ~= "" then return rec[f] end
    end
    return nil
end

local function sort_key(rec)
    local d
    if rec.date then d = tostring(rec.date) end
    if not d then
        local parts = rec.issued and rec.issued["date-parts"]
        if parts and parts[1] then
            d = string.format("%04d-%02d-%02d", tonumber(parts[1][1]) or 0,
                tonumber(parts[1][2]) or 0, tonumber(parts[1][3]) or 0)
        end
    end
    return d or "0000-00-00"
end

--- Candidates for metadata mode: the whole library, newest first.
--- @return table[] entries, string source
local function metadata_entries(pattern)
    local o = cfg.get()
    local out = {}
    local recs
    local ok, complete = pcall(require, "zotcite_extra.complete")
    if ok then recs = complete.records() end
    if recs and #recs > 0 then
        for _, rec in ipairs(recs) do
            if rec.citekey then
                local line, authors = line_of(rec)
                out[#out + 1] = {
                    citekey = rec.citekey,
                    zotkey = rec.zotkey,
                    rec = rec,
                    authors = authors,
                    year = year_of(rec),
                    line = line,
                    sort_key = sort_key(rec),
                }
            end
        end
        table.sort(out, function(a, b) return a.sort_key > b.sort_key end)
        return out, "zotcite"
    end

    local api = require("zotcite_extra.api")
    for _, it in ipairs(api.search(pattern or "", { limit = o.picker_limit > 0 and o.picker_limit or 25 })) do
        local citekey = it.bbt or it.key
        local d = it.data or {}
        local authors = ""
        if type(d.creators) == "table" and d.creators[1] then
            authors = d.creators[1].lastName or d.creators[1].name or ""
            if #d.creators > 2 then authors = authors .. " et al." end
        end
        local year = tostring(d.date or ""):match("(%d%d%d%d)") or ""
        out[#out + 1] = {
            citekey = citekey,
            zotkey = it.key,
            authors = authors,
            year = year,
            line = string.format("%s (%s) %s", authors, year, one_line(d.title or citekey)),
            api = it,
        }
    end
    return out, "api"
end

M.metadata_entries = metadata_entries

--- Backwards-compatible alias (used by :ZPing/:ZDoctor style probes and specs).
--- @return table[] entries, string source
M.entries = metadata_entries

--------------------------------------------------------------------- previews --

local function metadata_preview(e)
    local rec = e.rec or (e.api and e.api.data) or {}
    local lines = {}
    local function add(s)
        s = one_line(s)
        if s ~= "" then lines[#lines + 1] = s end
    end
    add(string.format("%s (%s)", e.authors or "", e.year or ""))
    add(rec.title or e.line)
    add(venue_of(rec))
    add(rec.volume and ("Volume " .. tostring(rec.volume)) or nil)
    if rec.DOI then add("doi:" .. tostring(rec.DOI)) end
    if rec.url and rec.url ~= "" then add(tostring(rec.url)) end
    add(string.rep("─", 40))
    for _, para in ipairs(vim.split(one_line(rec.abstractNote or rec.abstract or "No abstract available."),
        "\r?\n")) do
        add(para)
    end
    add(string.rep("─", 40))
    add("citekey: " .. tostring(e.citekey))
    return lines
end

local function semantic_preview(e)
    local lines = {}
    local function add(s)
        s = one_line(s)
        if s ~= "" then lines[#lines + 1] = s end
    end
    add(string.format("◆ ZotSeek match — similarity %.0f%% (%s)", (e.score or 0) * 100,
        e.source ~= "" and e.source or "?"))
    add(string.rep("─", 40))
    add(string.format("%s (%s)", e.authors or "", e.year or ""))
    add(e.title or e.line)
    add(string.rep("─", 40))
    add("matched passage" .. (e.page and (" (p. " .. tostring(e.page) .. ")") or ""))
    for _, para in ipairs(vim.split(e.snippet or "No snippet available.", "\r\n")) do
        add(para)
    end
    add(string.rep("─", 40))
    add("citekey: " .. tostring(e.citekey) .. (e.unresolved and "  (no better-bibtex key!)" or ""))
    return lines
end

------------------------------------------------------------------- separator --

local function source_badge(e)
    local s = e.source or ""
    if s == "both" then return { "≡", "ZotciteExtraSemStrong" } end
    if s == "semantic" then return { "◈", "ZotciteExtraSemBadge" } end
    if s == "keyword" then return { "⌕", "ZotciteExtraSemWeak" } end
    return { "·", "ZotciteExtraSemWeak" }
end

local function score_hl(score)
    if score >= 0.8 then return "ZotciteExtraSemStrong" end
    if score >= 0.6 then return "ZotciteExtraSemMid" end
    return "ZotciteExtraSemWeak"
end

--- Open the picker.
--- @param opts { mode?: string, search?: "metadata"|"semantic", pattern?: string,
---               footnote?: boolean, replace?: table, resume_insert?: boolean }
function M.open(opts)
    opts = opts or {}
    local conf = cfg.get()
    local semantic = require("zotcite_extra.semantic")
    local search = opts.search or conf.semantic_mode_default or "metadata"
    local sem_ok, sem_why = semantic.available()
    if search == "semantic" and not sem_ok then
        vim.notify("[zotcite-extra] " .. tostring(sem_why) .. " — using metadata search",
            vim.log.levels.WARN)
        search = "metadata"
    end

    local kind = conf.picker
    if kind == "fzf-lua" then kind = nil end -- removed backend: treat as telescope
    local has_telescope = pcall(require, "telescope")

    if (kind == nil or kind == "telescope") and has_telescope then
        return M.open_telescope(opts, search, semantic)
    end
    if search == "semantic" then
        vim.notify("[zotcite-extra] semantic search needs telescope — using metadata search",
            vim.log.levels.WARN)
        search = "metadata"
    end

    local list, _ = metadata_entries(opts.pattern)
    if #list == 0 then
        vim.notify("[zotcite-extra] no reference matched"
            .. (opts.pattern and (" '" .. opts.pattern .. "'") or ""), vim.log.levels.WARN)
        return
    end
    local by_key = {}
    for _, e in ipairs(list) do by_key[e.citekey] = e end
    local lines = {}
    for _, e in ipairs(list) do table.insert(lines, e.line .. "  " .. e.citekey) end

    local insert_mod = require("zotcite_extra.insert")

    -- last resort
    vim.ui.select(lines, { prompt = "Zotero" }, function(choice)
        if not choice then return end
        local key = choice:match("(%S+)%s*$")
        local e = key and by_key[key]
        if e then
            post(function()
                insert_mod.cite({ { citekey = e.citekey, zotkey = e.zotkey } }, {
                    mode = opts.mode,
                    replace = opts.replace,
                    resume_insert = opts.resume_insert,
                })
            end)
        end
    end)
end

-------------------------------------------------------------------- telescope --

--- @param opts table
--- @param search "metadata"|"semantic"
--- @param semantic table the semantic module
function M.open_telescope(opts, search, semantic)
    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")
    local previewers = require("telescope.previewers")
    local sorters = require("telescope.sorters")
    local entry_display = require("telescope.pickers.entry_display")
    local insert_mod = require("zotcite_extra.insert")

    local data = require("zotcite_extra.data")
    local semantic_hybrid = opts.hybrid == true

    -- metadata list is only built in metadata mode (no 3000-row scan otherwise)
    local list, source = {}, "semantic"
    local by_line = {}
    if search == "metadata" then
        list, source = metadata_entries(opts.pattern)
        if #list == 0 then
            vim.notify("[zotcite-extra] no reference matched"
                .. (opts.pattern and (" '" .. opts.pattern .. "'") or ""), vim.log.levels.WARN)
            return
        end
        for _, e in ipairs(list) do by_line[e.line] = e end
    end

    local function pick(chosen, mode, extra)
        local refs = {}
        for _, e in ipairs(chosen or {}) do
            if e and e.citekey then
                if e.unresolved then
                    vim.notify("[zotcite-extra] " .. e.zotkey .. " has no better-bibtex citekey;"
                        .. " inserting the Zotero key", vim.log.levels.WARN)
                end
                table.insert(refs, { citekey = e.citekey, zotkey = e.zotkey })
            end
        end
        if #refs == 0 then return end
        local o = vim.tbl_extend("force", {
            mode = mode,
            footnote = opts.footnote,
            resume_insert = opts.resume_insert,
        }, extra or {})
        if o.mode == nil then o.mode = opts.mode end
        if opts.replace then o.replace = opts.replace end
        if o.locator_prompt then
            o.locator_prompt = nil
            vim.ui.input({ prompt = "Locator (p. 42): " }, function(loc)
                o.locator = loc
                vim.schedule(function() insert_mod.cite(refs, o) end)
            end)
            return
        end
        vim.schedule(function() insert_mod.cite(refs, o) end)
    end

    ------------------------------------------------------------------ finders --

    local meta_display = entry_display.create({
        separator = " ",
        items = { { width = 22 }, { width = 6 }, { remaining = true } },
    })
    -- badge · authors · (year) · similarity · title, so the score stays visible
    -- even in a narrow results pane
    local sem_display = entry_display.create({
        separator = " ",
        items = { { width = 3 }, { width = 14 }, { width = 6 }, { width = 4 }, { remaining = true } },
    })

    local function meta_entry(e)
        return {
            value = e,
            display = function(entry)
                local ev = entry.value
                return meta_display({
                    { ev.authors, "Identifier" },
                    { "(" .. (ev.year or "") .. ")", "Number" },
                    { one_line(ev.rec and ev.rec.title or ev.line), "Title" },
                })
            end,
            ordinal = one_line(table.concat({
                e.authors or "", e.year or "", (e.rec and e.rec.title) or "", e.citekey or "",
            }, " ")),
            citekey = e.citekey,
        }
    end

    local function sem_entry(e)
        local badge, badge_hl = unpack(source_badge(e))
        return {
            value = e,
            display = function(entry)
                local ev = entry.value
                return sem_display({
                    { badge, badge_hl },
                    { ev.authors, "Identifier" },
                    { "(" .. (ev.year or "") .. ")", "Number" },
                    { string.format("%.2f", ev.score or 0), score_hl(ev.score or 0) },
                    { ev.title ~= "" and ev.title or ev.line, "Title" },
                })
            end,
            ordinal = one_line((e.title or e.line) .. " " .. (e.authors or "")),
            citekey = e.citekey,
        }
    end

    local finder, sorter, title, results_title, prompt_title, enter_preview
    local static = opts.entries or opts.similar

    if search == "semantic" and static then
        -- a fixed list (e.g. "papers similar to this one"): filter, don't query
        finder = finders.new_table({ results = static, entry_maker = sem_entry })
        sorter = conf.generic_sorter({})
        title = "semantic"
        results_title = opts.results_title or "ZotSeek · similar"
        prompt_title = "◆ ZotSeek"
        enter_preview = semantic_preview
    elseif search == "semantic" then
        local pconf = cfg.get().semantic or {}
        local last_prompt, cached = nil, {}
        finder = finders.new_dynamic({
            fn = function(prompt)
                prompt = vim.trim(prompt or "")
                if prompt == last_prompt then return cached end
                local entries, err = semantic.query(prompt, {
                    top_k = pconf.top_k,
                    min_similarity = pconf.min_similarity,
                    mode = semantic_hybrid and "hybrid" or "semantic",
                    bypass_cache = semantic_hybrid,
                })
                last_prompt = prompt
                cached = entries or {}
                if err then
                    vim.notify("[zotcite-extra] semantic search: " .. tostring(err),
                        vim.log.levels.WARN)
                end
                return cached
            end,
            entry_maker = sem_entry,
        })
        sorter = sorters.empty()
        title = "semantic"
        results_title = string.format("ZotSeek · %s", semantic_hybrid and "hybrid" or "semantic")
        prompt_title = "◆ ZotSeek"
        enter_preview = semantic_preview
    else
        finder = finders.new_table({ results = list, entry_maker = meta_entry })
        sorter = conf.generic_sorter({})
        title = "metadata"
        results_title = "Zotero · " .. source
        prompt_title = "Zotero"
        enter_preview = metadata_preview
    end

    local picker = pickers.new({}, {
        prompt_title = prompt_title,
        results_title = results_title,
        preview_title = search == "semantic" and "Semantic match" or "Abstract",
        default_text = opts.pattern,
        initial_mode = "insert",
        -- semantic search costs an HTTP round trip: query when typing pauses
        debounce = search == "semantic" and 250 or nil,
        finder = finder,
        sorter = sorter,
        layout_strategy = "horizontal",
        layout_config = {
            width = 0.95,
            height = 0.85,
            horizontal = { preview_width = 0.55, preview_cutoff = 80 },
            vertical = { preview_cutoff = 80 },
        },
        previewer = previewers.new_buffer_previewer({
            title = search == "semantic" and "Semantic match" or "Abstract",
            define_preview = function(self, entry)
                vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false,
                    enter_preview(entry.value))
                vim.wo[self.state.winid].wrap = true
                vim.wo[self.state.winid].linebreak = true
                if search == "semantic" then
                    vim.api.nvim_buf_add_highlight(self.state.bufnr,
                        vim.api.nvim_create_namespace("zotcite_extra_sem_preview"),
                        "ZotciteExtraSemTitle", 0, 0, -1)
                end
            end,
        }),
        attach_mappings = function(prompt_bufnr, map)
            local function selected()
                local chosen = {}
                local cur = action_state.get_current_picker(prompt_bufnr)
                for _, sel in ipairs(cur:get_multi_selection()) do
                    local e = sel.value or sel
                    if e then chosen[#chosen + 1] = e end
                end
                local single = action_state.get_selected_entry()
                if #chosen == 0 and single and single.value then chosen[1] = single.value end
                return chosen
            end

            local function take(mode, extra)
                local chosen = selected()
                actions.close(prompt_bufnr)
                pick(chosen, mode, extra or {})
            end

            local function reopen(changes)
                local line = action_state.get_current_line() or ""
                local carried = vim.tbl_extend("force", vim.deepcopy(opts), changes or {})
                carried.pattern = line
                actions.close(prompt_bufnr)
                vim.schedule(function() M.open(carried) end)
            end

            map("i", "<CR>", function() take(nil) end)
            map("i", "<C-n>", function() take("narrative") end)
            map("i", "<C-y>", function() take("suppress") end)
            map("i", "<C-l>", function() take(nil, { locator_prompt = true }) end)
            map("i", "<Tab>", actions.toggle_selection + actions.move_selection_next)
            map("i", "<S-Tab>", actions.toggle_selection + actions.move_selection_previous)

            -- look at the document without leaving the picker: semantic hits open
            -- the matched page, metadata hits go through the same Zotero-first
            -- chain as <leader>zo
            map("i", "<C-o>", function()
                local single = action_state.get_selected_entry()
                local e = single and single.value
                if not e then return end
                local att = require("zotcite_extra.attachment")
                if e.open_pdf then
                    att.launch(e.open_pdf)
                elseif e.zotkey then
                    att.open_item(e.zotkey)
                else
                    vim.notify("[zotcite-extra] this entry has no Zotero item", vim.log.levels.WARN)
                end
            end)

            -- the mode switch: same prompt, other engine
            map("i", "<C-s>", function()
                reopen({ search = search == "semantic" and "metadata" or "semantic" })
            end)
            if search == "semantic" then
                -- semantic only / semantic + keyword (slower, exact word coverage)
                map("i", "<C-h>", function() reopen({ search = "semantic", hybrid = not semantic_hybrid }) end)
                map("i", "<C-r>", function()
                    actions.close(prompt_bufnr)
                    vim.schedule(function() M.open(opts) end)
                end)
            end

            local function cancel()
                actions.close(prompt_bufnr)
                local rep = opts.replace
                if not (opts.resume_insert and rep and rep.row and rep.end0) then return end
                vim.schedule(function()
                    local line = vim.api.nvim_buf_get_lines(0, rep.row - 1, rep.row, false)[1] or ""
                    if vim.fn.mode():match("^[iR]") then
                        pcall(vim.api.nvim_win_set_cursor, 0,
                            { rep.row, math.min(rep.end0, #line) })
                    else
                        pcall(vim.api.nvim_win_set_cursor, 0,
                            { rep.row, math.max(0, math.min(rep.end0 - 1, #line - 1)) })
                        vim.api.nvim_feedkeys("a", "n", false)
                    end
                end)
            end
            map("i", "<Esc>", cancel)
            map("i", "<C-c>", cancel)
            return true
        end,
    })

    picker:find()

    -- amber frame in semantic mode: window-scoped highlights
    if search == "semantic" and ns_semantic then
        vim.schedule(function()
            for _, win in ipairs({ picker.prompt, picker.results, picker.preview }) do
                local id = win and win.winid
                if id and vim.api.nvim_win_is_valid(id) then
                    pcall(vim.api.nvim_win_set_hl_ns, id, ns_semantic)
                end
            end
        end)
    end
    return title
end

return M
