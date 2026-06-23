-- Config-local "plugin": Bitbucket PR review inside Neovim, on top of `bkt`.
-- Implementation in lua/bkt_review/init.lua. Phase 1: read-only review.
require("bkt_review").setup({
  -- prefix = "<leader>c",
  -- bkt = "bkt",
})

return {}
