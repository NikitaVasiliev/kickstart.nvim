-- Config-local "plugin": enumerate every call path *up* from a symbol, via LSP
-- callHierarchy/incomingCalls.  Implementation in lua/callstack/init.lua.
--
-- <leader>kk  callers of the symbol under the cursor (prompts for depth)
-- <leader>kK  same, reusing the last depth
--
-- One stack per page.  The rows are that stack's frames, numbered gdb-style
-- with #0 innermost, so j/k walks the stack and the preview follows:
--
--   stack 2/5 — depth 4 — leaf <- mid_b <- top_2 <- main
--     #0  leaf         lib.c:18
--     #1  mid_b        lib.c:28   calls leaf
--     #2  top_2        lib.c:38   calls mid_b
--     #3  main         lib.c:60   calls top_2
--
-- ] / [   next / previous stack
-- <CR>    whole stack -> loclist, landing on the frame you had selected;
--         the picker stays open so stacks can be compared
-- +       deepen from this stack's outermost frame
-- -       back to the previous result set
--
-- "<~" instead of "<-" means that frame only stores the callee's address, so
-- execution reaches it through a function pointer and the trail ends there.
require("callstack").setup({
  -- prefix = "<leader>k",
  -- default_depth = 3,
  -- max_nodes = 400,
  -- max_paths = 200,
  -- page_size = 20,
})

return {}
