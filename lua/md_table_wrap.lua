-- Wrap render-markdown.nvim tables that don't fit the window: each cell is
-- word-wrapped inside its column, so one table row takes several screen lines.
-- The raw rows are hidden with conceal_lines and the table is drawn as
-- virt_lines on the line next to it (virt_lines of a concealed line are hidden).
local M = {}

local CODE = "RenderMarkdownCodeInline"
local width = vim.fn.strdisplaywidth

local MARKUP = {
  strong_emphasis = "@markup.strong",
  emphasis = "@markup.italic",
  strikethrough = "@markup.strikethrough",
  code_span = CODE,
}
local HIDE = { emphasis_delimiter = true, code_span_delimiter = true }
-- link node -> key of its icon in render-markdown's `link` config
local LINKS = {
  inline_link = "hyperlink",
  full_reference_link = "hyperlink",
  uri_autolink = "hyperlink",
  image = "image",
  email_autolink = "email",
}

-- Cell text -> words; a word is a list of {text, hl} chunks, word.sp is the
-- highlight of the space before it. Inline markup comes from the
-- markdown_inline tree: delimiters and link targets are hidden, link icons
-- (from render-markdown's `link` config) are prepended.
function M.words(text, hl, link)
  -- GFM unescapes \| in table cells before inline parsing, code spans included
  text = vim.trim(text):gsub("\\|", "|")
  local hls, hide, prefix = {}, {}, {}
  local function each(s, e, f)
    for i = s + 1, e do
      f(i)
    end
  end
  local function walk(node)
    local t = node:type()
    local _, s, _, e = node:range()
    local group = MARKUP[t] or (LINKS[t] and "@markup.link.label")
    if group then
      each(s, e, function(i)
        hls[i] = hls[i] or {}
        table.insert(hls[i], group)
      end)
    end
    if HIDE[t] then
      each(s, e, function(i)
        hide[i] = true
      end)
    elseif t == "backslash_escape" then
      hide[s + 1] = true
    elseif LINKS[t] then
      local ks, ke = s + 1, e - 1 -- autolinks: keep all but < >
      for child in node:iter_children() do
        if child:type() == "link_text" or child:type() == "image_description" then
          _, ks, _, ke = child:range()
        end
      end
      each(s, e, function(i)
        hide[i] = i <= ks or i > ke
      end)
      if link and link.enabled then
        prefix[ks + 1] = link[LINKS[t]]
      end
    end
    for child in node:iter_children() do
      walk(child)
    end
  end
  walk(vim.treesitter.get_string_parser(text, "markdown_inline"):parse()[1]:root())

  -- equal highlight lists share one table so chunks with them can merge
  local cache = {}
  local function hl_of(list)
    local all = vim.list_extend({ hl }, list or {})
    if #all <= 1 then
      return all[1]
    end
    local key = table.concat(all, ",")
    cache[key] = cache[key] or all
    return cache[key]
  end
  local words, word, sp = {}, nil, nil
  local function put(s, h)
    if not word then
      word = { sp = sp }
      words[#words + 1] = word
    end
    local last = word[#word]
    if last and last[2] == h then
      last[1] = last[1] .. s
    else
      word[#word + 1] = { s, h }
    end
  end
  local starts = vim.str_utf_pos(text)
  for n, p in ipairs(starts) do
    if prefix[p] then
      put(prefix[p], link.highlight)
    end
    if not hide[p] then
      local ch = text:sub(p, (starts[n + 1] or #text + 1) - 1)
      if ch:match("^%s$") then
        word, sp = nil, hl_of(hls[p])
      else
        put(ch, hl_of(hls[p]))
      end
    end
  end
  return words
end

-- Greedy word wrap; words wider than `w` are split by character.
function M.wrap(words, w)
  local lines, cur, cur_w = {}, {}, 0
  local function put(text, hl, tw)
    local last = cur[#cur]
    if last and last[2] == hl then
      last[1] = last[1] .. text
    else
      cur[#cur + 1] = { text, hl }
    end
    cur_w = cur_w + tw
  end
  local function flush()
    lines[#lines + 1] = cur
    cur, cur_w = {}, 0
  end
  for _, word in ipairs(words) do
    local ww = 0
    for _, c in ipairs(word) do
      ww = ww + width(c[1])
    end
    if cur_w > 0 and cur_w + 1 + ww > w then
      flush()
    end
    if cur_w > 0 then
      put(" ", word.sp, 1)
    end
    if ww <= w - cur_w then
      for _, c in ipairs(word) do
        put(c[1], c[2], width(c[1]))
      end
    else
      for _, c in ipairs(word) do
        for _, ch in ipairs(vim.fn.split(c[1], "\\zs")) do
          local cw = width(ch)
          if cur_w + cw > w and cur_w > 0 then
            flush()
          end
          put(ch, c[2], cw)
        end
      end
    end
  end
  if cur_w > 0 or #lines == 0 then
    flush()
  end
  return lines
end

-- Share `budget` between columns, narrowest first: a column that fits keeps
-- its natural width, the wide ones split what is left.
function M.col_widths(naturals, budget)
  local order = {}
  for i in ipairs(naturals) do
    order[i] = i
  end
  table.sort(order, function(a, b)
    return naturals[a] < naturals[b]
  end)
  local widths, left = {}, budget
  for k, i in ipairs(order) do
    widths[i] = math.max(1, math.min(naturals[i], math.floor(left / (#order - k + 1))))
    left = left - widths[i]
  end
  return widths
end

-- Extmarks are per buffer, so fit the narrowest window showing it in this
-- tab (e.g. a zen float over the original window), not just ctx.win.
local function text_width(buf, fallback)
  local tab, w = vim.api.nvim_get_current_tabpage(), nil
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_get_tabpage(win) == tab then
      local ww = vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
      w = math.min(w or ww, ww)
    end
  end
  return w or vim.api.nvim_win_get_width(fallback) - vim.fn.getwininfo(fallback)[1].textoff
end

local function line_width(chunks)
  local n = 0
  for _, c in ipairs(chunks) do
    n = n + width(c[1])
  end
  return n
end

-- Returns false when the table should get the plugin's normal rendering.
local function render(self)
  local cfg, data, ctx = self.config, self.data, self.context
  if not (cfg.cell == "padded" or cfg.cell == "trimmed") or not data.layout.valid then
    return false
  end
  local ncols = #data.cols
  local avail = text_width(ctx.buf, ctx.win)
  local natural = data.layout.col + ncols + 1
  for _, col in ipairs(data.cols) do
    natural = natural + col.width
  end
  if natural <= avail then
    return false
  end
  local budget = avail - data.layout.col - (ncols + 1) - 2 * cfg.padding * ncols
  if budget < 3 * ncols then
    return false
  end

  local rows, naturals = {}, {}
  for c = 1, ncols do
    naturals[c] = 1
  end
  for r, row in ipairs(data.rows) do
    local hl = row.node.type == "pipe_table_header" and "@markup.strong" or nil
    rows[r] = {}
    for c, cell in ipairs(row.cells) do
      rows[r][c] = M.words(cell.node.text, hl, ctx.config.link)
      naturals[c] = math.max(naturals[c], line_width(M.wrap(rows[r][c], math.huge)[1]))
    end
  end
  local widths = M.col_widths(naturals, budget)

  local b, pad = cfg.border, cfg.padding
  local virt = {}
  local function new_line()
    return self:indent():line(true):pad(data.layout.col)
  end
  local function rule(l, m, r, hl, indicators)
    local parts = {}
    for c, w in ipairs(widths) do
      local seg = b[11]:rep(w + 2 * pad)
      local align = data.cols[c].alignment
      if indicators and w + 2 * pad >= 3 and align ~= "default" then
        local ind = cfg.alignment_indicator
        local inner = b[11]:rep(w + 2 * pad - 2)
        seg = (align == "right" and b[11] or ind) .. inner .. (align == "left" and b[11] or ind)
      end
      parts[c] = seg
    end
    virt[#virt + 1] = new_line():text(l .. table.concat(parts, m) .. r, hl):get()
  end

  rule(b[1], b[2], b[3], cfg.head)
  for r, row in ipairs(data.rows) do
    local header = row.node.type == "pipe_table_header"
    local hl = header and cfg.head or cfg.row
    local cells, height = {}, 1
    for c = 1, ncols do
      cells[c] = M.wrap(rows[r][c], widths[c])
      height = math.max(height, #cells[c])
    end
    for l = 1, height do
      local line = new_line():text(b[10], hl)
      for c = 1, ncols do
        local chunks = cells[c][l] or {}
        local fill = widths[c] - line_width(chunks)
        local align = data.cols[c].alignment
        local left = align == "right" and fill or align == "center" and math.floor(fill / 2) or 0
        line:pad(pad + left)
        for _, chunk in ipairs(chunks) do
          line:text(chunk[1], chunk[2])
        end
        line:pad(pad + fill - left):text(b[10], hl)
      end
      virt[#virt + 1] = line:get()
    end
    if header then
      rule(b[4], b[5], b[6], cfg.head, true)
    end
  end
  rule(b[7], b[8], b[9], cfg.row)

  -- virt_lines must sit on a visible line: the one after the table, else the one before.
  local first, last = data.rows[1].node.start_row, data.rows[#data.rows].node.start_row
  local anchor, above
  if last + 1 < vim.api.nvim_buf_line_count(ctx.buf) then
    anchor, above = last + 1, true
  elseif math.min(first, data.delim.start_row) > 0 then
    anchor, above = math.min(first, data.delim.start_row) - 1, false
  else
    return false
  end

  for _, row in ipairs(data.rows) do
    self.marks:add(cfg, true, row.node.start_row, 0, { conceal_lines = "" })
  end
  self.marks:add(cfg, true, data.delim.start_row, 0, { conceal_lines = "" })
  self.marks:add(cfg, false, anchor, 0, { virt_lines = virt, virt_lines_above = above })
  return true
end

function M.setup()
  local Render = require("render-markdown.render.markdown.table")
  local run = Render.run
  function Render:run()
    -- render() adds marks only after all its work succeeded, so a failure
    -- (e.g. plugin internals changed) falls back cleanly.
    local ok, done = pcall(render, self)
    if not (ok and done) then
      run(self)
    end
  end

  -- render-markdown skips re-rendering a buffer that didn't change, so a
  -- window opened or closed on it (zen float) would keep the old table width.
  vim.api.nvim_create_autocmd({ "WinNew", "WinClosed" }, {
    group = vim.api.nvim_create_augroup("md_table_wrap", {}),
    callback = function()
      vim.schedule(function()
        local seen = {}
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          local buf = vim.api.nvim_win_get_buf(win)
          if not seen[buf] and vim.bo[buf].filetype == "markdown" then
            seen[buf] = true
            require("render-markdown").render({ buf = buf, event = "md_table_wrap" })
          end
        end
      end)
    end,
  })
end

function M._check()
  local w = M.col_widths({ 5, 40, 30 }, 50)
  assert(w[1] == 5 and w[2] + w[3] <= 45 and w[2] >= 20 and w[3] >= 20, vim.inspect(w))
  w = M.col_widths({ 5, 10 }, 50)
  assert(w[1] == 5 and w[2] == 10, vim.inspect(w))

  local words = M.words(" see `a b`, `c` and x\\|y ", nil)
  assert(#words == 6, vim.inspect(words))
  assert(words[3][1][1] == "b" and words[3][1][2] == CODE and words[3].sp == CODE, vim.inspect(words[3]))
  assert(words[3][2][1] == "," and words[3][2][2] == nil, "comma glued to code span")
  assert(words[2].sp == nil and words[6][1][1] == "x|y")

  local lines = M.wrap(M.words("aaa bbb ccc", nil), 7)
  assert(#lines == 2 and lines[1][1][1] == "aaa bbb" and lines[2][1][1] == "ccc", vim.inspect(lines))
  lines = M.wrap(M.words("abcdefghij", nil), 4)
  assert(#lines == 3 and lines[3][1][1] == "ij", vim.inspect(lines))
  lines = M.wrap(M.words("x `p q`", nil), 10)
  assert(vim.deep_equal(lines[1], { { "x ", nil }, { "p q", CODE } }), vim.inspect(lines))
  local link = { enabled = true, hyperlink = "@", highlight = "L" }
  words = M.words("**b** [l](u) <http://u>", nil, link)
  assert(vim.deep_equal(words[1][1], { "b", "@markup.strong" }), vim.inspect(words))
  assert(vim.deep_equal(words[2], { { "@", "L" }, { "l", "@markup.link.label" } }), vim.inspect(words[2]))
  assert(words[3][2][1] == "http://u", vim.inspect(words[3]))
  assert(M.words("`a \\| b`")[2][1][1] == "|", "\\| unescaped inside code")
  words = M.words("**x** y", "H")
  assert(vim.deep_equal(words[1][1], { "x", { "H", "@markup.strong" } }) and words[2][1][2] == "H", vim.inspect(words))
  print("md_table_wrap: ok")
end

return M
