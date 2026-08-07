-- Headless test for lua/callstack.  Drives collection directly, not Telescope.
--
--   nvim --headless -u NONE -c "luafile lua/callstack/tests/run.lua"
--
-- Needs clangd on PATH.  Generates the fixture's compile_commands.json itself.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
local fixture = here .. "/fixture"
local root = vim.fn.fnamemodify(here, ":h:h:h") -- .../nvim/lua -> config root
vim.opt.runtimepath:prepend(root)

if vim.fn.executable("clangd") == 0 then
  io.write("clangd not on PATH\n")
  vim.cmd("cq")
end

-- clangd needs a compilation database or it answers with almost nothing.
local cc = ('[{"directory":%q,"command":"clang -c lib.c","file":%q}]'):format(fixture, fixture .. "/lib.c")
local f = assert(io.open(fixture .. "/compile_commands.json", "w"))
f:write(cc)
f:close()

local pass, fail = {}, {}
local function check(name, cond, detail)
  table.insert(cond and pass or fail, name)
  io.write(("  %s %s\n"):format(cond and "ok  " or "FAIL", name))
  if not cond and detail ~= nil then
    io.write("       " .. tostring(detail) .. "\n")
  end
end

local cs = require("callstack")
local I = cs._internal

vim.cmd("edit " .. fixture .. "/lib.c")
vim.lsp.start({
  name = "clangd",
  cmd = { "clangd", "--background-index=false" },
  root_dir = fixture,
})

-- Line and 0-based column of a function's *definition* in the fixture, so the
-- cursor can be put on its name.  Definitions start at column 0; every call
-- site and assignment in the fixture is indented, which is what excludes them.
local function line_of(name)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if not l:match("^%s") then
      local at = l:find(name .. "(", 1, true)
      if at then
        return i, at - 1
      end
    end
  end
  error("no such function definition in fixture: " .. name)
end

local function labels(paths)
  local out = {}
  for _, p in ipairs(paths) do
    table.insert(out, I.path_label(p))
  end
  table.sort(out)
  return out
end

-- Resolve the symbol under the cursor, then collect, then hand both to cb.
local function at(name, depth, cb)
  local client = I.client_for(0)
  local ln, col = line_of(name)
  vim.api.nvim_win_set_cursor(0, { ln, col })
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  client:request("textDocument/prepareCallHierarchy", params, function(err, res)
    if err or not res or #res == 0 then
      check("prepareCallHierarchy for " .. name, false, vim.inspect(err))
      return cb(nil)
    end
    I.collect(client, res[1], depth, function(paths, meta)
      cb(paths, meta, res[1])
    end)
  end)
end

-- The tests are async and order matters (config is mutated by the cap test),
-- so they run as an explicit chain rather than in parallel.
local steps = {}

table.insert(steps, function(next_step)
  at("leaf", 4, function(paths)
    if not paths then
      return next_step()
    end
    local got = labels(paths)
    local want = {
      "leaf <- mid_a <- top_1 <- main",
      "leaf <- mid_a <- top_2 <- main",
      "leaf <- mid_b <- top_2 <- main",
      "leaf <- mid_b <- top_3 <- main",
      "leaf <- recur <- uses_recur <- main",
    }
    check("depth 4 from leaf yields the 5 expected paths", vim.deep_equal(got, want), vim.inspect(got))

    -- The regression that a shared accumulator caused: top_1 only ever calls
    -- mid_a, so it must never appear behind mid_b.
    -- Plain find, not a pattern: "-" is a quantifier in Lua patterns, so
    -- l:match("mid_b <- top_1") silently never matches and the check passes
    -- for the wrong reason.
    local mis = false
    for _, l in ipairs(got) do
      if l:find("mid_b <- top_1", 1, true) or l:find("mid_a <- top_3", 1, true) then
        mis = true
      end
    end
    check("nesting is correct (no caller under the wrong branch)", not mis, vim.inspect(got))

    -- A frame list must be innermost-first so the loclist reads bottom-up.
    local first = paths[1].frames
    check("frames are innermost first", first[1].name == "leaf", first[1].name)
    next_step()
  end)
end)

table.insert(steps, function(next_step)
  at("recur", 4, function(paths)
    if not paths then
      return next_step()
    end
    local got = labels(paths)
    -- If cycle breaking were broken this would never return at all, so simply
    -- arriving here is most of the assertion.
    check("recursion terminates", #got > 0, vim.inspect(got))
    local ok, self_edge = false, false
    for _, l in ipairs(got) do
      if l:find("recur <- uses_recur", 1, true) then
        ok = true
      end
      if l:find("recur <- recur", 1, true) then
        self_edge = true
      end
    end
    check("recursive self-edge is dropped", ok and not self_edge, vim.inspect(got))
    next_step()
  end)
end)

table.insert(steps, function(next_step)
  at("leaf", 1, function(paths)
    if not paths then
      return next_step()
    end
    local got = labels(paths)
    check(
      "depth 1 yields only the direct callers",
      vim.deep_equal(got, { "leaf <- mid_a", "leaf <- mid_b", "leaf <- recur" }),
      vim.inspect(got)
    )
    next_step()
  end)
end)

table.insert(steps, function(next_step)
  at("orphan", 3, function(paths)
    if not paths then
      return next_step()
    end
    -- The root itself is a leaf of the tree, so an uncalled function yields
    -- exactly one one-frame path.
    check("an uncalled function yields a single bare path", #paths == 1 and #paths[1].frames == 1, vim.inspect(labels(paths)))
    next_step()
  end)
end)

table.insert(steps, function(next_step)
  at("leaf", 4, function(paths)
    if not paths then
      return next_step()
    end
    local p = paths[1]
    I.path_to_loclist(p, 0)
    local ll = vim.fn.getloclist(0, { all = 1 })
    check("selecting a path fills the loclist with one entry per frame", #ll.items == #p.frames, ("%d vs %d"):format(#ll.items, #p.frames))
    check("loclist is titled for named_loclist", (ll.title or ""):match("^callstack: ") ~= nil, ll.title)

    local last = ll.items[#ll.items]
    check("outermost frame is last, so ]l walks up", last.text:match("^calls ") ~= nil or #p.frames == 1, last.text)

    local enriched = 0
    for _, it in ipairs(ll.items) do
      if type(it.user_data) == "table" and it.user_data.loclist_context_name then
        enriched = enriched + 1
      end
    end
    check("loclist_context enriched the entries", enriched > 0, ("%d of %d"):format(enriched, #ll.items))

    -- Non-root frames point at the call site, not the callee's definition.
    local second = p.frames[2]
    check("non-root frames carry a call site", second == nil or second.call_lnum ~= nil, vim.inspect(second and second.name))
    next_step()
  end)
end)

table.insert(steps, function(next_step)
  at("hidden", 2, function(paths)
    if not paths then
      return next_step()
    end
    local got = labels(paths)
    -- clangd reports the assignment `o->get = hidden` as an incoming call, so
    -- without the address-taken check this reads as a normal call chain and
    -- implies ops_init is where execution comes from.
    local flagged = false
    for _, l in ipairs(got) do
      if l:find("hidden <~ ops_init", 1, true) then
        flagged = true
      end
    end
    check("address-taken edge is marked <~, not <-", flagged, vim.inspect(got))
    local tagged = false
    for _, p in ipairs(paths) do
      if p.indirect then
        tagged = true
      end
    end
    check("path carries the indirect flag", tagged, vim.inspect(got))

    -- A genuine call must not be mistaken for an address-taken.
    for _, l in ipairs(got) do
      check("real calls keep <-", not l:find("hidden <~ ops_call", 1, true), l)
      break
    end
    next_step()
  end)
end)

table.insert(steps, function(next_step)
  at("mid_a", 2, function(paths)
    if not paths then
      return next_step()
    end
    local got = labels(paths)
    local any_indirect = false
    for _, p in ipairs(paths) do
      if p.indirect then
        any_indirect = true
      end
    end
    check("a purely direct chain is never flagged indirect", not any_indirect, vim.inspect(got))
    next_step()
  end)
end)

-- Runs last: it lowers max_paths for the rest of the process.
table.insert(steps, function(next_step)
  I.set_config({ max_paths = 2 })
  at("leaf", 4, function(paths, meta)
    if not paths then
      return next_step()
    end
    check("max_paths caps the result", #paths <= 2, #paths)
    check("truncation is reported, not silent", meta.truncated == true, vim.inspect(meta))
    next_step()
  end)
end)

local function drive(i)
  if i > #steps then
    io.write(("\n%d passed, %d failed\n"):format(#pass, #fail))
    if #fail > 0 then
      io.write("failed: " .. table.concat(fail, ", ") .. "\n")
      vim.cmd("cq")
    end
    return vim.cmd("qa!")
  end
  steps[i](function()
    vim.schedule(function()
      drive(i + 1)
    end)
  end)
end

-- Give clangd time to index the fixture before the first request.
vim.defer_fn(function()
  if not I.client_for(0) then
    io.write("clangd never attached\n")
    vim.cmd("cq")
  end
  drive(1)
end, 3000)

-- Hard stop, so a hang fails the run instead of blocking forever.
vim.defer_fn(function()
  io.write("\nTIMED OUT — " .. #pass .. " passed before the deadline\n")
  vim.cmd("cq")
end, 40000)
