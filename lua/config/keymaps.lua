-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

local map = vim.keymap.set

pcall(vim.keymap.del, "n", "<leader>l")

local function stop_lsp_for_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    vim.notify("No LSP clients attached to buffer " .. bufnr, vim.log.levels.INFO)
    return
  end

  vim.lsp.stop_client(clients)
  vim.notify("Stopped " .. #clients .. " LSP client(s) for buffer " .. bufnr, vim.log.levels.INFO)
end

vim.api.nvim_create_user_command("LspStopBuffer", function()
  stop_lsp_for_buffer(0)
end, { desc = "Stop LSP clients attached to the current buffer" })

vim.api.nvim_create_user_command("LspStopWindow", function()
  stop_lsp_for_buffer(vim.api.nvim_win_get_buf(0))
end, { desc = "Stop LSP clients attached to the current window's buffer" })

vim.api.nvim_create_user_command("LspStopTab", function()
  local seen = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local bufnr = vim.api.nvim_win_get_buf(win)
    if not seen[bufnr] then
      seen[bufnr] = true
      stop_lsp_for_buffer(bufnr)
    end
  end
end, { desc = "Stop LSP clients attached to buffers visible in the current tab" })

map("n", "<leader>ft", function()
  require("telescope").extensions.tab_switch.tabs()
end, { desc = "Telescope: switch tabs" })

map("n", "<leader>fd", "<cmd>Telescope find_files find_command=find,.,-type,d<cr>", { desc = "Find directories" })
map("n", "<leader>G", "<cmd>Neogit<cr>", { desc = "Neogit" })
map("n", "<leader>fm", function()
  require("mini.files").open(vim.api.nvim_buf_get_name(0), true)
end, { desc = "Files" })

map("n", "<leader><leader>", function()
  require("telescope.builtin").find_files()
end, { desc = "Global search" })
map("n", "<leader>,", function()
  require("telescope.builtin").buffers()
end, { desc = "Opened buffers" })
map("n", "<leader>/", function()
  require("telescope_search").live_grep()
end, { desc = "Global grep (<C-f> literal)" })
map("n", "<leader>s.", function()
  require("telescope_search").grep_in_dir()
end, { desc = "Grep in directory" })
map("n", "<leader>fo", function()
  require("telescope_search").find_files_in_dir()
end, { desc = "Find files in directory" })
map("n", "<leader>ir", function()
  require("telescope.builtin").registers()
end, { desc = "Show registers" })
map("n", "<leader>ik", function()
  require("telescope.builtin").keymaps()
end, { desc = "Show keymaps" })
map("n", "<leader>bj", function()
  require("telescope.builtin").current_buffer_fuzzy_find()
end, { desc = "Current buffer fuzzy find" })
map("n", "<leader>fc", function()
  require("telescope.builtin").commands()
end, { desc = "Find command" })
map("n", "<leader>fj", function()
  require("telescope.builtin").jumplist()
end, { desc = "Jumps" })
map("n", "<leader>tf", function()
  require("neotest").run.run(vim.fn.expand("%"))
end, { desc = "Run File" })

map("n", "<leader>dte", function()
  require("translate").translate({ lang = ":en" })
end, { desc = "Translate word to :en" })
map("v", "<leader>dte", function()
  require("translate").translate({ lang = ":en" })
end, { desc = "Translate selection to :en" })
map({ "n", "v" }, "<leader>dtr", function()
  require("translate").translate({ lang = ":ru" })
end, { desc = "Translate to :ru" })

local function current_window_is_loclist()
  local wininfo = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
  return wininfo and wininfo.quickfix == 1 and wininfo.loclist == 1
end

local loclist_undo = {}

local function get_loclist_context()
  local current_win = vim.api.nvim_get_current_win()
  local in_loclist_win = current_window_is_loclist()
  local locinfo = vim.fn.getloclist(current_win, { filewinid = 0, id = 0, idx = 0, items = 0, title = 0 })
  local loclist_win = locinfo.filewinid ~= 0 and locinfo.filewinid or current_win
  local key = locinfo.id ~= 0 and locinfo.id or loclist_win

  return {
    current_win = current_win,
    in_loclist_win = in_loclist_win,
    locinfo = locinfo,
    loclist_win = loclist_win,
    key = key,
  }
end

local function push_loclist_undo(context, cursor_idx)
  local stack = loclist_undo[context.key] or {}
  loclist_undo[context.key] = stack

  table.insert(stack, {
    cursor_idx = cursor_idx,
    idx = context.locinfo.idx,
    items = vim.deepcopy(context.locinfo.items or {}),
    title = context.locinfo.title,
  })
end

local function delete_current_loclist_entry()
  local context = get_loclist_context()
  local loclist = context.locinfo.items or {}

  if #loclist == 0 then
    return
  end

  local idx = context.in_loclist_win and vim.fn.line(".") or context.locinfo.idx
  if not idx or idx < 1 or idx > #loclist then
    return
  end

  push_loclist_undo(context, idx)
  table.remove(loclist, idx)

  if #loclist == 0 and not context.in_loclist_win then
    vim.cmd("lclose")
  else
    local next_idx = math.min(idx, #loclist)
    vim.fn.setloclist(context.loclist_win, {}, "r", {
      idx = next_idx,
      items = loclist,
      quickfixtextfunc = require("loclist_context").quickfixtextfunc,
      title = context.locinfo.title,
    })

    if context.in_loclist_win and next_idx > 0 and vim.api.nvim_win_is_valid(context.current_win) then
      vim.api.nvim_win_set_cursor(context.current_win, { next_idx, 0 })
    end
  end
end

local function undo_loclist_delete()
  local context = get_loclist_context()
  local stack = loclist_undo[context.key]
  local previous = stack and table.remove(stack)

  if not previous then
    return
  end

  vim.fn.setloclist(context.loclist_win, {}, "r", {
    idx = previous.idx,
    items = previous.items,
    quickfixtextfunc = require("loclist_context").quickfixtextfunc,
    title = previous.title,
  })

  if context.in_loclist_win and vim.api.nvim_win_is_valid(context.current_win) then
    vim.api.nvim_win_set_cursor(context.current_win, { math.min(previous.cursor_idx, #previous.items), 0 })
  end
end

local function open_current_loclist()
  local context = get_loclist_context()
  require("loclist_context").refresh(context.loclist_win, { load = true })
  vim.cmd("lopen")
end

map("n", "<leader>ld", delete_current_loclist_entry, { desc = "Loclist: delete current entry" })

vim.api.nvim_create_autocmd("FileType", {
  pattern = "qf",
  callback = function(event)
    if not current_window_is_loclist() then
      return
    end

    map("n", "dd", delete_current_loclist_entry, {
      buffer = event.buf,
      desc = "Loclist: delete current entry",
    })
    map("n", "u", undo_loclist_delete, {
      buffer = event.buf,
      desc = "Loclist: undo delete",
    })
  end,
})

map("n", "<leader>lo", open_current_loclist, { desc = "Loclist: open" })
map("n", "<leader>lc", "<cmd>lclose<cr>", { desc = "Loclist: close" })

local ll = require("named_loclist")

map("n", "<leader>la", ll.add_current, { desc = "Loclist: add current" })
map("n", "<leader>lw", function()
  vim.ui.input({ prompt = "Save loclist as: " }, function(name)
    if name then
      ll.save(name)
    end
  end)
end, { desc = "Loclist: save named" })
map("n", "<leader>ls", ll.telescope_switch, { desc = "Loclist: switch" })

-- Copy file name / path to the system clipboard
local function copy_to_clipboard(value, label)
  vim.fn.setreg("+", value)
  vim.notify(label .. ": " .. value)
end

map("n", "<leader>yn", function()
  copy_to_clipboard(vim.fn.expand("%:t"), "Copied name")
end, { desc = "Copy file name" })
map("n", "<leader>yp", function()
  copy_to_clipboard(vim.fn.expand("%:."), "Copied path")
end, { desc = "Copy relative path" })
map("n", "<leader>yP", function()
  copy_to_clipboard(vim.fn.expand("%:p"), "Copied path")
end, { desc = "Copy absolute path" })

map("n", "<leader>oo", "<cmd>Obsidian open<cr>", { desc = "Obsidian: open" })
map("n", "<leader>oc", "<cmd>Obsidian check<cr>", { desc = "Obsidian: check" })
map("n", "<leader>ot", "<cmd>Obsidian today<cr>", { desc = "Obsidian: today" })
map("n", "<leader>oq", "<cmd>Obsidian quick_switch<cr>", { desc = "Obsidian: switch" })
map("n", "<leader>os", "<cmd>Obsidian search<cr>", { desc = "Obsidian: search" })
map("n", "<leader>ow", "<cmd>Obsidian workspace<cr>", { desc = "Obsidian: workspace" })
map("n", "<leader>or", "<cmd>Obsidian rename<cr>", { desc = "Obsidian: rename" })
