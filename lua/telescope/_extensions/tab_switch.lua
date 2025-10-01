-- Minimal, safe tab switcher for Telescope:
--   <CR>  -> jump to selected tab
--   <C-d> -> close selected tab
--   <C-r> -> close selected tab and reopen the picker (refresh)
local ok, telescope = pcall(require, 'telescope')
if not ok then
  error 'tab_switch: requires nvim-telescope/telescope.nvim'
end

local pickers = require 'telescope.pickers'
local finders = require 'telescope.finders'
local conf = require('telescope.config').values
local actions = require 'telescope.actions'
local action_state = require 'telescope.actions.state'
local entry_display = require 'telescope.pickers.entry_display'

local function get_cwd()
  if vim.uv and vim.uv.cwd then
    return vim.uv.cwd()
  end
  if vim.loop and vim.loop.cwd then
    return vim.loop.cwd()
  end
  return nil
end

-- Build entries for all tabpages.
local function collect_tab_entries()
  local tabs = vim.api.nvim_list_tabpages()
  local entries = {}

  local cwd = get_cwd()

  for idx, tab in ipairs(tabs) do
    local win = vim.api.nvim_tabpage_get_win(tab)
    local buf = vim.api.nvim_win_get_buf(win)

    local fullpath = vim.api.nvim_buf_get_name(buf)

    if fullpath == '' then
      fullpath = '[No Name]'
    end

    local short = vim.fn.fnamemodify(fullpath, ':.')
    if cwd and short:sub(1, #cwd) == cwd then
      short = short:sub(#cwd + 2)
    end

    local modified = vim.api.nvim_buf_get_option(buf, 'modified') and ' [+]' or ''

    local win_count = #vim.api.nvim_tabpage_list_wins(tab)

    local function make_display()
      local displayer = entry_display.create {
        separator = ' ',
        items = {
          { width = 3 }, -- index
          { remaining = true }, -- filename
          { width = 6 }, -- [+]
          { width = 6 }, -- (Nw)
        },
      }

      return displayer {
        { tostring(idx), 'TelescopeResultsNumber' },
        short,
        modified,
        string.format('(%dw)', win_count),
      }
    end

    table.insert(entries, {
      ordinal = string.format('%d %s', idx, short),
      display = make_display,
      value = {
        index = idx,
        tab = tab,
        buf = buf,
        path = fullpath,
        short = short,
      },
    })
  end

  return entries
end

local function pick_tabs(opts)
  opts = opts or {}

  pickers
    .new(opts, {
      prompt_title = 'Tabs',
      finder = finders.new_table {
        results = collect_tab_entries(),
        entry_maker = function(e)
          return e
        end,
      },
      sorter = conf.generic_sorter(opts),
      previewer = false,

      attach_mappings = function(prompt_bufnr, map)
        -- Close picker first, then run fn on next tick with selected entry.
        local function with_selected(fn)
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          vim.schedule(function()
            if entry and entry.value then
              pcall(fn, entry.value)
            end
          end)
        end

        -- <CR>: jump to selected tab
        actions.select_default:replace(function()
          with_selected(function(val)
            if vim.api.nvim_set_current_tabpage then
              pcall(vim.api.nvim_set_current_tabpage, val.tab)
            else
              vim.cmd('tabnext ' .. tostring(val.index))
            end
          end)
        end)

        -- <C-d>: close selected tab by index
        map({ 'i', 'n' }, '<C-d>', function()
          with_selected(function(val)
            pcall(vim.cmd, 'tabclose ' .. tostring(val.index))
          end)
        end)

        -- <C-r>: close then reopen picker (refresh)
        map({ 'i', 'n' }, '<C-r>', function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          vim.schedule(function()
            if entry and entry.value then
              pcall(vim.cmd, 'tabclose ' .. tostring(entry.value.index))
            end
            vim.schedule(function()
              require('telescope').extensions.tab_switch.tabs(opts)
            end)
          end)
        end)

        return true
      end,
    })
    :find()
end

return telescope.register_extension {
  exports = {
    tabs = pick_tabs,
  },
}
