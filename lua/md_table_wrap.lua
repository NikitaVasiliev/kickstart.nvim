-- Wrap render-markdown.nvim tables that don't fit the window: each cell is
-- word-wrapped inside its column, so one table row takes several screen lines.
-- The raw rows are hidden with conceal_lines and the table is drawn as
-- virt_lines on the line next to it (virt_lines of a concealed line are hidden).
local M = {}

local CODE = "RenderMarkdownCodeInline"
local width = vim.fn.strdisplaywidth

-- Cell text -> words; a word is a list of {text, hl} chunks, word.sp is the
-- highlight of the space before it. Only code spans are highlighted.
-- ponytail: bold/italic/links render as raw text; take spans from the
-- markdown_inline tree if that matters.
function M.words(text, hl)
  text = vim.trim(text):gsub("\\|", "|")
  local words, glue = {}, false
  local function add(seg, h)
    local first = true
    for space, w in seg:gmatch("(%s*)(%S+)") do
      if glue and space == "" and #words > 0 then
        table.insert(words[#words], { w, h })
      else
        words[#words + 1] = { { w, h }, sp = (h == CODE and not first) and CODE or nil }
      end
      glue, first = true, false
    end
    if seg ~= "" then
      glue = not seg:find("%s$")
    end
  end
  local pos = 1
  while true do
    local s, e, code = text:find("`([^`]+)`", pos)
    if not s then
      add(text:sub(pos), hl)
      break
    end
    add(text:sub(pos, s - 1), hl)
    add(code, CODE)
    pos = e + 1
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
  local avail = vim.api.nvim_win_get_width(ctx.win) - vim.fn.getwininfo(ctx.win)[1].textoff
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
      rows[r][c] = M.words(cell.node.text, hl)
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
  print("md_table_wrap: ok")
end

return M
