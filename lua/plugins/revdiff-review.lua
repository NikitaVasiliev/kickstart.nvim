-- Config-local "plugin": loads the revdiff_review module and registers its
-- commands/keymaps. Returns an empty spec so lazy has nothing to manage.
--
-- Implementation lives in lua/revdiff_review/init.lua. It powers two flows:
--   1. interactive review of any buffer (<leader>r prefix, see the module)
--   2. the revdiff override launcher at
--      ${CLAUDE_PLUGIN_DATA}/scripts/launch-revdiff.sh, which opens changed
--      files here and reads annotations back via $REVDIFF_REVIEW_OUTPUT.
require("revdiff_review").setup({
  -- prefix = "<leader>r",
  -- history_dir = nil,  -- defaults to $REVDIFF_HISTORY_DIR or ~/.config/revdiff/history
})

return {}
