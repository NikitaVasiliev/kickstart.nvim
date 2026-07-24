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
      local function focus_diff_side(side)
        local ok, lib = pcall(require, "diffview.lib")
        local view = ok and lib.get_current_view()
        local win = view and view.cur_layout and view.cur_layout[side]

        if not win or not win.id or not vim.api.nvim_win_is_valid(win.id) then
          return
        end

        vim.api.nvim_set_current_win(win.id)
        -- Keep the other revision alive for an instant switch back, while
        -- giving the selected revision all of the available split space.
        vim.cmd("wincmd |")
        vim.cmd("wincmd _")
      end

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
          keymaps = {
            view = {
              { "n", "[o", function() focus_diff_side("a") end, { desc = "Show old revision" } },
              { "n", "]o", function() focus_diff_side("b") end, { desc = "Show new revision" } },
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
    opts = function(_, opts)
      opts = opts or {}
      opts.signs = {
        add = { text = "+" },
        change = { text = "~" },
        delete = { text = "_" },
        topdelete = { text = "‾" },
        changedelete = { text = "~" },
      }
      opts.signs_staged_enable = true
      opts.signcolumn = true -- Toggle with `:Gitsigns toggle_signs`
      opts.numhl = false -- Toggle with `:Gitsigns toggle_numhl`
      opts.linehl = false -- Toggle with `:Gitsigns toggle_linehl`
      opts.word_diff = false -- Toggle with `:Gitsigns toggle_word_diff`
      opts.watch_gitdir = {
        follow_files = true,
      }
      opts.auto_attach = true
      opts.attach_to_untracked = false
      opts.current_line_blame = true -- Toggle with `:Gitsigns toggle_current_line_blame`
      opts.current_line_blame_opts = {
        virt_text = true,
        virt_text_pos = "eol", -- 'eol' | 'overlay' | 'right_align'
        delay = 1000,
        ignore_whitespace = false,
        virt_text_priority = 100,
        use_focus = true,
      }
      opts.current_line_blame_formatter = "<author>, <author_time:%Y-%m-%d> - <summary> (<abbrev_sha>)"
      opts.sign_priority = 6
      opts.update_debounce = 100
      opts.status_formatter = nil -- Use default
      opts.max_file_length = 40000 -- Disable if file is longer than this (in lines)
      opts.preview_config = {
        -- Options passed to nvim_open_win
        border = "single",
        style = "minimal",
        relative = "cursor",
        row = 0,
        col = 1,
      }

      local old_on_attach = opts.on_attach
      opts.on_attach = function(buffer)
        if old_on_attach then
          old_on_attach(buffer)
        end

        local gs = package.loaded.gitsigns
        local function map(lhs, direction, desc)
          vim.keymap.set("n", lhs, function()
            if vim.wo.diff then
              vim.cmd.normal({ direction == "next" and "]c" or "[c", bang = true })
            else
              gs.nav_hunk(direction, { target = "all" })
            end
          end, { buffer = buffer, desc = desc, silent = true })
        end

        map("]h", "next", "Next Hunk")
        map("[h", "prev", "Prev Hunk")
        vim.keymap.set("n", "]H", function()
          gs.nav_hunk("last", { target = "all" })
        end, { buffer = buffer, desc = "Last Hunk", silent = true })
        vim.keymap.set("n", "[H", function()
          gs.nav_hunk("first", { target = "all" })
        end, { buffer = buffer, desc = "First Hunk", silent = true })
      end

      return opts
    end,
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
