# zotcite-extra

**Word-style citations in Neovim.** Pick references from Zotero, insert them as
Pandoc citations, see them rendered by Zotero's own CSL engine — then swap the
mode, set a locator, or refresh the reference list, all without leaving the
buffer.

[zotcite](https://github.com/jalvesaq/zotcite) owns the Zotero database layer
(sqlite copies, citekeys, collections, notes). zotcite-extra adds the part it
deliberately leaves to `pandoc --citeproc`: **Word-integration semantics** —
mode swapping, locators, live CSL rendering, in-document bibliography, numeric
styles, style switching, and opening the PDF you are citing.

Formatting is never reimplemented here: every rendered citation and every
bibliography entry is Zotero's own output, fetched from its local API
(`127.0.0.1:23119/api/users/0/items?include=citation&style=…`).

```
source:  ... is task-specific [@panaderoTrackingSelfregulatedLearning2025, p. 14] ...
screen:  ... is task-specific (Panadero et al., 2025, p. 14) ...
```

```
@pan<Tab>            picker, seeded with "pan"           → <CR>
see @ted<Tab><CR>    replaces what you typed             → see [@yan2020]
<Space>zm            (Author, 2020) ⇄ Author (2020) ⇄ (2020)
<Space>zb            ## References, rebuilt from the citations in the buffer
<Space>zo            the PDF, in Zotero's reader, with your annotations
```

## Features

- **One picker, two engines.** Telescope, two panes (list + abstract). Fuzzy
  metadata search over the whole library, and — with
  [ZotSeek](https://github.com/introfini/zotseek) — semantic search inside your
  Zotero library, visually distinct (amber frame, similarity column, matched
  passage in the preview). `<C-s>` switches engine, prompt carried over.
- **Insertion that replaces what you typed.** `@ted` + `<Tab>` inserts
  `[@yan2020]`, not `[@yan2020ted]`; mixed case, digits, `-`, `_` and sloppy
  pastes (`[@ key ]`) are handled. `.`/`,` after the token stay outside.
- **You never leave insert mode.** The citation is rendered as soon as the
  picker closes, the cursor sits after `]`, and you carry on writing.
- **Modes and locators as text rewrites.** `(Author, 2020)` ⇄ `Author (2020)` ⇄
  `(2020)`, `p. 14`, prefixes and suffixes (`[see @k, p. 3, for a review]`) —
  lossless, because the buffer keeps Pandoc syntax.
- **Numeric styles done properly.** `[1]`, nature, GB/T 7714, IEEE: numbers come
  from document order (`[1, 3–5]`), the reference list is numbered in citation
  order.
- **Live bibliography.** `:ZBiblio` inserts or refreshes `## References` from
  the citations in the buffer, in the document's CSL style, keeping whatever
  follows intact.
- **The document you are citing.** `<Space>zo` opens the PDF in Zotero's reader
  through `zotero://` links; linked attachments and stale cloud mounts are
  resolved instead of silently failing. `<C-o>` does the same from inside the
  picker — a semantic hit jumps to the *matched page*.
- **ZotSeek writing aids.** `:ZSuggest` searches for the paragraph you just
  wrote; `:ZSimilar` snowballs from the citation under the cursor.
- **Honest about unknowns.** A half-typed or missing key is never concealed,
  only underlined; `:ZDoctor` reports exactly which zotcite internals exist and
  which key bindings are shadowed.

## Requirements

- Neovim **0.10+** (uses `vim.system`, `vim.ui.open`; developed on 0.12).
- **Zotero 8+** (or 10.x) running, with the local API enabled (it is by
  default at `127.0.0.1:23119`).
- [zotcite](https://github.com/jalvesaq/zotcite) with `hl_cite_key = false`
  and `key_type = "better-bibtex"` (or `"zotero"`).
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) for the
  picker (without it, a plain `vim.ui.select` fallback is used).
- `sqlite3` and `curl` on `PATH`; a `yaml` tree-sitter parser for the
  document style.
- Optional: [ZotSeek](https://github.com/introfini/zotseek) with
  `zotseek.mcpServer.enabled = true` for semantic search.

## Install

```lua
{
    "jalvesaq/zotcite",
    lazy = false,     -- zotcite does its work in ftplugin/, so do not lazy-load it
    dependencies = { "nvim-treesitter/nvim-treesitter", "nvim-telescope/telescope.nvim" },
    opts = { key_type = "better-bibtex", hl_cite_key = false }, -- we render instead
},
{
    "fabea87/zotcite-extra",
    lazy = false,
    dependencies = { "jalvesaq/zotcite", "nvim-telescope/telescope.nvim" },
    config = function()
        require("zotcite_extra").setup({ default_style = "apa" })
    end,
}
```

No keybindings outside `<leader>z*`, no global options touched beyond
`'conceallevel'`/`'concealcursor'` in attached windows (see
[Configuration](#configuration)).

## Configuration

Everything is optional; the defaults are:

```lua
require("zotcite_extra").setup({
    -- Zotero
    port = 23119,
    library = "users/0",
    cache_ttl_ms = 120000,

    -- CSL style: nil -> the document's YAML `csl:`, else `default_style`
    style = nil,
    default_style = "apa",
    sort_cluster = true,          -- alphabetical cluster order (APA 7 §8.12)

    -- Rendering
    render = true,
    render_debounce_ms = 120,
    insert_conceal = true,        -- render inside insert mode (adds `i` to 'concealcursor')
    leave_insert_after_pick = false,

    -- Citation syntax
    footnotes = true,
    footnote_prefix = "zot",
    locator_label = "page",

    -- Completion
    tab_completion = true,        -- <Tab> inside `@key` opens the picker
    tab_uses_picker = true,       -- false -> the inline menu (<C-x><C-o>)
    at_trigger = false,           -- open the list as soon as `@` is typed

    -- Numeric styles
    numeric = {
        force = nil,              -- nil = detect, or "numeric" / "author-date"
        range = 3,                -- "1, 3–5, 9": 3 consecutive numbers collapse
        bracket = true,           -- "[1, 2]" instead of "1, 2"
        marker = "[%d] ",         -- reference-list prefix ("%d. " for nature)
    },

    -- Semantic search (ZotSeek)
    semantic = { enabled = true, top_k = 40, min_similarity = 0.3, mode = "semantic" },
    semantic_mode_default = "metadata",

    -- Attachments
    storage_dir = "~/Zotero",     -- where Zotero keeps stored files
    attach_dir = nil,             -- linked files: read from Zotero's prefs, repaired if stale
    sync_zotcite = true,          -- hand that directory to zotcite (stops its nagging)
    open_cmd = nil,               -- opener override; nil -> `open` / `xdg-open`

    -- Pickers / compatibility
    picker = nil,                 -- telescope; "ui" forces the vim.ui.select fallback
    shadow_zotcite_keys = true,   -- our <leader>zb / <leader>zo win (see below)
    warn_on_zotcite_changes = true,

    -- Keymaps (set false to keep zotcite's / disable)
    maps = { insert = "<leader>zc", narrative = "<leader>zn", cycle = "<leader>zm",
             bib = "<leader>zb", csl = "<leader>zs", locator = "<leader>zl",
             open = "<leader>zo", open_external = "<leader>zO" },
})
```

## Usage

### Picking a citation

Type `@` and a few letters, press `<Tab>`:

| key | effect |
|---|---|
| `<Tab>` (inside `@key`) | open the picker seeded with what you typed |
| `<CR>` | insert as `[@key]` |
| `<C-n>` / `<C-y>` | insert as `@key` (narrative) / `[-@key]` (year only) |
| `<C-l>` | insert with a locator prompt |
| `<Tab>` / `<S-Tab>` | mark several rows → one cluster `[@a2020; @b2021]` |
| `<C-s>` | switch search engine: metadata ⇄ ZotSeek semantic |
| `<C-h>` | semantic ⇄ hybrid (embeddings + Zotero keyword search) |
| `<C-r>` | re-run the search |
| `<C-o>` | open the highlighted row's document (picker stays open) |
| `<Esc>` / `<C-c>` | cancel — you land back exactly where you were typing |

`@` + `<Tab>` with no seed lists the whole library, newest first. Picking while
the cursor sits on an existing citation **appends** to that cluster, like Word.

### Two search engines

| | metadata | semantic |
|---|---|---|
| frame, prompt | plain Telescope, `Zotero` | amber frame, `◆ ZotSeek` |
| rows | author (year) title | `◈` badge, author (year), similarity, title |
| preview | Abstract | the matched passage, with its page |
| engine | zotcite's sqlite, fuzzy on author/year/title/citekey | ZotSeek embeddings (`/zotseek/search`) |

Semantic rows say how a hit was found — `≡` both legs, `◈` semantic only, `⌕`
keyword only — and the similarity is colour-coded (≥.80 / ≥.60 / below).
`mode=semantic` costs ~0.1 s, `hybrid` ~1 s, so the picker only queries when
typing pauses and caches per query (2821 papers on the test library).

### Modes, locators, canonical syntax

```
(Author, 2020)  ⇄  Author (2020)  ⇄  (2020)      <Space>zm
[@key, p. 14]                                     <Space>zl  /  <C-l> in the picker
[see @key, p. 3, for a review]                    prefix / suffix survive every swap
```

`:ZNormalize` canonicalises the whole buffer (`:ZNormalize!` = dry run):
`[@a;@b]` → `[@a; @b]`, `@key[p.3]` → `@key [p. 3]`, `[@k,pp.3-4]` →
`[@k, pp. 3–4]`, `[@ k ]` → `[@k]`.

### Rendering

Set `conceallevel=2` in markdown buffers (the plugin does not force it). The
buffer keeps `[@key]`; the screen shows Zotero's text, including numeric styles:

```
source:  Both [@butler…1995; @he…2023] hold, see [@butler…1995, p. 3].
APA:     Both (Butler & Winne, 1995; He et al., 2023) hold, see (Butler & Winne, 1995, p. 3).
nature:  Both [1, 2] hold, see [1, p. 3].
```

Rendering never touches the text under the cursor: a half-typed `@pan`, a typo,
or an item missing from Zotero stays visible with a warning underline. Inside
insert mode (`insert_conceal = true`) only the group under the cursor stays raw,
so a citation picked a second ago is already formatted while you type the next
sentence.

### Bibliography

`:ZBiblio` (`<Space>zb`) inserts or **refreshes** the reference list under a
heading (`## References` by default), from the citations in the buffer, in the
document's CSL style, replacing only its own block:

```
## References

[1] Butler, D. L. & Winne, P. H. Feedback and Self-Regulated Learning: A Theoretical Synthesis. *Rev. Educ. Res.* **65**, 245–281 (1995).

[2] He, J., Liu, Y., Ran, T. & Zhang, D. How students' perception of feedback …
```

Alphabetical for author-date styles, numbered in citation order for numeric
ones. `:ZStyle` writes `csl:` into the YAML front matter.

### Opening the document

`:ZOpen` / `<Space>zo` resolves attachments through Zotero's own API, so stored
*and* linked attachments work without configuration:

1. ask Zotero how it resolves the attachment (`/items/<key>/file` → `file://…`);
2. file exists → open the way Zotero would (`zotero://open-pdf/…`, reader with
   annotations);
3. Zotero's path is stale (a cloud account was re-added, the mount renamed —
   Zotero then silently does nothing) → open the file we can reach, and say so;
4. no attachment → select the item in Zotero.

`:ZAttachments` prints that chain; `:ZFixAttachDir` repairs the stale directory
with one symlink so Zotero itself works again. `<Space>zO` opens the raw file in
an external app, `:ZOpen!` just selects the item.

### Writing aids (ZotSeek)

| command | what |
|---|---|
| `:ZSuggest` | semantic search for the **paragraph** (or selection) under the cursor — "which papers say this?" |
| `:ZSimilar` | papers similar to the citation under the cursor (snowballing) |

## Commands

| command | effect |
|---|---|
| `:ZCite` / `:ZCite!` | pick → `[@key]` / footnote + `[^zot1]` |
| `:ZCiteN` / `:ZCiteY` | pick → `@key` / `[-@key]` |
| `:ZSemantic` | pick with ZotSeek semantic search |
| `:ZMode` | cycle parenthetical → narrative → year-only |
| `:ZLocator [p. 14]` | set / clear the locator |
| `:ZDel` | delete the citation under the cursor |
| `:ZBiblio` | insert / refresh the reference list |
| `:ZStyle [style-id]` | set the document CSL style |
| `:ZRender` | toggle CSL rendering |
| `:ZOpen` / `:ZOpen!` | open the PDF (in Zotero) / select the item |
| `:ZAttachments` | how Zotero and the disk resolve this citation's files |
| `:ZFixAttachDir` | relink Zotero's stale linked-attachment directory |
| `:ZNormalize` / `:ZNormalize!` | canonicalise citation syntax (dry run with `!`) |
| `:ZSuggest` / `:ZSimilar` | semantic writing aids |
| `:ZAttach` | enable citations in a non-markdown buffer |
| `:ZLsp` | (re)start completion in this buffer |
| `:ZRender` / `:ZPing` / `:ZDoctor` | rendering toggle / status / compatibility report |

## Which buffers get citations

Every markdown-ish buffer, whether it became markdown by filetype (`markdown`,
`pandoc`, `quarto`, `rmd`, `mdx`, `tex`, `typst`, `rnoweb`, `vimwiki`) or only by
file name (`.md`, `.markdown`, `.mdown`, `.mdx`, `.qmd`, `.rmd`, `.Rmd`). For
anything else (`.txt`, `:enew`) run `:ZAttach` once.

## Compatibility with zotcite

zotcite-extra is a **companion, not a fork**: zotcite keeps owning the database
layer, so its internals are called by name and its updates matter.

- Tested against zotcite `f57a5eb` (master, 2026-10-04).
- Needs `hl_cite_key = false` (we render instead — `:ZDoctor` warns when it is on).
- Borrowed internals, every call `pcall`ed and degrading to Zotero's HTTP API:
  `zotcite.config.{get_config,get_key_type,init}`,
  `zotcite.zotero.{get_match,get_ref_data,get_all_citations,init,get_attachment}`,
  `zotcite.get.abstract`, `zotcite.seek.refs`.

Two of its key bindings are shadowed, deliberately and switchably:

| key | zotcite | zotcite-extra |
|---|---|---|
| `<leader>zb` | paste abstract note | update the bibliography (abstract stays on `<leader>zA`) |
| `<leader>zo` | open attachment (needs `attach_dir`) | open the document (see above) |
| `<Tab>` (insert) | inline menu / `<C-x><C-b>` | our picker (`<C-x><C-b>` stays zotcite's) |

```lua
require("zotcite_extra").setup({
    shadow_zotcite_keys = false,           -- keep zotcite's zb/zo, we still have :ZBiblio / :ZOpen
    sync_zotcite = false,                  -- don't hand attach_dir to zotcite
})
```

`:ZDoctor` prints the probe table, `hl_cite_key`, optional dependencies and the
shadowed keys; `:ZPing` summarises it as `zotcite API: 10/10 present`. Without
zotcite at all, the plugin still loads: picker and bibliography fall back to
Zotero's HTTP API, citekey resolution and completion go quiet.

## How it works

```
lua/zotcite_extra/
  init.lua        setup, commands, buffer attachment, keymaps, :ZDoctor/:ZPing
  picker.lua      telescope: two search engines, multi-select, previews, decorations
  semantic.lua    ZotSeek bridge (/zotseek/stats, /search, /similar)
  complete.lua    `@token` scanning + omnifunc for the inline menu
  cluster.lua     Pandoc cluster parsing, rendering, canonicalisation
  numeric.lua     numeric CSL styles: document-order numbering
  csl.lua         citation assembly from Zotero's per-item text
  render.lua      conceal + inline virtual text, document-style aware
  biblio.lua      `## References` from Zotero's `format=bib`
  style.lua       document CSL style (YAML `csl:`)
  attachment.lua  attachments, `zotero://` links, stale base-dir repair
  api.lua         Zotero local API client (cached, normalised)
  data.lua        bridge to zotcite's sqlite layer
  compat.lua      what we borrow from zotcite, and what we shadow
```

Everything that formats is deferred to Zotero; everything that decides *what* to
format (document order, clusters, locators, numbering, modes) lives here.

## Tests

```bash
# pure logic, no Zotero required (these run in CI):
nvim --headless -l tests/token_spec.lua       # @token scanning, replacement, multi-select
nvim --headless -l tests/mode_swap_spec.lua   # cluster parsing, mode swaps, locators
nvim --headless -l tests/numeric_spec.lua     # numeric styles, :ZNormalize

# needs Zotero running:
nvim --headless -l tests/attachment_spec.lua
nvim --headless -l tests/semantic_spec.lua    # skips when ZotSeek is absent
nvim --headless -l tests/compat_spec.lua      # passes with and without zotcite
nvim examples/test.md -c "luafile tests/integration_spec.lua"
```

## Known limitations

- **Word field codes** are not written: a Markdown document stays Markdown
  (`--citeproc` renders it). No `ADDIN ZOTERO_ITEM` round trip.
- **LaTeX/Typst** buffers get citations and rendering, but the numeric-style
  machinery and `:ZBiblio` are Markdown-shaped (headings, `## References`).
- **Narrative + several items** renders as `Author (2020); (2021)` — a true
  per-item narrative cluster still needs its own author form.
- Cluster prefixes/suffixes are preserved and rewritten, but there is no UI to
  *edit* them yet (hand-edit the text).

## Credits

Built on [zotcite](https://github.com/jalvesaq/zotcite) by José Alves Castro
(database layer, completion infrastructure),
[telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) (picker) and
optionally [ZotSeek](https://github.com/introfini/zotseek) by José Fernandes
(semantic search). Formatting is Zotero's, via
[CSL](https://citationstyles.org/).

## License

MIT — see [LICENSE](LICENSE).
