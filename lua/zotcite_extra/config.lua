--- zotcite-extra: defaults & runtime options
local M = {}

local defaults = {
    --- Zotero local HTTP API
    port = 23119,
    library = "users/0",
    request_timeout_ms = 6000,
    cache_ttl_ms = 120000,

    --- CSL style: "apa" or a full URL. `nil` -> read from YAML `csl:` field,
    --- falling back to `default_style`.
    style = nil,
    default_style = "apa",
    styles_dir = "~/Zotero/styles",

    --- Reorder cluster items alphabetically (APA 7 §8.12). Set false to keep
    --- insertion order.
    sort_cluster = true,

    --- Nested parentheses -> commas inside a parenthetical cluster.
    nested_parens = "comma",

    --- Rendering: show the Zotero-formatted citation instead of the raw
    --- pandoc syntax. Requires zotcite `hl_cite_key = false`.
    render = true,
    --- Render on insert-mode changes too: the debounced pass skips only the
    --- group the cursor sits in, so a citation picked from the picker is
    --- rendered immediately instead of after an <Esc>.
    render_events = { "BufEnter", "CursorHold", "TextChanged", "TextChangedI", "InsertLeave", "WinEnter" },
    render_debounce_ms = 120,
    --- nvim only conceals in a mode listed in 'concealcursor', so rendering
    --- inside insert mode (no mode jumping after a pick) needs `i` there. This
    --- adds it for windows showing an attached buffer. Side effect: treesitter
    --- markdown conceals its own markers (`*`, `**`, link targets) while you
    --- type. Set false to keep 'concealcursor' untouched.
    insert_conceal = true,
    --- Fallback only: when insert-mode conceal is impossible anyway, leave
    --- insert mode after a pick so the citation is rendered at once. Off by
    --- default — picking keeps you in insert mode.
    leave_insert_after_pick = false,

    --- Insert behaviour
    footnotes = true,
    footnote_prefix = "zot",
    locator_label = "page",

    --- Which buffers get citations. zotcite's own list, plus extension-based
    --- detection so a `.md` file works even when its filetype is wrong.
    filetypes = { "markdown", "pandoc", "quarto", "rmd", "mdx", "rnoweb", "tex", "typst", "vimwiki" },
    markdown_extensions = {
        "^%.md$", "^%.markdown$", "^%.mdown$", "^%.mdx$",
        "^%.qmd$", "^%.rmd$", "^%.Rmd$", "^%.Rmarkdown$",
    },
    attach_events = { "FileType", "BufReadPost", "BufNewFile", "BufEnter" },

    --- Where Zotero keeps stored attachments (used only as a fallback when an
    --- attachment has no explicit path; linked files are resolved through
    --- Zotero's own base-attachment directory, read from prefs.js).
    storage_dir = "~/Zotero",
    --- Linked-attachment directory; nil -> read Zotero's prefs, repaired when the
    --- configured mount no longer exists under ~/Library/CloudStorage.
    attach_dir = nil,
    --- Hand that directory to zotcite as well, so its own commands (PDF notes,
    --- :Znote) stop asking and stop printing the "attach_dir is not defined"
    --- warning. Set false to leave zotcite's config untouched.
    sync_zotcite = true,
    --- Warn at setup when a zotcite internal we rely on has disappeared, or when
    --- zotcite's hl_cite_key is on (it fights our rendering).
    warn_on_zotcite_changes = true,
    --- Take over the two zotcite keys whose behaviour we replace:
    ---   <leader>zb  zotcite: paste abstract  ->  zotcite-extra: update bibliography
    ---   <leader>zo  zotcite: open attachment ->  zotcite-extra: open the document
    --- Set false to keep zotcite's bindings (its abstract also stays on
    --- <leader>zA, and our commands remain available as :ZBiblio / :ZOpen).
    shadow_zotcite_keys = true,
    --- Opener for attachments/URLs. nil -> "open" on macOS, "xdg-open" elsewhere.
    open_cmd = nil,

    --- Bibliography
    bib_heading = "^#+%s*[Rr]eferences%s*$",
    bib_heading_insert = "## References",

    --- Tab-based completion of `@citekey` (plain Vim completion, no LSP).
    tab_completion = true,
    --- inside `@key`, <Tab> opens the reference picker seeded with the typed
    --- token (it replaces that token and accepts a multi-selection); false ->
    --- the inline completion menu (<C-x><C-o>)
    tab_uses_picker = true,
    completion_limit = 200,
    --- Open the list as soon as `@` is typed (instead of waiting for <Tab>).
    at_trigger = false,
    completeopt = "menu,menuone,noinsert,noselect",

    --- Semantic search through the ZotSeek plugin (embeddings inside Zotero,
    --- `GET /zotseek/search` on Zotero's local server). `enabled = false` turns
    --- the second search mode off entirely.
    semantic = {
        enabled = true,
        top_k = 40,
        min_similarity = 0.3,
        --- "semantic" (fast, ~0.1 s: pure embeddings) or "hybrid" (~1 s: embeddings
        --- + Zotero keyword search fused with RRF). <C-h> toggles it per session.
        mode = "semantic",
        --- how much of the paragraph :ZSuggest sends as the query
        suggest_chars = 600,
    },
    --- Which search mode the picker starts in: "metadata" (default) or "semantic".
    semantic_mode_default = "metadata",

    --- Numeric citation styles ([1], nature, GB/T 7714, IEEE, Vancouver).
    --- Numbers come from document order and are computed by zotcite-extra; the
    --- style itself is detected from Zotero's own output.
    numeric = {
        --- nil = auto-detect, "numeric" / "author-date" = force it
        force = nil,
        --- how many consecutive numbers make a range ("1, 2, 4–6")
        range = 3,
        --- wrap clusters in brackets: "[1, 2]" (false -> "1, 2")
        bracket = true,
        --- reference-list prefix (string.format pattern, %d = the number)
        marker = "[%d] ",
    },

    --- Picker UI. Telescope is the picker (two panes, both search modes), so this
    --- only chooses the fallback used when telescope is absent: "ui" -> the
    --- built-in vim.ui.select (metadata mode, single selection).
    picker = nil,
    picker_limit = 0, -- 0 = unlimited

    --- Keymaps (set to false to disable)
    maps = {
        insert_completion = "<C-x><C-b>", -- matches zotcite
        render_toggle = false,
    },
}

M.options = vim.deepcopy(defaults)
M.defaults = defaults

function M.setup(opts)
    opts = opts or {}
    M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
    return M.options
end

function M.get()
    return M.options
end

--- Is this buffer a markdown document (by filetype or by extension)?
function M.is_markdown(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) then return false end
    local o = M.options
    local ft = vim.bo[bufnr].filetype
    if ft ~= "" and vim.tbl_contains(o.filetypes, ft) then return true end
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then return false end
    for _, pat in ipairs(o.markdown_extensions) do
        if name:match(pat) then return true end
    end
    return false
end

function M.expand(path)
    return (path:gsub("^~", vim.env.HOME))
end

function M.style_url(id)
    if not id or id == "" then return nil end
    if id:match("^https?://") then return id end
    return "http://www.zotero.org/styles/" .. id
end

function M.style_id(url)
    if not url then return nil end
    return (url:gsub("^https?://www%.zotero%.org/styles/", ""))
end

return M
