local M = {}

local function strip_ansi(s)
  if not s or s == "" then
    return s
  end

  s = s:gsub("\27%[[0-?]*[ -/]*[@-~]", "")
  s = s:gsub("\27[@-Z\\-_]", "")
  s = s:gsub("\27%].-\7", "")
  s = s:gsub("\27%].-\27\\", "")
  return s
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function get_visual_selection()
  local _, csrow, cscol = unpack(vim.fn.getpos("'<"))
  local _, cerow, cecol = unpack(vim.fn.getpos("'>"))

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
  return trim(table.concat(lines, " "))
end

local function open_hover(markdown_lines, opts)
  opts = opts or {}
  local _, winnr = vim.lsp.util.open_floating_preview(
    markdown_lines,
    "markdown",
    vim.tbl_deep_extend("force", {
      border = "rounded",
      focusable = true,
      focus = true,
      max_width = math.floor(vim.o.columns * 0.5),
      max_height = math.floor(vim.o.lines * 0.4),
      anchor = "NW",
    }, opts)
  )

  vim.api.nvim_create_autocmd({ "CursorMoved", "BufHidden", "InsertEnter" }, {
    buffer = 0,
    once = true,
    callback = function()
      if vim.api.nvim_win_is_valid(winnr) then
        vim.api.nvim_win_close(winnr, true)
      end
    end,
  })
end

local function run_trans(text, lang, brief)
  local args = { "trans" }

  if brief == true then
    table.insert(args, "-brief")
  end

  table.insert(args, "--no-ansi")
  table.insert(args, lang or ":en")
  table.insert(args, text)

  local out = {}
  local err = {}

  local job_id = vim.fn.jobstart(args, {
    stdout_buffered = true,
    stderr_buffered = true,
    env = {
      NO_COLOR = "1",
      TERM = "dumb",
      PAGER = "cat",
      LESS = "FRX",
      LESSANSIENDCHARS = "mK",
    },
    on_stdout = function(_, data)
      if not data then
        return
      end
      for _, line in ipairs(data) do
        if line and line ~= "" then
          table.insert(out, strip_ansi(line))
        end
      end
    end,
    on_stderr = function(_, data)
      if not data then
        return
      end
      for _, line in ipairs(data) do
        if line and line ~= "" then
          table.insert(err, strip_ansi(line))
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 then
          open_hover({ ("**trans failed (%d):**\n\n```\n%s\n```"):format(code, table.concat(err, "\n")) })
          return
        end
        if #out == 0 then
          open_hover({ "_No translation returned._" })
          return
        end

        local md = { "### Translation", "" }
        vim.list_extend(md, out)
        open_hover(md)
      end)
    end,
  })

  if job_id <= 0 then
    open_hover({ "**Failed to start `trans` process.**\n\nIs translate-shell installed and on $PATH?" })
  end
end

function M.translate(opts)
  opts = opts or {}

  local text
  local mode = vim.api.nvim_get_mode().mode
  if mode:match("[vV\22]") then
    text = get_visual_selection()
  end

  if not text or text == "" then
    text = vim.fn.expand("<cword>")
  end

  if not text or text == "" then
    open_hover({ "_Nothing to translate._" })
    return
  end

  run_trans(text, opts.lang or ":en", opts.brief)
end

vim.api.nvim_create_user_command("Trans", function(cmd)
  M.translate({
    lang = cmd.args ~= "" and cmd.args or ":en",
    brief = not cmd.bang,
  })
end, {
  nargs = "?",
  bang = true,
  desc = "Translate word/selection with translate-shell and show in hover",
})

return M
