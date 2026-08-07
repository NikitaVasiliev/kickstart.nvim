-- Picker test: one stack per page, j/k walks the frames, ] / [ switch stacks.
-- Needs the real config (telescope), unlike tests/run.lua which uses -u NONE:
--
--   FIX=$PWD/lua/callstack/tests/fixture nvim --headless \
--     -c "luafile lua/callstack/tests/picker.lua"
--
-- Paging is driven through state.go rather than nvim_feedkeys, because
-- telescope's prompt does not respond to synthetic input under --headless.
-- The mappings are asserted separately, so both halves are covered.

local cs = require("callstack"); local I = cs._internal
local F = vim.env.FIX .. "/lib.c"
local function fr(name, line, ind)
  return { name=name, uri=vim.uri_from_fname(F), file="lib.c", lnum=line, col=1,
           call_lnum=line, call_col=1, indirect=ind or false, kids={} }
end
-- Distinct outermost frames, so the two pages are distinguishable.
local p1 = { frames = { fr("leaf",18), fr("mid_a",23), fr("top_1",33) } }
local p2 = { frames = { fr("leaf",18), fr("recur",48, true), fr("uses_recur",53) }, indirect = true }
local state = { paths={p1,p2}, root_name="leaf", depth=3, index=1,
                win=vim.api.nvim_get_current_win() }
local fails = 0
local function ck(n,c,d) io.write((c and "  ok   " or "  FAIL ")..n.."\n"); if not c then fails=fails+1; if d then io.write("       "..tostring(d).."\n") end end end
local function prompt_buf()
  for _,b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].filetype == "TelescopePrompt" then return b end end
end
vim.defer_fn(function()
  local st = require("telescope.actions.state")
  local pb = prompt_buf()
  if not pb then io.write("NO PICKER OPENED\n"); vim.cmd("cq") end
  local pk = st.get_current_picker(pb)
  -- finder.results is what the picker was handed, independent of async sorting.
  -- new_table stores entries, not the raw rows, so unwrap .value when present.
  local function fv(t, i) local e = t[i]; if e == nil then return nil end; return e.value or e end
  local r = pk.finder.results
  ck("page shows all 3 frames of stack 1", #r == 3, #r)
  ck("frame #0 is the innermost symbol", fv(r,1) and fv(r,1).name == "leaf", fv(r,1) and fv(r,1).name)
  ck("frame #2 is the outermost of stack 1", fv(r,3) and fv(r,3).name == "top_1", fv(r,3) and fv(r,3).name)
  ck("prompt title names the stack index", (pk.prompt_title or ""):find("stack 1/2", 1, true) ~= nil, pk.prompt_title)
  ck("title carries the path label", (pk.prompt_title or ""):find("leaf <- mid_a", 1, true) ~= nil, pk.prompt_title)

  -- The mapping must exist in both modes; telescope dispatches it the same way
  -- bkt_review's pager does.
  local function mapped(lhs, mode)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(pb, mode)) do
      if m.lhs == lhs then return true end
    end
    return false
  end
  ck("] mapped in insert mode", mapped("]", "i"))
  ck("] mapped in normal mode", mapped("]", "n"))
  ck("[ mapped in both", mapped("[", "i") and mapped("[", "n"))
  ck("<CR> mapped (path -> loclist)", mapped("<CR>", "i") or mapped("<CR>", "n"))
  ck("+ mapped (deepen)", mapped("+", "i") or mapped("+", "n"))

  state.go(state.index + 1)   -- same function ] is bound to
  vim.defer_fn(function()
    local pk2 = st.get_current_picker(prompt_buf())
    local function fv2(t,i) local e=t[i]; if e==nil then return nil end; return e.value or e end
    local r2 = pk2.finder.results
    ck("] switched to stack 2", fv2(r2,3) and fv2(r2,3).name == "uses_recur", fv2(r2,3) and fv2(r2,3).name)
    ck("stack 2 still shows 3 frames", #r2 == 3, #r2)
    ck("indirect frame kept its flag", fv2(r2,2) and fv2(r2,2).indirect == true, vim.inspect(fv2(r2,2) and fv2(r2,2).indirect))
    state.go(state.index - 1)
    vim.defer_fn(function()
      local r3 = st.get_current_picker(prompt_buf()).finder.results
      local function fv3(t,i) local e=t[i]; if e==nil then return nil end; return e.value or e end
      ck("[ went back to stack 1", fv3(r3,3) and fv3(r3,3).name == "top_1", fv3(r3,3) and fv3(r3,3).name)
      io.write(fails == 0 and "\nPICKER OK\n" or ("\n"..fails.." picker failures\n"))
      if fails > 0 then vim.cmd("cq") end
      vim.cmd("qa!")
    end, 500)
  end, 700)
end, 1500)
I.show(state)
vim.defer_fn(function() io.write("TIMEOUT\n"); vim.cmd("cq") end, 25000)
