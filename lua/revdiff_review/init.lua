-- revdiff_review — review ANY buffer with line / range / file-level annotations,
-- then export to revdiff's history format so the revdiff Claude Code skill
-- consumes it directly.
--
-- Two entry points:
--   * interactive: :RevdiffComment / :RevdiffExport etc. (see setup())
--   * launcher session: when $REVDIFF_REVIEW_OUTPUT is set, start_session() wires
--     an auto-export-on-quit so the revdiff override launcher can drive nvim and
--     read annotations from stdout. See scripts/launch-revdiff.sh override.

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("revdiff_review")

-- store[abspath] = { bufnr, lines = { {id, text, lnum} }, file_level = { texts = {}, mark } }
local store = {}

local config = {
  prefix = "<leader>r",
  history_dir = nil, -- nil => $REVDIFF_HISTORY_DIR or ~/.config/revdiff/history
}

local function notify(msg, level)
  vim.notify("[review] " .. msg, level or vim.log.levels.INFO)
end

local function label(text)
  local first = vim.split(text, "\n", { plain = true })[1] or ""
  if vim.fn.strdisplaywidth(first) > 60 then
    first = vim.fn.strcharpart(first, 0, 57) .. "…"
  end
  return first
end

local function ensure(path)
  if not store[path] then
    store[path] = { bufnr = nil, lines = {}, file_level = { texts = {}, mark = nil } }
  end
  return store[path]
end

-- Multi-line floating comment editor. :w / <leader>w to save, q / Esc to cancel.
local function open_editor(initial, on_submit)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  if initial and initial ~= "" then
    api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(initial, "\n", { plain = true }))
  end
  local width = math.min(80, math.floor(vim.o.columns * 0.6))
  local win = api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = 8,
    style = "minimal",
    border = "rounded",
    title = " review comment  (:w / <leader>w save · q cancel) ",
    title_pos = "center",
  })
  if initial == "" then
    vim.cmd("startinsert")
  end
  local function close()
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end
  local function submit()
    local text = vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    close()
    if text ~= "" then
      on_submit(text)
    end
  end
  vim.keymap.set("n", "<leader>w", submit, { buffer = buf, desc = "Save comment" })
  vim.keymap.set("n", "q", close, { buffer = buf, desc = "Cancel" })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, desc = "Cancel" })
  -- `:w` / `ZZ` save the comment instead of writing a file
  api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = submit })
end

local function refresh_file_level(buf, e)
  if e.file_level.mark then
    pcall(api.nvim_buf_del_extmark, buf, ns, e.file_level.mark)
    e.file_level.mark = nil
  end
  if #e.file_level.texts == 0 then
    return
  end
  local vlines = {}
  for _, t in ipairs(e.file_level.texts) do
    vlines[#vlines + 1] = { { "▌ [file] " .. label(t), "RevdiffReviewVirt" } }
  end
  e.file_level.mark = api.nvim_buf_set_extmark(buf, ns, 0, 0, {
    virt_lines = vlines,
    virt_lines_above = true,
  })
end

local function set_line_mark(buf, lnum, text, existing_id)
  return api.nvim_buf_set_extmark(buf, ns, lnum, 0, {
    id = existing_id,
    sign_text = "▌",
    sign_hl_group = "RevdiffReviewSign",
    virt_text = { { "  " .. label(text), "RevdiffReviewVirt" } },
    virt_text_pos = "eol",
  })
end

function M.comment(line1)
  local buf = api.nvim_get_current_buf()
  local path = api.nvim_buf_get_name(buf)
  if path == "" then
    return notify("buffer has no file name", vim.log.levels.WARN)
  end
  local lnum = (line1 or vim.fn.line(".")) - 1
  open_editor("", function(text)
    local id = set_line_mark(buf, lnum, text)
    local e = ensure(path)
    e.bufnr = buf
    e.lines[#e.lines + 1] = { id = id, text = text, lnum = lnum }
    notify("annotation added on line " .. (lnum + 1))
  end)
end

function M.file_comment()
  local buf = api.nvim_get_current_buf()
  local path = api.nvim_buf_get_name(buf)
  if path == "" then
    return notify("buffer has no file name", vim.log.levels.WARN)
  end
  open_editor("", function(text)
    local e = ensure(path)
    e.bufnr = buf
    table.insert(e.file_level.texts, text)
    refresh_file_level(buf, e)
    notify("file-level annotation added")
  end)
end

local function find_on_cursor(buf, e)
  local row = vim.fn.line(".") - 1
  for i, a in ipairs(e.lines) do
    local pos = api.nvim_buf_get_extmark_by_id(buf, ns, a.id, {})
    if pos[1] == row then
      return i, a, pos[1]
    end
  end
end

function M.edit()
  local buf = api.nvim_get_current_buf()
  local e = store[api.nvim_buf_get_name(buf)]
  if not e then
    return notify("no annotations in this buffer", vim.log.levels.WARN)
  end
  local _, a, row = find_on_cursor(buf, e)
  if not a then
    return notify("no annotation on this line", vim.log.levels.WARN)
  end
  open_editor(a.text, function(text)
    a.text = text
    set_line_mark(buf, row, text, a.id)
    notify("annotation updated")
  end)
end

function M.delete()
  local buf = api.nvim_get_current_buf()
  local e = store[api.nvim_buf_get_name(buf)]
  if not e then
    return notify("no annotations in this buffer", vim.log.levels.WARN)
  end
  local i, a = find_on_cursor(buf, e)
  if a then
    pcall(api.nvim_buf_del_extmark, buf, ns, a.id)
    table.remove(e.lines, i)
    return notify("annotation deleted")
  end
  if #e.file_level.texts > 0 then
    e.file_level.texts = {}
    refresh_file_level(buf, e)
    return notify("file-level annotations cleared")
  end
  notify("no annotation on this line", vim.log.levels.WARN)
end

-- resolve the live line number of a stored annotation (extmark > fallback)
local function live_lnum(e, a)
  if e.bufnr and api.nvim_buf_is_valid(e.bufnr) then
    local pos = api.nvim_buf_get_extmark_by_id(e.bufnr, ns, a.id, {})
    if pos[1] then
      return pos[1] + 1
    end
  end
  return a.lnum + 1
end

function M.list()
  local items = {}
  for path, e in pairs(store) do
    for _, t in ipairs(e.file_level.texts) do
      items[#items + 1] = { filename = path, lnum = 1, text = "[file] " .. label(t) }
    end
    for _, a in ipairs(e.lines) do
      items[#items + 1] = { filename = path, lnum = live_lnum(e, a), text = label(a.text) }
    end
  end
  if #items == 0 then
    return notify("no annotations yet")
  end
  table.sort(items, function(x, y)
    if x.filename == y.filename then
      return x.lnum < y.lnum
    end
    return x.filename < y.filename
  end)
  vim.fn.setqflist({}, " ", { title = "Review annotations", items = items })
  vim.cmd("copen")
end

function M.clear()
  for _, e in pairs(store) do
    if e.bufnr and api.nvim_buf_is_valid(e.bufnr) then
      pcall(api.nvim_buf_clear_namespace, e.bufnr, ns, 0, -1)
    end
  end
  store = {}
  notify("cleared all annotations")
end

local function git(root, args)
  local cmd = { "git", "-C", root }
  vim.list_extend(cmd, args)
  local out = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return out
end

-- Export annotations.
--   opts.output : when set, write ONLY the annotation blocks (revdiff stdout
--                 format) to this path — used by the launcher session. The full
--                 history file is still written. No clipboard/notify in this mode.
function M.export(opts)
  opts = opts or {}
  local paths = {}
  for path, e in pairs(store) do
    if #e.lines > 0 or #e.file_level.texts > 0 then
      paths[#paths + 1] = path
    end
  end
  if #paths == 0 then
    if not opts.output then
      notify("no annotations to export", vim.log.levels.WARN)
    end
    return
  end
  table.sort(paths)

  local first_dir = vim.fn.fnamemodify(paths[1], ":h")
  local root_lines = git(first_dir, { "rev-parse", "--show-toplevel" })
  local root = (root_lines and root_lines[1] and root_lines[1] ~= "") and root_lines[1] or vim.fn.getcwd()
  local repo = vim.fn.fnamemodify(root, ":t")
  local function relpath(p)
    return (p:gsub("^" .. vim.pesc(root .. "/"), ""))
  end

  -- annotation blocks only (this is exactly the revdiff stdout format)
  local blocks, count = {}, 0
  for _, path in ipairs(paths) do
    local e = store[path]
    local rel = relpath(path)
    for _, t in ipairs(e.file_level.texts) do
      blocks[#blocks + 1] = "## " .. rel .. " (file-level)"
      vim.list_extend(blocks, vim.split(t, "\n", { plain = true }))
      blocks[#blocks + 1] = ""
      count = count + 1
    end
    local sorted = vim.deepcopy(e.lines)
    table.sort(sorted, function(a, b)
      return live_lnum(e, a) < live_lnum(e, b)
    end)
    for _, a in ipairs(sorted) do
      blocks[#blocks + 1] = "## " .. rel .. ":" .. live_lnum(e, a) .. " (line)"
      vim.list_extend(blocks, vim.split(a.text, "\n", { plain = true }))
      blocks[#blocks + 1] = ""
      count = count + 1
    end
  end

  -- full history file: header + annotations + raw diff
  local full = {
    "# Review: " .. os.date("%Y-%m-%d %H:%M:%S"),
    "path: " .. root,
  }
  local hash = git(root, { "rev-parse", "--short", "HEAD" })
  if hash and hash[1] then
    full[#full + 1] = "commit: " .. hash[1]
  end
  vim.list_extend(full, { "", "## Annotations", "" })
  vim.list_extend(full, blocks)
  vim.list_extend(full, { "---", "", "## Diff", "" })
  local rels = {}
  for _, p in ipairs(paths) do
    rels[#rels + 1] = relpath(p)
  end
  local diff = git(root, vim.list_extend({ "diff", "HEAD", "--" }, rels))
  if diff then
    vim.list_extend(full, diff)
  end

  -- always persist the full history file (safety net + "locate my review")
  local hist = config.history_dir
    or vim.env.REVDIFF_HISTORY_DIR
    or (vim.fn.expand("~") .. "/.config/revdiff/history")
  local dir = hist .. "/" .. repo
  vim.fn.mkdir(dir, "p")
  local file = dir .. "/" .. os.date("%Y%m%d-%H%M%S") .. ".md"
  pcall(vim.fn.writefile, full, file)

  if opts.output then
    vim.fn.writefile(blocks, opts.output)
  else
    pcall(vim.fn.setreg, "+", table.concat(full, "\n"))
    notify(
      ('exported %d annotation(s) -> %s\nCopied to clipboard. In Claude Code: "use my latest revdiff annotations"')
        :format(count, file)
    )
  end
end

-- Launcher session: auto-export on quit to opts.output; optionally diff against base.
function M.start_session(opts)
  opts = opts or {}
  if not opts.output or opts.output == "" then
    return
  end
  local grp = api.nvim_create_augroup("RevdiffReviewSession", { clear = true })
  api.nvim_create_autocmd("VimLeavePre", {
    group = grp,
    callback = function()
      pcall(M.export, { output = opts.output })
    end,
  })
  if opts.base and opts.base ~= "" then
    vim.schedule(function()
      local ok, gs = pcall(require, "gitsigns")
      if ok and gs.change_base then
        pcall(gs.change_base, opts.base, true)
      end
    end)
  end
  vim.schedule(function()
    notify("review session — annotate with " .. config.prefix .. "c / " .. config.prefix .. "f, then :qa to finish")
  end)
end

local function register()
  api.nvim_set_hl(0, "RevdiffReviewVirt", { link = "Comment", default = true })
  api.nvim_set_hl(0, "RevdiffReviewSign", { link = "DiagnosticSignWarn", default = true })

  local function cmd(name, fn, o)
    api.nvim_create_user_command(name, fn, o or {})
  end
  cmd("RevdiffComment", function(o)
    M.comment(o.line1)
  end, { range = true })
  cmd("RevdiffFileComment", M.file_comment)
  cmd("RevdiffEdit", M.edit)
  cmd("RevdiffDelete", M.delete)
  cmd("RevdiffList", M.list)
  cmd("RevdiffExport", function()
    M.export()
  end)
  cmd("RevdiffClear", M.clear)

  local p = config.prefix
  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { desc = desc })
  end
  map("n", p .. "c", "<cmd>RevdiffComment<cr>", "Review: comment line")
  map("x", p .. "c", ":RevdiffComment<cr>", "Review: comment selection")
  map("n", p .. "f", "<cmd>RevdiffFileComment<cr>", "Review: file-level comment")
  map("n", p .. "i", "<cmd>RevdiffEdit<cr>", "Review: edit comment")
  map("n", p .. "d", "<cmd>RevdiffDelete<cr>", "Review: delete comment")
  map("n", p .. "l", "<cmd>RevdiffList<cr>", "Review: list comments")
  map("n", p .. "e", "<cmd>RevdiffExport<cr>", "Review: export to revdiff history")
  map("n", p .. "x", "<cmd>RevdiffClear<cr>", "Review: clear all")
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  register()
  -- launcher session mode: triggered purely by env so the launcher needs no -c
  if vim.env.REVDIFF_REVIEW_OUTPUT and vim.env.REVDIFF_REVIEW_OUTPUT ~= "" then
    M.start_session({ output = vim.env.REVDIFF_REVIEW_OUTPUT, base = vim.env.REVDIFF_REVIEW_BASE })
  end
end

return M
