return {
  {
    "neovim/nvim-lspconfig",
    opts = function(_, opts)
      local telescope_loclist = require("telescope_loclist")
      local builtin = require("telescope.builtin")

      local function get_python_path()
        local cwd = vim.fn.getcwd()
        local venv_python = cwd .. "/.venv/bin/python"
        if vim.fn.executable(venv_python) == 1 then
          return venv_python
        end
        return vim.fn.exepath("python3")
      end

      opts.servers = opts.servers or {}
      opts.servers["*"] = opts.servers["*"] or {}
      opts.servers["*"].keys = opts.servers["*"].keys or {}
      vim.list_extend(opts.servers["*"].keys, {
        {
          "gd",
          function()
            builtin.lsp_definitions({ attach_mappings = telescope_loclist.attach_mappings })
          end,
          desc = "Goto Definition",
          has = "definition",
        },
        {
          "gr",
          function()
            builtin.lsp_references({ attach_mappings = telescope_loclist.attach_mappings })
          end,
          desc = "References",
          nowait = true,
        },
        {
          "gI",
          function()
            builtin.lsp_implementations({ attach_mappings = telescope_loclist.attach_mappings })
          end,
          desc = "Goto Implementation",
        },
        {
          "<leader>ds",
          function()
            builtin.lsp_document_symbols({ attach_mappings = telescope_loclist.attach_mappings })
          end,
          desc = "Document Symbols",
        },
        {
          "<leader>ws",
          function()
            builtin.lsp_dynamic_workspace_symbols({ attach_mappings = telescope_loclist.attach_mappings })
          end,
          desc = "Workspace Symbols",
        },
      })

      opts.servers.pyright = opts.servers.pyright or {}
      opts.servers.pyright.settings = opts.servers.pyright.settings or {}
      opts.servers.pyright.settings.python = vim.tbl_deep_extend(
        "force",
        opts.servers.pyright.settings.python or {},
        { pythonPath = get_python_path() }
      )
    end,
  },
}
