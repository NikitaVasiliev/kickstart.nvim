return {
  {
    "MeanderingProgrammer/render-markdown.nvim",
    ft = { "markdown" },
    dependencies = {
      "nvim-treesitter/nvim-treesitter",
      "nvim-mini/mini.nvim",
    },
    ---@module "render-markdown"
    ---@type render.md.UserConfig
    opts = {},
    config = function(_, opts)
      require("render-markdown").setup(opts)
      require("md_table_wrap").setup()
    end,
  },
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, {
        "markdown",
        "markdown_inline",
        "html",
        "yaml",
      })
    end,
  },
}
