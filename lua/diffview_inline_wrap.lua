-- diff1_inline draws deleted lines as virt_lines, which Neovim never wraps.
-- Pre-wrap them to the window's text width (honouring 'linebreak'), so a
-- long deleted line reads like the wrapped added line below it.
local M = {}

local function base_hl(hl)
  return type(hl) == "table" and hl[1] or hl
end

-- Split one virt_line (list of {text, hl} chunks) into rows of `width` cells
function M.wrap_line(chunks, width, linebreak, breakat, pad)
  local cells, total = {}, 0
  for _, c in ipairs(chunks) do
    for _, ch in ipairs(vim.fn.split(c[1], "\\zs")) do
      -- ponytail: tabs count as their 1-cell strdisplaywidth, not to the next tabstop
      local w = vim.fn.strdisplaywidth(ch)
      cells[#cells + 1] = { ch, c[2], w }
      total = total + w
    end
  end
  if total <= width then
    return { chunks }
  end

  local rows, row, used = {}, {}, 0
  for _, cell in ipairs(cells) do
    if used + cell[3] > width and #row > 0 then
      local carry = {}
      if linebreak then
        for i = #row, 1, -1 do
          if breakat:find(row[i][1], 1, true) then
            carry = vim.list_slice(row, i + 1)
            row = vim.list_slice(row, 1, i)
            break
          end
        end
      end
      rows[#rows + 1] = row
      row, used = carry, 0
      for _, c in ipairs(carry) do
        used = used + c[3]
      end
    end
    row[#row + 1] = cell
    used = used + cell[3]
  end
  rows[#rows + 1] = row

  local out = {}
  for _, r in ipairs(rows) do
    local line, w = {}, 0
    for _, cell in ipairs(r) do
      local last = line[#line]
      if last and vim.deep_equal(last[2], cell[2]) then
        last[1] = last[1] .. cell[1]
      else
        line[#line + 1] = { cell[1], cell[2] }
      end
      w = w + cell[3]
    end
    if pad and w < width and r[1] then
      line[#line + 1] = { string.rep(" ", width - w), base_hl(r[1][2]) }
    end
    out[#out + 1] = line
  end
  return out
end

-- Old side of each buffer's last inline render, for M.table_diff
local old_by_buf = {}

-- The inline diff of `buf` by 0-based row, for md_table_wrap: `hl` is the
-- line highlight of an added/changed row, `before`/`after` are the old
-- lines deleted above/below that row (where diffview anchors their virt_lines).
function M.table_diff(buf)
  local old = old_by_buf[buf]
  local hunks = old and require("diffview.scene.inline_diff").get_hunks(buf)
  if not hunks then
    return nil
  end
  local d = { hl = {}, before = {}, after = {} }
  for _, h in ipairs(hunks) do
    local os, oc, ns, nc = h[1], h[2], h[3], h[4]
    for k = 0, nc - 1 do
      d.hl[ns - 1 + k] = k < oc and "DiffviewDiffChange" or "DiffviewDiffAdd"
    end
    if oc > 0 then
      local lines = vim.list_slice(old, os, os + oc - 1)
      if nc > 0 or ns == 0 then
        d.before[math.max(ns - 1, 0)] = lines
      else
        d.after[ns - 1] = lines
      end
    end
  end
  return d
end

-- render-markdown draws tables from M.table_diff, so redraw after it changes
local function rerender(buf)
  vim.schedule(function()
    if package.loaded["render-markdown"] and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "markdown" then
      require("render-markdown").render({ buf = buf, event = "diffview_inline" })
    end
  end)
end

function M.setup()
  local inline = require("diffview.scene.inline_diff")
  local render, clear = inline.render, inline.clear
  inline.render = function(buf, old_lines, ...)
    render(buf, old_lines, ...)
    old_by_buf[buf] = old_lines
    rerender(buf)
  end
  inline.clear = function(buf)
    clear(buf)
    if buf and old_by_buf[buf] then
      old_by_buf[buf] = nil
      rerender(buf)
    end
  end

  local ns = inline.ns
  local set_extmark = vim.api.nvim_buf_set_extmark
  vim.api.nvim_buf_set_extmark = function(buf, id, row, col, opts)
    if id == ns and opts and opts.virt_lines then
      local win = vim.fn.bufwinid(buf)
      local info = win ~= -1 and vim.fn.getwininfo(win)[1]
      if info and vim.wo[win].wrap then
        local width = info.width - info.textoff
        local inline = require("diffview.config").get_config().view.inline or {}
        local lines = {}
        for _, l in ipairs(opts.virt_lines) do
          vim.list_extend(
            lines,
            M.wrap_line(l, width, vim.wo[win].linebreak, vim.o.breakat, inline.deletion_highlight == "full_width")
          )
        end
        opts = vim.tbl_extend("force", opts, { virt_lines = lines })
      end
    end
    return set_extmark(buf, id, row, col, opts)
  end

  -- re-emit the deleted rows when wrapping is toggled after the render
  vim.api.nvim_create_autocmd("OptionSet", {
    pattern = { "wrap", "linebreak" },
    callback = function()
      local view = require("diffview.lib").get_current_view()
      local layout = view and view.cur_layout
      if layout and layout._repaint then
        layout:_repaint()
      end
    end,
  })
end

return M
