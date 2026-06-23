return {
  {
    "nvim-telescope/telescope.nvim",
    event = "VeryLazy",
    version = false,
    dependencies = {
      "nvim-lua/plenary.nvim",
      {
        "nvim-telescope/telescope-fzf-native.nvim",
        build = "make",
        cond = function()
          return vim.fn.executable("make") == 1
        end,
      },
      "nvim-telescope/telescope-ui-select.nvim",
    },
    opts = function(_, opts)
      local actions = require("telescope.actions")
      local action_state = require("telescope.actions.state")
      local loclist = require("telescope_loclist")

      local function for_each_file(prompt_bufnr)
        local picker = action_state.get_current_picker(prompt_bufnr)
        local selections = picker:get_multi_selection()
        actions.close(prompt_bufnr)

        for _, entry in ipairs(selections) do
          local filepath = entry.path or entry.filename
          if filepath then
            vim.cmd("edit " .. vim.fn.fnameescape(filepath))
          end
        end
      end

      local function grep_in_selected(prompt_bufnr)
        local picker = action_state.get_current_picker(prompt_bufnr)
        local selections = picker:get_multi_selection()
        actions.close(prompt_bufnr)

        local paths = {}
        for _, entry in ipairs(selections) do
          table.insert(paths, entry.path or entry.filename)
        end

        if #paths > 0 then
          require("telescope.builtin").live_grep({ search_dirs = paths })
        end
      end

      opts = opts or {}
      opts.extensions = vim.tbl_deep_extend("force", opts.extensions or {}, {
        ["ui-select"] = require("telescope.themes").get_dropdown(),
      })
      opts.defaults = opts.defaults or {}
      opts.defaults.dynamic_preview_title = true
      opts.defaults.mappings = opts.defaults.mappings or {}
      opts.defaults.mappings.i = opts.defaults.mappings.i or {}
      opts.defaults.mappings.n = opts.defaults.mappings.n or {}

      opts.defaults.layout_strategy = "flex"
      opts.defaults.layout_config = vim.tbl_deep_extend("force", opts.defaults.layout_config or {}, {
        flex = {
          flip_columns = 140,
        },
        horizontal = {
          width = 0.95,
          height = 0.9,
          preview_width = 0.55,
        },
        vertical = {
          width = 0.95,
          height = 0.95,
          preview_height = 0.6,
        },
      })
      opts.defaults.mappings.i["<C-d>"] = actions.delete_buffer
      opts.defaults.mappings.i["<C-e>"] = for_each_file
      opts.defaults.mappings.i["<C-g>"] = grep_in_selected
      opts.defaults.mappings.i["<C-l>"] = loclist.send_current
      opts.defaults.mappings.i["<C-q>"] = loclist.send_current
      opts.defaults.mappings.i["<M-l>"] = loclist.send_all
      opts.defaults.mappings.i["<A-l>"] = loclist.send_all
      opts.defaults.mappings.i["<Esc>l"] = loclist.send_all

      opts.defaults.mappings.n["q"] = actions.close
      opts.defaults.mappings.n["dd"] = actions.delete_buffer
      opts.defaults.mappings.n["<C-l>"] = loclist.send_current
      opts.defaults.mappings.n["<C-q>"] = loclist.send_current
      opts.defaults.mappings.n["<M-l>"] = loclist.send_all
      opts.defaults.mappings.n["<A-l>"] = loclist.send_all
      opts.defaults.mappings.n["<Esc>l"] = loclist.send_all

      opts.pickers = opts.pickers or {}
      opts.pickers.buffers = opts.pickers.buffers or {}
      opts.pickers.buffers.sort_mru = true
      opts.pickers.buffers.ignore_current_buffer = true

      return opts
    end,
    config = function(_, opts)
      local telescope = require("telescope")
      local loclist = require("telescope_loclist")
      telescope.setup(opts)
      telescope.setup({
        defaults = {
          mappings = {
            i = {
              ["<C-l>"] = loclist.send_current,
              ["<M-l>"] = loclist.send_all,
            },
            n = {
              ["<C-l>"] = loclist.send_current,
              ["<M-l>"] = loclist.send_all,
            },
          },
        },
      })
      pcall(telescope.load_extension, "fzf")
      pcall(telescope.load_extension, "ui-select")
      pcall(telescope.load_extension, "tab_switch")
    end,
  },
  {
    "nvim-mini/mini.nvim",
    event = "VeryLazy",
    config = function()
      require("mini.files").setup()
      require("mini.jump").setup()

      local function create_tmux_session()
        local entry = require("mini.files").get_fs_entry()
        if not entry or not entry.path then
          return
        end

        local dir_path = vim.fn.fnamemodify(entry.path, ":p:h")
        local dir_name = vim.fn.fnamemodify(dir_path, ":t")
        local cmd =
          string.format("tmux new-session -d -s %s -c %s", vim.fn.shellescape(dir_name), vim.fn.shellescape(dir_path))
        vim.fn.system(cmd)
        vim.notify("Tmux session '" .. dir_name .. "' created in " .. dir_path, vim.log.levels.INFO)
      end

      vim.api.nvim_create_autocmd("User", {
        pattern = "MiniFilesBufferCreate",
        callback = function(args)
          vim.keymap.set("n", "<leader>n", create_tmux_session, {
            buffer = args.data.buf_id,
            desc = "Create tmux session",
          })
        end,
      })
    end,
  },
}
