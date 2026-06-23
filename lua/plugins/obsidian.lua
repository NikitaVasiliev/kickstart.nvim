-- obsidian.nvim — backs the <leader>o* keymaps in lua/config/keymaps.lua
-- (they drive the unified :Obsidian <subcommand> interface).
return {
  "obsidian-nvim/obsidian.nvim",
  version = "*",
  cmd = "Obsidian",
  ft = "markdown",
  dependencies = { "nvim-lua/plenary.nvim" },
  opts = {
    workspaces = {
      { name = "personal", path = "~/Documents/Obsidian Vault/personal/" },
    },
    -- render-markdown.nvim already handles markdown UI in this config
    ui = { enable = false },
  },
}
