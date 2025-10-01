-- lua/translate.lua

local M = {}

local function strip_ansi(s)
  if not s or s == '' then
    return s
  end
  -- CSI: ESC [ ... <final byte @-~>
  s = s:gsub('\27%[[0-?]*[ -/]*[@-~]', '')
  -- Single-char escapes: ESC <char>
  s = s:gsub('\27[@-Z\\-_]', '')
  -- OSC: ESC ] ... BEL  OR  ESC ] ... ESC \

  s = s:gsub('\27%].-\7', '') -- ESC ] ... BEL
  s = s:gsub('\27%].-\27\\', '') -- ESC ] ... ESC \

  return s
end

-- Join lines and trim
local function trim(s)
  return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

-- Safely get visual selection (single or multi-line), preserving spaces

local function get_visual_selection()
  local _, csrow, cscol, _ = unpack(vim.fn.getpos "'<")

  local _, cerow, cecol, _ = unpack(vim.fn.getpos "'>")
  if csrow == 0 or cerow == 0 then
    return nil
  end

  if csrow > cerow or (csrow == cerow and cscol > cecol) then
    csrow, cerow = cerow, csrow
    cscol, cecol = cecol, cscol
  end

  local lines = vim.api.nvim_buf_get_lines(0, csrow - 1, cerow, false)
  if #lines == 0 then
    return nil
  end
  lines[1] = string.sub(lines[1], cscol, #lines[1])
  lines[#lines] = string.sub(lines[#lines], 1, cecol)
  return trim(table.concat(lines, ' '))
end

-- Open a hover-like floating window using LSP util
local function open_hover(markdown_lines, opts)
  opts = opts or {}

  local bufnr, winnr = vim.lsp.util.open_floating_preview(

    markdown_lines,
    'markdown',
    vim.tbl_deep_extend('force', {

      border = 'rounded',
      focusable = true,

      focus = true,
      max_width = math.floor(vim.o.columns * 0.5),
      max_height = math.floor(vim.o.lines * 0.4),
      anchor = 'NW',
    }, opts or {})
  )
  -- Close on typical events
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'BufHidden', 'InsertEnter' }, {
    buffer = 0,
    once = true,
    callback = function()
      if vim.api.nvim_win_is_valid(winnr) then
        vim.api.nvim_win_close(winnr, true)
      end
    end,
  })
  return bufnr, winnr
end

local function run_trans(text, lang, brief)
  lang = lang or ':en'
  local args = { 'trans' }

  if brief == true then
    table.insert(args, '-brief')
  end
  table.insert(args, '--no-ansi')
  table.insert(args, lang)

  table.insert(args, text)

  local out, err = {}, {}

  local job_id = vim.fn.jobstart(args, {
    stdout_buffered = true,
    stderr_buffered = true,
    -- Prevent pagers / colorization from upstream tools
    env = {
      NO_COLOR = '1',
      TERM = 'dumb',
      PAGER = 'cat',
      LESS = 'FRX', -- fast/raw, no init/clear
      LESSANSIENDCHARS = 'mK', -- avoid weird endings
    },
    on_stdout = function(_, data)
      if not data then
        return
      end
      for _, line in ipairs(data) do
        if line and line ~= '' then
          table.insert(out, strip_ansi(line))
        end
      end
    end,
    on_stderr = function(_, data)
      if not data then
        return
      end
      for _, line in ipairs(data) do
        if line and line ~= '' then
          table.insert(err, strip_ansi(line))
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 then
          open_hover { ('**trans failed (%d):**\n\n```\n%s\n```'):format(code, table.concat(err, '\n')) }

          return
        end
        if #out == 0 then
          open_hover { '_No translation returned._' }
          return
        end
        local md = { '### Translation', '' }
        for _, line in ipairs(out) do
          table.insert(md, line)
        end
        open_hover(md)
      end)
    end,
  })

  if job_id <= 0 then
    open_hover { '**Failed to start `trans` process.**\n\nIs translate-shell installed and on $PATH?' }
  end
end

-- Build the job and show output
-- Public: translate word under cursor or visual selection
function M.translate(opts)
  opts = opts or {}
  local lang = opts.lang or ':en'
  local brief = opts.brief

  local text
  -- Prefer visual selection if we're in visual mode or range was given
  local mode = vim.api.nvim_get_mode().mode
  if mode:match '[vV\22]' then
    text = get_visual_selection()
  end
  if not text or text == '' then
    -- fallback: word under cursor
    text = vim.fn.expand '<cword>'
  end

  if not text or text == '' then
    open_hover { '_Nothing to translate._' }
    return
  end

  run_trans(text, lang, brief)
end

-- User command: :Trans [lang]
-- Usage:

--   :Trans           -> translate word under cursor to English (brief)
--   :Trans :bg       -> translate to Bulgarian (brief)
--   :Trans! :ru      -> full output (remove -brief)
vim.api.nvim_create_user_command('Trans', function(cmd)
  M.translate {
    lang = cmd.args ~= '' and cmd.args or ':en',

    brief = not cmd.bang, -- default brief; use :Trans! to show full output
  }
end, {
  nargs = '?',

  bang = true,
  desc = 'Translate word/selection with translate-shell and show in hover',
})

return M
