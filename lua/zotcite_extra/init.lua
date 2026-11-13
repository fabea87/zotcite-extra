--- zotcite-extra: CSL-grade citations for zotcite.
--- Companion to zotcite: zotcite owns the Zotero database layer, this module
--- adds the Word-integration semantics (mode swapping, locators, live CSL
--- rendering, in-document bibliography, style switching).
local cfg = require("zotcite_extra.config")

local M = {}

M.config = cfg

local function buf()
    return vim.api.nvim_get_current_buf()
end

--- Insert a citation (picker).
--- @param opts { mode?: string, footnote?: boolean, pattern?: string }
--- The text to search for when suggesting citations: the visual selection, or
--- the blank-line-delimited paragraph around the cursor.
--- @return string
function M.paragraph_text()
    local mode = vim.fn.mode()
    if mode:match("^[vV\22]") then
        local saved = vim.fn.getreg("v")
        vim.cmd('noautocmd normal! "vy')
        local text = vim.fn.getreg("v")
        vim.fn.setreg("v", saved)
        return vim.trim((text or ""):gsub("%s+", " "))
    end
    local buf = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local function blank(i)
        local l = lines[i]
        return l == nil or vim.trim(l) == "" or l:match("^#") ~= nil
    end
    local first, last = row, row
    while first > 1 and not blank(first - 1) do first = first - 1 end
    while last < #lines and not blank(last + 1) do last = last + 1 end
    local parts = {}
    for i = first, last do
        local l = lines[i] or ""
        if not l:match("^#") then table.insert(parts, vim.trim(l)) end
    end
    local text = table.concat(parts, " ")
        :gsub("%[%^[^%]]*%]", "")            -- footnotes
        :gsub("%[[^%]]*%]%([^%)]*%)", "%1")   -- markdown links
        :gsub("[*_`]+", "")
        :gsub("%s+", " ")
    text = vim.trim(text)
    -- a long paragraph would swamp the embedding: keep the head
    local max = (cfg.get().semantic or {}).suggest_chars or 600
    if #text > max then text = text:sub(1, max) end
    return text
end

function M.cite(opts)
    opts = opts or {}
    if opts.search == nil then opts.search = nil end
    if not require("zotcite_extra.api").ping() then
        vim.notify("[zotcite-extra] Zotero is not reachable on port " .. cfg.get().port,
            vim.log.levels.ERROR)
        return
    end
    require("zotcite_extra.picker").open(opts)
end

--- Swap the citation under the cursor: (Author, 2020) <-> Author (2020) <-> (2020).
function M.cycle_mode()
    require("zotcite_extra.insert").cycle_mode()
end

function M.set_locator(loc)
    if loc == nil or loc == "" then
        vim.ui.input({ prompt = "Locator: " }, function(v)
            if v then require("zotcite_extra.insert").set_locator(v) end
        end)
        return
    end
    require("zotcite_extra.insert").set_locator(loc)
end

function M.remove_citation()
    require("zotcite_extra.insert").remove_citation()
end

--- Open the document (PDF) of the citation under the cursor, through Zotero.
--- Replaces zotcite's <leader>zo, which needs `attach_dir` for linked files.
--- @param opts? { force?: "system" }
function M.open_attachment(opts)
    require("zotcite_extra.attachment").open_under_cursor(opts)
end

--- Focus the item in Zotero instead of opening its file (`:ZOpen!`).
function M.select_in_zotero()
    local cluster = require("zotcite_extra.cluster")
    local data = require("zotcite_extra.data")
    local pos = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_buf_get_lines(0, pos[1] - 1, pos[1], false)[1] or ""
    local group = cluster.nearest(line, pos[2])
    local citekey = group and cluster.items_of(group)[1] and cluster.items_of(group)[1].key
    local zotkey = citekey and data.zotkey(citekey)
    if not zotkey then
        vim.notify("[zotcite-extra] no citation on this line", vim.log.levels.WARN)
        return
    end
    require("zotcite_extra.attachment").launch(
        require("zotcite_extra.attachment").zotero_url("select", zotkey))
end

function M.bibliography()
    require("zotcite_extra.biblio").update({})
end

--- Show/choose the document CSL style.
function M.style(id)
    local style = require("zotcite_extra.style")
    if id and id ~= "" then
        local ok, err = require("zotcite_extra.api").validate_style(id)
        if not ok then
            vim.notify("[zotcite-extra] invalid style: " .. tostring(err), vim.log.levels.ERROR)
            return
        end
        local applied = style.set(buf(), id)
        vim.notify("[zotcite-extra] style: " .. applied, vim.log.levels.INFO)
        require("zotcite_extra.render").schedule()
        return
    end
    local current = style.get(buf())
    local list = style.available()
    vim.ui.select(list, { prompt = "CSL style (current: " .. tostring(current) .. ")" }, function(choice)
        if choice then M.style(choice) end
    end)
end

function M.toggle_render()
    require("zotcite_extra.render").toggle()
end

function M.ping()
    local api = require("zotcite_extra.api")
    local ok = api.ping()
    local data = require("zotcite_extra.data")
    local info = {
        "Zotero: " .. (ok and "reachable" or "unreachable"),
        "library: " .. cfg.get().library,
        "style: " .. tostring(api.current_style(buf())),
        "zotcite: " .. (data.ready() and "ready" or "not initialised"),
        "Zotero-refs available: " .. tostring(next(data.search("") or {}) ~= nil),
    }
    local compat = require("zotcite_extra.compat")
    local missing = {}
    for _, dep in ipairs(compat.deps) do
        if not compat.probe(dep) then table.insert(missing, dep.mod .. "." .. dep.field) end
    end
    local ok_sem, sem = pcall(require, "zotcite_extra.semantic")
    table.insert(info, ok_sem and sem.status_line() or "semantic: unavailable")
    table.insert(info, string.format("zotcite API: %d/%d present%s",
        #compat.deps - #missing, #compat.deps,
        #missing > 0 and (" (missing: " .. table.concat(missing, ", ") .. ")") or ""))
    vim.notify("[zotcite-extra]\n" .. table.concat(info, "\n"), vim.log.levels.INFO)
end

local attached = {}

--- Is this buffer already set up?
function M.is_attached(bufnr)
    return attached[bufnr or vim.api.nvim_get_current_buf()] == true
end

--- Give zotcite itself a chance to initialise this buffer (it normally does so
--- from its own ftplugin, which does not run for every markdown-ish buffer).
local function ensure_zotcite(bufnr)
    local ok, zcfg = pcall(require, "zotcite.config")
    if not ok or not zcfg or not zcfg.init then return end
    if vim.bo[bufnr].buftype == "nofile" then return end
    local kt = select(2, pcall(zcfg.get_key_type, bufnr))
    if kt == nil then
        vim.schedule(function()
            pcall(function() vim.api.nvim_buf_call(bufnr, zcfg.init) end)
        end)
    end
end

local lsp_booted = {}

--- Make zotcite's completion usable:
---   * nvim 0.12 needs `vim.lsp.completion.enable()` before any insert-mode
---     popup appears — zotcite never calls it, so `@pan` stays silent;
---   * zotcite starts its server from a VimEnter-scheduled `global_init`, which
---     never runs in headless/piped sessions.
function M.bootstrap(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if lsp_booted[bufnr] then return end
    lsp_booted[bufnr] = true
    require("zotcite_extra.data").ensure()
    local ok = pcall(function()
        local running = #vim.lsp.get_clients({ bufnr = bufnr, name = "zotero_ls" })
        if running == 0 then
            vim.api.nvim_buf_call(bufnr, function()
                require("zotcite.lsp").start()
            end)
        end
    end)
    if not ok then return end
    M.enable_completion(bufnr)
end

--- Typing `@` should open the Zotero list immediately.
--- `vim.lsp.completion.enable{autotrigger=true}` only fires on keyword
--- characters, and `@` is none of them, so the key is mapped to insert `@` and
--- ask the server for completions.
--- Is the cursor inside an `@citekey` token (no whitespace since the `@`)?
function M.in_cite_token()
    return require("zotcite_extra.complete").token() ~= nil
end

local function feed(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "n", false)
end

--- <Tab> inside `@key` opens the reference picker, seeded with what has been
--- typed so far; elsewhere it indents as usual. The picker is zotcite-extra's
--- own (telescope, or vim.ui.select without it), because it owns the *insertion*: it
--- replaces the half-typed `@token` and it can take several references at
--- once. zotcite's preview-rich box is still on <C-x><C-b>.
function M.map_at_key(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if vim.b[bufnr].zotcite_extra_at_mapped then return end
    vim.b[bufnr].zotcite_extra_at_mapped = true
    local o = cfg.get()

    if o.tab_completion ~= false then
        vim.keymap.set("i", "<Tab>", function()
            if vim.fn.pumvisible() == 1 then
                feed("<C-n>")
                return
            end
            if M.in_cite_token() then
                if o.tab_uses_picker then
                    local tok = require("zotcite_extra.complete").token()
                    local was_insert = vim.fn.mode():match("^[iR]") ~= nil
                    -- the picker must run outside the mapping's text-lock
                    vim.schedule(function()
                        require("zotcite_extra.picker").open({
                            pattern = tok and tok.text or "",
                            replace = tok,
                            resume_insert = was_insert,
                        })
                    end)
                else
                    feed("<C-x><C-o>")
                end
                return
            end
            feed("<Tab>")
        end, { buffer = bufnr, silent = true, desc = "Zotero citation picker / indent" })

        vim.keymap.set("i", "<S-Tab>", function()
            if vim.fn.pumvisible() == 1 then
                feed("<C-p>")
            else
                feed("<S-Tab>")
            end
        end, { buffer = bufnr, silent = true, desc = "Zotero citation completion (back)" })
    end

    if o.at_trigger then
        vim.keymap.set("i", "@", function()
            feed("@")
            vim.schedule(function()
                if vim.fn.mode():match("^i") then feed("<C-x><C-o>") end
            end)
        end, { buffer = bufnr, silent = true, desc = "Zotero citation completion" })
    end
end

--- Turn on insert-mode completion for zotcite's client in this buffer.
function M.enable_completion(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not (vim.lsp.completion and vim.lsp.completion.enable) then return end
    for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
        if c.name == "zotero_ls" then
            -- kept off on purpose: it cannot filter, our omnifunc does
            pcall(vim.lsp.completion.enable, false, c.id, bufnr)
        end
    end
    vim.bo[bufnr].completeopt = cfg.get().completeopt
    _G.ZotciteExtraOmni = require("zotcite_extra.complete").omnifunc
    vim.bo[bufnr].omnifunc = "v:lua.ZotciteExtraOmni"
    M.map_at_key(bufnr)
end

--- Normal-mode commands for an attached buffer.
--- @param bufnr integer
local function apply_maps(bufnr)
    local o = cfg.get()
    local maps = o.maps or {}
    local function set(lhs, fn, desc)
        if lhs == false then return end
        vim.keymap.set("n", lhs, fn, { buffer = bufnr, desc = desc })
    end
    set(maps.insert or "<leader>zc", function() M.cite() end, "Zotero citation")
    set(maps.narrative or "<leader>zn", function() M.cite({ mode = "narrative" }) end,
        "Narrative citation")
    set(maps.cycle or "<leader>zm", function() M.cycle_mode() end, "Swap citation mode")
    local shadow = o.shadow_zotcite_keys ~= false
    set(shadow and (maps.bib or "<leader>zb") or false, function() M.bibliography() end,
        "Update bibliography")
    set(maps.csl or "<leader>zs", function() M.style() end, "CSL style")
    set(maps.locator or "<leader>zl", function() M.set_locator() end, "Citation locator")
    set(shadow and (maps.open or "<leader>zo") or false, function() M.open_attachment() end,
        "Open the document")
    set(shadow and (maps.open_external or "<leader>zO") or (maps.open_external or "<leader>zO"), function()
        require("zotcite_extra.attachment").open_under_cursor({ force = "system" })
    end, "Open the document in an external app")
    -- zotcite maps <leader>zb to "paste abstract"; we take that key for the
    -- bibliography and keep the abstract on <leader>zA
    set("<leader>zA", function()
        pcall(function() require("zotcite.get").abstract() end)
    end, "Zotcite: paste abstract")
end

--- Attach citations/bindings to a buffer if it is a markdown document.
--- @param bufnr? integer
--- @param force? boolean attach even when the buffer does not look like markdown
--- @return boolean attached_now
function M.maybe_attach(bufnr, force)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) then return false end
    if attached[bufnr] then return false end
    if not force and not cfg.is_markdown(bufnr) then return false end
    attached[bufnr] = true

    local o = cfg.get()
    ensure_zotcite(bufnr)
    vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        pcall(M.bootstrap, bufnr)
        -- zotcite's ftplugin may still register its own z-maps after ours (it is
        -- initialised lazily), so re-apply on the next tick: <leader>zo is our
        -- attachment opener, <leader>zb the bibliography.
        pcall(apply_maps, bufnr)
        -- and tell zotcite where the linked attachments live, so its own
        -- commands stop asking about `attach_dir`
        if cfg.get().sync_zotcite ~= false then
            pcall(require("zotcite_extra.attachment").sync_zotcite)
        end
    end)

    pcall(require("zotcite_extra.render").attach, bufnr)
    apply_maps(bufnr)
    return true
end

function M.setup(opts)
    local o = cfg.setup(opts)
    local api = require("zotcite_extra.api")
    api.clear_cache()
    require("zotcite_extra.render").setup_hl()
    require("zotcite_extra.picker").setup_hl()

    local cmd = vim.api.nvim_create_user_command
    cmd("ZCite", function(a)
        M.cite({ footnote = a.bang })
    end, { bang = true, desc = "Insert a Zotero citation (CSL-formatted)" })

    cmd("ZCiteN", function()
        M.cite({ mode = "narrative" })
    end, { desc = "Insert a narrative citation: Author (Year)" })

    cmd("ZCiteY", function()
        M.cite({ mode = "suppress" })
    end, { desc = "Insert a year-only citation: (Year)" })

    cmd("ZMode", function()
        M.cycle_mode()
    end, { desc = "Swap citation mode under the cursor" })

    cmd("ZLocator", function(a)
        M.set_locator(a.args)
    end, { nargs = "?", desc = "Set the locator of the citation under the cursor" })

    cmd("ZDel", function()
        M.remove_citation()
    end, { desc = "Delete the citation under the cursor" })

    cmd("ZOpen", function(a)
        if a.bang then M.select_in_zotero() else M.open_attachment() end
    end, { bang = true, desc = "Open the PDF of the citation under the cursor (in Zotero)" })

    cmd("ZSemantic", function()
        M.cite({ search = "semantic" })
    end, { desc = "Pick a citation with ZotSeek semantic search" })

    cmd("ZNormalize", function(a)
        local cluster = require("zotcite_extra.cluster")
        local buf = vim.api.nvim_get_current_buf()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local changed, preview = 0, {}
        for i, line in ipairs(lines) do
            local new, n = cluster.normalize_line(line)
            if n > 0 then
                changed = changed + n
                if #preview < 8 then
                    table.insert(preview, string.format("%d: %s\n→ %s", i, line, new))
                end
                lines[i] = new
            end
        end
        if changed == 0 then
            vim.notify("[zotcite-extra] citations are already canonical", vim.log.levels.INFO)
            return
        end
        if a.bang then
            vim.notify("[zotcite-extra] " .. changed .. " citation(s) would change:\n"
                .. table.concat(preview, "\n\n"), vim.log.levels.INFO)
            return
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.notify("[zotcite-extra] normalized " .. changed .. " citation(s)", vim.log.levels.INFO)
        pcall(function() require("zotcite_extra.render").refresh() end)
    end, { bang = true, desc = "Canonicalise citation syntax (:ZNormalize! = dry run)" })

    cmd("ZSuggest", function()
        local text = M.paragraph_text()
        if #text < 15 then
            vim.notify("[zotcite-extra] put the cursor in the paragraph to search for",
                vim.log.levels.WARN)
            return
        end
        M.cite({ search = "semantic", pattern = text })
    end, { desc = "Suggest citations by meaning for the current paragraph" })

    cmd("ZSimilar", function()
        local cluster = require("zotcite_extra.cluster")
        local data = require("zotcite_extra.data")
        local pos = vim.api.nvim_win_get_cursor(0)
        local line = vim.api.nvim_buf_get_lines(0, pos[1] - 1, pos[1], false)[1] or ""
        local group = cluster.nearest(line, pos[2])
        local citekey = group and cluster.items_of(group)[1] and cluster.items_of(group)[1].key
        local zotkey = citekey and data.zotkey(citekey)
        if not zotkey then
            vim.notify("[zotcite-extra] no citation on this line", vim.log.levels.WARN)
            return
        end
        local entries, err = require("zotcite_extra.semantic").similar(zotkey)
        if not entries or #entries == 0 then
            vim.notify("[zotcite-extra] no similar papers" .. (err and (": " .. err) or ""),
                vim.log.levels.WARN)
            return
        end
        M.cite({
            search = "semantic",
            entries = entries,
            results_title = "ZotSeek · similar to " .. citekey,
        })
    end, { desc = "Papers similar to the citation under the cursor (ZotSeek)" })

    cmd("ZAttachments", function()
        local data = require("zotcite_extra.data")
        local cluster = require("zotcite_extra.cluster")
        local pos = vim.api.nvim_win_get_cursor(0)
        local line = vim.api.nvim_buf_get_lines(0, pos[1] - 1, pos[1], false)[1] or ""
        local group = cluster.nearest(line, pos[2])
        local citekey = group and cluster.items_of(group)[1] and cluster.items_of(group)[1].key
        local zotkey = citekey and data.zotkey(citekey)
        if not zotkey then
            vim.notify("[zotcite-extra] no citation on this line", vim.log.levels.WARN)
            return
        end
        local lines = require("zotcite_extra.attachment").describe(zotkey)
        table.insert(lines, 1, citekey .. " (" .. zotkey .. ")")
        vim.notify("[zotcite-extra]\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
    end, { desc = "How the attachments of this citation resolve (Zotero vs. disk)" })

    cmd("ZFixAttachDir", function()
        local ok, msg = require("zotcite_extra.attachment").fix_base()
        vim.notify("[zotcite-extra] " .. msg, ok and vim.log.levels.INFO or vim.log.levels.WARN)
    end, { desc = "Relink Zotero's stale linked-attachment base directory (symlink)" })

    cmd("ZBiblio", function()
        M.bibliography()
    end, { desc = "Insert or update the bibliography" })

    cmd("ZStyle", function(a)
        M.style(a.args)
    end, { nargs = "?", desc = "Set the document CSL style (YAML csl:)" })

    cmd("ZRender", function()
        M.toggle_render()
    end, { desc = "Toggle CSL rendering" })

    cmd("ZLsp", function()
        local buf = vim.api.nvim_get_current_buf()
        M.bootstrap(buf)
        local names = {}
        for _, c in ipairs(vim.lsp.get_clients({ bufnr = buf })) do table.insert(names, c.name) end
        vim.notify("[zotcite-extra] LSP clients here: " .. (#names > 0 and table.concat(names, ", ") or "none"),
            vim.log.levels.INFO)
    end, { desc = "(Re)start zotcite completion in this buffer" })

    cmd("ZDoctor", function()
        vim.notify("[zotcite-extra] compatibility\n" .. table.concat(require("zotcite_extra.compat").report(), "\n"),
            vim.log.levels.INFO)
    end, { desc = "zotcite-extra / zotcite compatibility report" })

    cmd("ZPing", function()
        M.ping()
    end, { desc = "zotcite-extra status" })

    -- completion may arrive after attach (server start is async)
    vim.api.nvim_create_autocmd("LspAttach", {
        group = attach_group,
        callback = function(ev)
            local client = vim.lsp.get_client_by_id(ev.data.client_id)
            if client and client.name == "zotero_ls" then M.enable_completion(ev.buf) end
        end,
    })

    cmd("ZAttach", function()
        local buf = vim.api.nvim_get_current_buf()
        attached[buf] = nil
        if M.maybe_attach(buf, true) then
            vim.notify("[zotcite-extra] attached to this buffer", vim.log.levels.INFO)
        else
            vim.notify("[zotcite-extra] could not attach", vim.log.levels.WARN)
        end
    end, { desc = "Enable citations in this buffer" })

    local maps = o.maps or {}
    if maps.cite ~= false then
        vim.keymap.set({ "n", "i" }, "<Plug>(zotcite-extra-cite)", function() M.cite() end,
            { desc = "Zotero citation" })
    end
    if maps.mode then
        vim.keymap.set("n", maps.mode, function() M.cycle_mode() end,
            { desc = "Swap citation mode" })
    end
    if maps.bibliography then
        vim.keymap.set("n", maps.bibliography, function() M.bibliography() end,
            { desc = "Update bibliography" })
    end
    if maps.style then
        vim.keymap.set("n", maps.style, function() M.style() end, { desc = "CSL style" })
    end
    if maps.locator then
        vim.keymap.set("n", maps.locator, function() M.set_locator() end, { desc = "Citation locator" })
    end

    --- Attach to every markdown buffer, however it became markdown:
    --- by filetype, by extension, or by `:ZAttach`.
    local attach_group = vim.api.nvim_create_augroup("ZotciteExtraAttach", { clear = true })
    vim.api.nvim_create_autocmd(o.attach_events, {
        group = attach_group,
        pattern = "*",
        callback = function(ev) M.maybe_attach(ev.buf) end,
    })

    -- a breaking zotcite change should be visible, not silent
    vim.schedule(function() pcall(require("zotcite_extra.compat").check) end)

    -- buffers that already exist when setup runs
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then M.maybe_attach(b) end
    end
    return o
end

return M
