local M = {}

local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

local function entry_to_locitem(entry)
  local value = type(entry.value) == "table" and entry.value or {}
  local filename = entry.path or entry.filename or value.path or value.filename
  local lnum = entry.lnum or entry.row or value.lnum or value.row or 1
  local col = entry.col or value.col or 1
  local text = entry.text or value.text or entry.ordinal or entry.value

  if not filename and entry.bufnr then
    filename = vim.api.nvim_buf_get_name(entry.bufnr)
  end

  if not filename or filename == "" then
    return nil
  end

  return {
    bufnr = entry.bufnr,
    filename = filename,
    lnum = lnum,
    col = col,
    text = type(text) == "string" and text or vim.inspect(text),
  }
end

local function set_picker_loclist(prompt_bufnr, entries)
  local picker = action_state.get_current_picker(prompt_bufnr)
  local items = {}

  for _, entry in ipairs(entries) do
    local item = entry_to_locitem(entry)
    if item then
      table.insert(items, item)
    end
  end

  if #items == 0 then
    vim.notify("No valid entries for location list", vim.log.levels.WARN)
    return
  end

  local title = string.format("%s (%s)", picker.prompt_title, picker:_get_prompt())
  actions.close(prompt_bufnr)
  vim.fn.setloclist(picker.original_win_id, {}, "r", {
    title = title,
    items = items,
  })
end

function M.send_current(prompt_bufnr)
  local picker = action_state.get_current_picker(prompt_bufnr)
  local multi = picker:get_multi_selection()

  if multi and #multi > 0 then
    set_picker_loclist(prompt_bufnr, multi)
    return
  end

  local entry = action_state.get_selected_entry()
  if entry then
    set_picker_loclist(prompt_bufnr, { entry })
  end
end

function M.send_all(prompt_bufnr)
  local picker = action_state.get_current_picker(prompt_bufnr)
  local entries = {}
  for entry in picker.manager:iter() do
    table.insert(entries, entry)
  end
  set_picker_loclist(prompt_bufnr, entries)
end

function M.attach_mappings(_, map)
  map("i", "<C-l>", M.send_current)
  map("i", "<C-q>", M.send_current)
  map("i", "<M-l>", M.send_all)
  map("i", "<A-l>", M.send_all)
  map("i", "<Esc>l", M.send_all)

  map("n", "<C-l>", M.send_current)
  map("n", "<C-q>", M.send_current)
  map("n", "<M-l>", M.send_all)
  map("n", "<A-l>", M.send_all)
  map("n", "<Esc>l", M.send_all)
  return true
end

return M
