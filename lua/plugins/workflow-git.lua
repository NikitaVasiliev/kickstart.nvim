return {
  {
    "NeogitOrg/neogit",
    cmd = "Neogit",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "sindrets/diffview.nvim",
      "nvim-telescope/telescope.nvim",
    },
    config = true,
  },
  {
    "sindrets/diffview.nvim",
    cmd = {
      "DiffviewOpen",
      "DiffviewFileHistory",
    },
    keys = {
      { "<leader>Gd", "<cmd>DiffviewOpen<cr>", desc = "Repo Diffview" },
      { "<leader>Gh", "<cmd>DiffviewFileHistory<cr>", desc = "Repo history" },
      { "<leader>Gf", "<cmd>DiffviewFileHistory --follow %<cr>", desc = "File history" },
      { "<leader>Gm", "<cmd>DiffviewOpen master<cr>", desc = "Diff with master" },
      {
        "<leader>Gl",
        function()
          local current_line = vim.fn.line(".")
          local file = vim.fn.expand("%")
          vim.cmd(string.format("DiffviewFileHistory --follow -L%s,%s:%s", current_line, current_line, file))
        end,
        desc = "Line history",
      },
    },
    opts = {},
  },
  {
    "ThePrimeagen/harpoon",
    branch = "harpoon2",
    dependencies = { "nvim-lua/plenary.nvim" },
    config = function()
      local harpoon = require("harpoon")
      harpoon:setup()

      vim.keymap.set("n", "<leader>ha", function()
        harpoon:list():add()
      end, { desc = "Add to list" })
      vim.keymap.set("n", "<leader>hr", function()
        harpoon:list():clear()
      end, { desc = "Clear list" })
      vim.keymap.set("n", "<leader>hl", function()
        harpoon.ui:toggle_quick_menu(harpoon:list())
      end, { desc = "Show list" })

      vim.keymap.set("n", "<leader>hs", function()
        harpoon:list():select(1)
      end, { desc = "Switch to 1" })
      vim.keymap.set("n", "<leader>hd", function()
        harpoon:list():select(2)
      end, { desc = "Switch to 2" })
      vim.keymap.set("n", "<leader>hf", function()
        harpoon:list():select(3)
      end, { desc = "Switch to 3" })
      vim.keymap.set("n", "<leader>hg", function()
        harpoon:list():select(4)
      end, { desc = "Switch to 4" })
      vim.keymap.set("n", "<leader>hb", function()
        harpoon:list():prev()
      end, { desc = "Switch to previous" })
      vim.keymap.set("n", "<leader>hn", function()
        harpoon:list():next()
      end, { desc = "Switch to next" })
    end,
  },
  {
    "chentoast/marks.nvim",
    event = "VeryLazy",
    opts = {
      default_mappings = true,
    },
  },
  {
    "gcmt/vessel.nvim",
    event = "VeryLazy",
    config = function()
      local vessel = require("vessel")
      vessel.setup({
        create_commands = true,
        commands = {
          view_marks = "Marks",
        },
      })

      vim.keymap.set("n", "<leader>m", function()
        vessel.view_marks()
      end, { desc = "Marks" })
    end,
  },
}
