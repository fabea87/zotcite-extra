--- Document CSL style, stored in the YAML front matter.
--- `csl:` is read by pandoc's --citeproc, so the editor and the docx build
--- always agree on the style. Zotero validates ids on demand.
local cfg = require("zotcite_extra.config")

local M = {}

local YAML_START = "^%-%-%-%s*$"
local YAML_END = "^%-%-%-%s*$"

--- Byte range of the YAML front matter, or nil.
function M.yaml_range(bufnr)
    bufnr = bufnr or 0
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if not lines[1] or not lines[1]:match(YAML_START) then return nil end
    for i = 2, #lines do
        if lines[i]:match("^%-%-%-%s*$") or lines[i]:match("^%.%.%.%s*$") then
            return { first = 2, last = i - 1, close = i }
        end
    end
    return nil
end

local function yaml_get(bufnr, field)
    local r = M.yaml_range(bufnr)
    if not r then return nil end
    local lines = vim.api.nvim_buf_get_lines(bufnr, r.first - 1, r.last, false)
    for _, l in ipairs(lines) do
        local v = l:match("^%s*" .. field .. "%s*:%s*(.-)%s*$")
        if v then return (v:gsub("^['\"]", ""):gsub("['\"]$", "")) end
    end
    return nil
end

local function yaml_set(bufnr, field, value)
    local r = M.yaml_range(bufnr)
    if not r then
        vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "---", field .. ": " .. value, "---", "" })
        return true
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, r.first - 1, r.last, false)
    for i, l in ipairs(lines) do
        if l:match("^%s*" .. field .. "%s*:") then
            lines[i] = field .. ": " .. value
            vim.api.nvim_buf_set_lines(bufnr, r.first - 1, r.last, false, lines)
            return true
        end
    end
    table.insert(lines, field .. ": " .. value)
    vim.api.nvim_buf_set_lines(bufnr, r.first - 1, r.last, false, lines)
    return true
end

--- Current style id for the buffer (YAML `csl:` -> `zotero-style:` -> config).
function M.get(bufnr)
    bufnr = bufnr or 0
    return (yaml_get(bufnr, "csl") or yaml_get(bufnr, "zotero%-style")
        or cfg.get().style or cfg.get().default_style)
end

function M.set(bufnr, style)
    bufnr = bufnr or 0
    local id = cfg.style_id(style) or style
    yaml_set(bufnr, "csl", id)
    return id
end

--- Styles available locally in Zotero's styles directory.
function M.available()
    local dir = cfg.expand(cfg.get().styles_dir)
    local out = {}
    local ok, iter = pcall(vim.fs.dir, dir)
    if not ok or not iter then return out end
    for name in iter do
        if name:match("%.csl$") then
            table.insert(out, (name:gsub("%.csl$", "")))
        end
    end
    table.sort(out)
    return out
end

return M
