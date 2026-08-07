-- Config-local "plugin": enumerate every call path *up* from a symbol, via LSP
-- callHierarchy/incomingCalls.  Implementation in lua/callstack/init.lua.
--
-- <leader>kk  callers of the symbol under the cursor (prompts for depth)
-- <leader>kK  same, reusing the last depth
--
-- In the picker: ] / [ page, <CR> path -> loclist (picker stays open),
-- <Tab> cycle previewed frame, + deepen from the selection, - go back.
require("callstack").setup({
  -- prefix = "<leader>k",
  -- default_depth = 3,
  -- max_nodes = 400,
  -- max_paths = 200,
  -- page_size = 20,
})

return {}
