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
    config = function()
      local function diffview_opts()
        -- Characters are ~2x taller than wide, so on a portrait screen cols/lines < 2
        local portrait = vim.o.columns < vim.o.lines * 2
        local layout = portrait and "diff2_vertical" or "diff2_horizontal"
        return {
          view = {
            default = { layout = layout },
            file_history = { layout = layout },
            merge_tool = {
              layout = portrait and "diff3_vertical" or "diff3_horizontal",
              winbar_info = true,
            },
          },
        }
      end
      require("diffview").setup(diffview_opts())
      vim.api.nvim_create_autocmd("VimResized", {
        callback = function()
          require("diffview").setup(diffview_opts())
        end,
      })
    end,
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
    "lewis6991/gitsigns.nvim",
    opts = {
      signs = {
        add = { text = "+" },
        change = { text = "~" },
        delete = { text = "_" },
        topdelete = { text = "‾" },
        changedelete = { text = "~" },
      },
      signs_staged_enable = true,
      signcolumn = true, -- Toggle with `:Gitsigns toggle_signs`
      numhl = false, -- Toggle with `:Gitsigns toggle_numhl`
      linehl = false, -- Toggle with `:Gitsigns toggle_linehl`
      word_diff = false, -- Toggle with `:Gitsigns toggle_word_diff`
      watch_gitdir = {
        follow_files = true,
      },
      auto_attach = true,
      attach_to_untracked = false,
      current_line_blame = true, -- Toggle with `:Gitsigns toggle_current_line_blame`
      current_line_blame_opts = {
        virt_text = true,
        virt_text_pos = "eol", -- 'eol' | 'overlay' | 'right_align'
        delay = 1000,
        ignore_whitespace = false,
        virt_text_priority = 100,
        use_focus = true,
      },
      current_line_blame_formatter = "<author>, <author_time:%Y-%m-%d> - <summary> (<abbrev_sha>)",
      sign_priority = 6,
      update_debounce = 100,
      status_formatter = nil, -- Use default
      max_file_length = 40000, -- Disable if file is longer than this (in lines)
      preview_config = {
        -- Options passed to nvim_open_win
        border = "single",
        style = "minimal",
        relative = "cursor",
        row = 0,
        col = 1,
      },
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
