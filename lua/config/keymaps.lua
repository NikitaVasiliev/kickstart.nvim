-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

local map = vim.keymap.set

pcall(vim.keymap.del, "n", "<leader>l")

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
  require("telescope.builtin").live_grep()
end, { desc = "Global grep" })
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

map("n", "<leader>ld", function()
  local win = 0
  local loclist = vim.fn.getloclist(win)
  if #loclist == 0 then
    return
  end

  local idx = vim.fn.getloclist(win, { idx = 0 }).idx
  if not idx or idx < 1 or idx > #loclist then
    return
  end

  table.remove(loclist, idx)
  vim.fn.setloclist(win, {}, "r", { items = loclist })

  if #loclist == 0 then
    vim.cmd("lclose")
  elseif idx > #loclist then
    vim.cmd("llast")
  else
    vim.cmd("lnext")
  end
end, { desc = "Loclist: delete current entry" })

map("n", "<leader>lo", "<cmd>lopen<cr>", { desc = "Loclist: open" })
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

map("n", "<leader>oo", "<cmd>Obsidian open<cr>", { desc = "Obsidian: open" })
map("n", "<leader>oc", "<cmd>Obsidian check<cr>", { desc = "Obsidian: check" })
map("n", "<leader>ot", "<cmd>Obsidian today<cr>", { desc = "Obsidian: today" })
map("n", "<leader>oq", "<cmd>Obsidian quick_switch<cr>", { desc = "Obsidian: switch" })
map("n", "<leader>os", "<cmd>Obsidian search<cr>", { desc = "Obsidian: search" })
map("n", "<leader>ow", "<cmd>Obsidian workspace<cr>", { desc = "Obsidian: workspace" })
map("n", "<leader>or", "<cmd>Obsidian rename<cr>", { desc = "Obsidian: rename" })
