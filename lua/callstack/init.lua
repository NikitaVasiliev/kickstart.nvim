-- callstack.nvim -- enumerate every call path *up* from a symbol.
--
-- `gr` answers "who mentions this", one level up.  When you are learning an
-- unfamiliar codebase the useful question is several levels up: how does
-- execution actually arrive here?  This asks for a depth, walks the caller
-- graph upward via callHierarchy/incomingCalls, and presents each distinct
-- path as a selectable alternative.
--
-- Selecting one populates the location list, one entry per frame, so ]l walks
-- up the stack.  Frames point at the *call site* (from `fromRanges`) rather
-- than the callee's body, which makes the list read like a real backtrace.
--
-- Static counterpart to `clearn tree`, which shows the paths a particular run
-- actually took; this also covers the ones it did not.

local M = {}

local config = {
  prefix = "<leader>k",
  default_depth = 3,
  -- ponytail: fixed caps, not a time budget.  One symbol with a handful of
  -- callers explodes fast -- depth 3 on a diamond already repeats the entry
  -- point once per path -- and `+` (deepen from a selection) is the intended
  -- way to go further, rather than raising these.
  max_nodes = 400,
  max_paths = 200,
  page_size = 20,
}

local loclist_context = require("loclist_context")

local function notify(msg, level)
  vim.notify("[callstack] " .. msg, level or vim.log.levels.INFO)
end

local function short(uri)
  return vim.fn.fnamemodify(vim.uri_to_fname(uri), ":t")
end

-- Identity for cycle detection.  Name plus file, not the range: a recursive
-- function calls itself from a different line each time, and keying on the
-- range would never break the loop.
local function key(item)
  return item.uri .. "::" .. item.name
end

--------------------------------------------------------------------------------
-- collect
--------------------------------------------------------------------------------

local function client_for(bufnr)
  local clients = vim.lsp.get_clients({
    bufnr = bufnr,
    method = "callHierarchy/incomingCalls",
  })
  return clients[1]
end

-- Source lines, cached, for the address-taken check below.
local line_cache = {}
local function line_at(uri, lnum)
  local path = vim.uri_to_fname(uri)
  local lines = line_cache[path]
  if not lines then
    lines = (vim.fn.filereadable(path) == 1) and vim.fn.readfile(path) or {}
    line_cache[path] = lines
  end
  return lines[lnum]
end

-- clangd reports an *address-taken* site as an incoming call.  Storing a
-- function in an ops struct therefore looks identical to calling it, and a path
-- stops at the assignment while appearing to have found an entry point.  ostor
-- does this constantly:
--
--     static struct pcs_stor_blk *blk_allocator_get(...)   blk_allocator.c:312
--     a->blk_mgr.get = blk_allocator_get;                  blk_allocator.c:391
--     b = blk_mgr->get(blk_mgr, c, id, sz, mode);          clnt_ctx.c:171
--
-- The reference range itself distinguishes them: a call is followed by "(",
-- an address-taken is not.  Purely textual, so it costs no extra request.
-- ponytail: does not follow the pointer through the struct field -- it only
-- says the trail goes cold here, which beats implying an entry point.
local function address_taken(uri, from_range)
  if not from_range then
    return false
  end
  local line = line_at(uri, from_range["end"].line + 1)
  if not line then
    return false
  end
  local rest = line:sub(from_range["end"].character + 1)
  return rest:match("^%s*%(") == nil
end

local function make_node(item, from_range)
  local uri = item.uri
  return {
    item = item,
    name = item.name,
    uri = uri,
    file = short(uri),
    -- Where this function is defined.
    lnum = (item.selectionRange or item.range).start.line + 1,
    col = (item.selectionRange or item.range).start.character + 1,
    -- Where, inside this function, it references the frame below it.  nil for
    -- the root, which is the symbol you started on.
    call_lnum = from_range and (from_range.start.line + 1) or nil,
    call_col = from_range and (from_range.start.character + 1) or nil,
    -- True when that reference stores the address rather than calling it.
    indirect = address_taken(uri, from_range),
    kids = {},
  }
end

-- Recursive fan-out.  Every node owns its own `kids` and is linked to its
-- parent at creation: an earlier version appended to a shared accumulator as
-- replies arrived and silently mis-nested the tree, putting a caller of one
-- branch underneath its sibling.  Nesting must not depend on reply order.
local function expand(client, node, depth, seen, budget, done)
  if depth <= 0 or budget.nodes >= config.max_nodes then
    node.exhausted = depth > 0 -- stopped by the cap, not by the depth limit
    return done()
  end

  client:request("callHierarchy/incomingCalls", { item = node.item }, function(err, res)
    if err or not res or #res == 0 then
      return done()
    end

    -- Start at 1 for the dispatch loop itself, released by the tick() after it.
    -- Without that token a child whose own expand() completes synchronously --
    -- which every child does at the last depth level -- drops pending to 0
    -- mid-loop and fires done() before the remaining siblings are even added.
    local pending, fired = 1, false
    local function tick()
      pending = pending - 1
      if pending <= 0 and not fired then
        fired = true
        done()
      end
    end

    for _, call in ipairs(res) do
      if budget.nodes >= config.max_nodes then
        node.exhausted = true
        break
      end
      local k = key(call.from)
      if seen[k] then
        -- Recursion, or a diamond rejoining itself.  Stop this path; siblings
        -- are unaffected because `seen` is copied per branch below.
        node.cycle = true
      else
        local kid = make_node(call.from, (call.fromRanges or {})[1])
        budget.nodes = budget.nodes + 1
        table.insert(node.kids, kid)
        pending = pending + 1
        local next_seen = vim.tbl_extend("force", {}, seen)
        next_seen[k] = true
        expand(client, kid, depth - 1, next_seen, budget, tick)
      end
    end

    tick() -- release the dispatch loop's token
  end)
end

-- Depth-first walk emitting one path per leaf, innermost frame first.
local function enumerate(node, prefix, out, truncated)
  local chain = vim.list_extend(vim.deepcopy(prefix), { node })
  if #node.kids == 0 then
    if #out >= config.max_paths then
      truncated.hit = true
      return
    end
    local indirect = false
    for _, f in ipairs(chain) do
      if f.indirect then
        indirect = true
        break
      end
    end
    table.insert(out, {
      frames = chain,
      cycle = node.cycle or false,
      exhausted = node.exhausted or false,
      indirect = indirect,
    })
    return
  end
  for _, kid in ipairs(node.kids) do
    enumerate(kid, chain, out, truncated)
  end
end

-- "<-" is a real call, "<~" means the frame to the right only stores the
-- address of the one to its left, so execution reaches it through a function
-- pointer and the trail goes cold there.
local function path_label(path)
  local s = path.frames[1].name
  for i = 2, #path.frames do
    local f = path.frames[i]
    s = s .. (f.indirect and " <~ " or " <- ") .. f.name
  end
  local tags = {}
  if path.indirect then
    table.insert(tags, "indirect: address taken, real callers dispatch via pointer")
  end
  if path.cycle then
    table.insert(tags, "cycle")
  elseif path.exhausted then
    table.insert(tags, "depth limit")
  end
  if #tags > 0 then
    s = s .. "  (" .. table.concat(tags, "; ") .. ")"
  end
  return s
end

-- root -> list of paths, deduped by the name chain.
local function collect(client, root_item, depth, cb)
  local root = make_node(root_item, nil)
  local budget = { nodes = 0 }
  expand(client, root, depth, { [key(root_item)] = true }, budget, function()
    local paths, truncated = {}, { hit = false }
    enumerate(root, {}, paths, truncated)

    local seen_label, unique = {}, {}
    for _, p in ipairs(paths) do
      local lbl = path_label(p)
      if not seen_label[lbl] then
        seen_label[lbl] = true
        table.insert(unique, p)
      end
    end
    -- Longest first: a path that reached an entry point tells you more than
    -- one that merely ran out of depth.
    table.sort(unique, function(a, b)
      if #a.frames ~= #b.frames then
        return #a.frames > #b.frames
      end
      return path_label(a) < path_label(b)
    end)
    cb(unique, {
      nodes = budget.nodes,
      truncated = truncated.hit or budget.nodes >= config.max_nodes,
    })
  end)
end

--------------------------------------------------------------------------------
-- location list
--------------------------------------------------------------------------------

-- One entry per frame, outermost last, so ]l walks up the stack.  Non-root
-- frames point at their call site, which is what makes this read like a
-- backtrace rather than a list of function definitions.
local function path_to_loclist(path, win)
  local items = {}
  for i, f in ipairs(path.frames) do
    local lnum = f.call_lnum or f.lnum
    local col = f.call_col or f.col
    local below = path.frames[i - 1]
    local text = f.name .. "()"
    if below then
      text = (f.indirect and "takes address of " or "calls ") .. below.name
    end
    table.insert(
      items,
      loclist_context.extend_item({
        filename = vim.uri_to_fname(f.uri),
        lnum = lnum,
        col = col,
        text = text,
      })
    )
  end

  local names = {}
  for _, f in ipairs(path.frames) do
    table.insert(names, f.name)
  end
  vim.fn.setloclist(win or 0, {}, "r", {
    items = items,
    quickfixtextfunc = loclist_context.quickfixtextfunc,
    title = ("callstack: %s (%d)"):format(table.concat(names, " <- "), #items),
  })
end

--------------------------------------------------------------------------------
-- picker
--------------------------------------------------------------------------------

-- Frames of one path as picker rows: gdb-style index (#0 innermost) plus the
-- name of the frame below, so a row can say "calls X" on its own.
local function frames_of(path)
  local out = {}
  for i, f in ipairs(path.frames) do
    table.insert(
      out,
      vim.tbl_extend("keep", {
        idx = i - 1,
        below = i > 1 and path.frames[i - 1].name or nil,
      }, f)
    )
  end
  return out
end

local function fallback_select(paths, on_pick)
  vim.ui.select(paths, {
    prompt = "Call paths",
    format_item = path_label,
  }, function(choice)
    if choice then
      on_pick(choice)
    end
  end)
end

-- One stack per page.  The rows are the *frames* of a single call path, so j/k
-- walks the stack and the preview follows; ] / [ switch to the next stack, the
-- way <leader>p] steps comments.  Frames are numbered gdb-style, #0 innermost,
-- which makes the direction unambiguous and matches the loclist order.
local function show(state)
  local ok = pcall(require, "telescope")
  if not ok then
    return fallback_select(state.paths, function(p)
      path_to_loclist(p, state.win)
      vim.cmd("lopen")
    end)
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")
  local telescope_loclist = require("telescope_loclist")

  state.index = math.min(math.max(state.index or 1, 1), #state.paths)

  local picker

  local function current()
    return state.paths[state.index]
  end

  local displayer = entry_display.create({
    separator = "  ",
    items = {
      { width = 4 },  -- #n
      { width = 28 }, -- symbol
      { width = 22 }, -- file:line
      { remaining = true },
    },
  })

  local function entry_maker(frame)
    local lnum = frame.call_lnum or frame.lnum
    local rel = ("%s:%d"):format(frame.file, lnum)
    local note = ""
    if frame.below then
      note = (frame.indirect and "takes address of " or "calls ") .. frame.below
    end
    return {
      value = frame,
      filename = vim.uri_to_fname(frame.uri),
      lnum = lnum,
      col = frame.call_col or frame.col,
      ordinal = frame.name .. " " .. rel,
      display = function()
        return displayer({
          { "#" .. tostring(frame.idx), "TelescopeResultsNumber" },
          { frame.name, frame.indirect and "DiagnosticWarn" or "TelescopeResultsIdentifier" },
          { rel, "TelescopeResultsComment" },
          { note, frame.indirect and "DiagnosticWarn" or "TelescopeResultsComment" },
        })
      end,
    }
  end

  local function rows()
    return frames_of(current())
  end

  local function title()
    local p = current()
    local t = ("stack %d/%d — depth %d — %s"):format(state.index, #state.paths, state.depth, path_label(p))
    if state.truncated then
      t = t .. " · TRUNCATED"
    end
    return t
  end

  -- picker.layout is only populated once the picker is drawn, and older
  -- telescope exposes prompt_border instead; try both and shrug if neither.
  local function set_title(t)
    if pcall(function()
      picker.layout.prompt.border:change_title(t)
    end) then
      return
    end
    pcall(function()
      picker.prompt_border:change_title(t)
    end)
  end

  local function go(i)
    if i < 1 or i > #state.paths then
      return
    end
    state.index = i
    picker:refresh(finders.new_table({ results = rows(), entry_maker = entry_maker }), { reset_prompt = true })
    set_title(title())
  end
  -- Exposed on the state so the test can exercise paging directly: telescope's
  -- prompt does not respond to nvim_feedkeys under --headless.
  state.go = go

  picker = pickers.new({}, {
    prompt_title = title(),
    finder = finders.new_table({ results = rows(), entry_maker = entry_maker }),
    sorter = conf.generic_sorter({}),
    previewer = conf.qflist_previewer({}),
    attach_mappings = function(bufnr, map)
      -- ] / [ page between stacks; j/k is left alone so it does what it always
      -- does inside a picker, which is walk the rows -- here, the frames.
      map({ "i", "n" }, "]", function()
        go(state.index + 1)
      end)
      map({ "i", "n" }, "[", function()
        go(state.index - 1)
      end)

      -- Whole stack -> loclist, positioned on the frame that was selected, and
      -- the picker stays open so other stacks can be compared.
      local function send()
        local p = current()
        local entry = action_state.get_selected_entry()
        path_to_loclist(p, state.win)
        if entry and entry.value and entry.value.idx then
          pcall(vim.cmd, "ll " .. tostring(entry.value.idx + 1))
        end
        notify(("loclist: %s"):format(path_label(p)))
      end
      map({ "i", "n" }, "<CR>", send)

      -- Deepen from this stack's outermost frame.
      map({ "i", "n" }, "+", function()
        local p = current()
        actions.close(bufnr)
        M.deepen(p, state)
      end)

      map({ "i", "n" }, "-", function()
        if not state.parent then
          return notify("already at the first result set")
        end
        actions.close(bufnr)
        show(state.parent)
      end)

      telescope_loclist.attach_mappings(bufnr, map)
      return true
    end,
  })
  picker:find()
  set_title(title())
end

--------------------------------------------------------------------------------
-- entry points
--------------------------------------------------------------------------------

local last_depth = nil

-- Expand further from the outermost frame of an already-found path, keeping
-- the frames below it as a prefix so the result is still a full path from the
-- original symbol.
function M.deepen(path, state)
  local tip = path.frames[#path.frames]
  local client = state.client
  if not client then
    return notify("LSP client is gone", vim.log.levels.WARN)
  end

  local prefix = {}
  for i = 1, #path.frames - 1 do
    table.insert(prefix, path.frames[i])
  end

  local seen = {}
  for _, f in ipairs(path.frames) do
    seen[f.uri .. "::" .. f.name] = true
  end

  local node = make_node(tip.item, tip.call_lnum and {
    start = { line = tip.call_lnum - 1, character = (tip.call_col or 1) - 1 },
  } or nil)
  local budget = { nodes = 0 }
  notify(("deepening from %s (+%d)"):format(tip.name, state.depth))
  expand(client, node, state.depth, seen, budget, function()
    local paths, truncated = {}, { hit = false }
    enumerate(node, prefix, paths, truncated)
    if #paths <= 1 and #node.kids == 0 then
      return notify(("no further callers of %s"):format(tip.name))
    end
    table.sort(paths, function(a, b)
      return #a.frames > #b.frames
    end)
    vim.schedule(function()
      show({
        paths = paths,
        root_name = state.root_name,
        depth = state.depth,
        client = client,
        win = state.win,
        truncated = truncated.hit or budget.nodes >= config.max_nodes,
        page = 1,
        parent = state, -- `-` returns here
      })
    end)
  end)
end

function M.callers(depth)
  local bufnr = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local client = client_for(bufnr)
  if not client then
    return notify("no LSP client here supports call hierarchy", vim.log.levels.WARN)
  end

  local params = vim.lsp.util.make_position_params(win, client.offset_encoding)
  client:request("textDocument/prepareCallHierarchy", params, function(err, res)
    if err then
      return notify("prepareCallHierarchy: " .. tostring(err.message or err), vim.log.levels.ERROR)
    end
    if not res or #res == 0 then
      return notify("no symbol under the cursor", vim.log.levels.WARN)
    end
    local root = res[1]
    notify(("walking callers of %s, depth %d…"):format(root.name, depth))
    collect(client, root, depth, function(paths, meta)
      if #paths == 0 then
        return vim.schedule(function()
          notify(("%s has no callers"):format(root.name))
        end)
      end
      vim.schedule(function()
        if meta.truncated then
          notify(("hit the %d-node cap — results are partial"):format(config.max_nodes), vim.log.levels.WARN)
        end
        show({
          paths = paths,
          root_name = root.name,
          depth = depth,
          client = client,
          win = win,
          truncated = meta.truncated,
          page = 1,
        })
      end)
    end)
  end, bufnr)
end

function M.prompt()
  vim.ui.input({
    prompt = "Depth up: ",
    default = tostring(last_depth or config.default_depth),
  }, function(input)
    if not input or input == "" then
      return
    end
    local n = tonumber(input)
    if not n or n < 1 then
      return notify("depth must be a positive number", vim.log.levels.WARN)
    end
    last_depth = math.floor(n)
    M.callers(last_depth)
  end)
end

function M.repeat_last()
  M.callers(last_depth or config.default_depth)
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})

  vim.api.nvim_create_user_command("Callstack", function(o)
    local n = tonumber(o.args)
    if n then
      last_depth = math.floor(n)
      M.callers(last_depth)
    else
      M.prompt()
    end
  end, { nargs = "?", desc = "callers of the symbol under the cursor" })

  local p = config.prefix
  local function map(lhs, fn, desc)
    vim.keymap.set("n", p .. lhs, fn, { desc = "Callstack: " .. desc })
  end
  map("k", M.prompt, "callers of symbol (ask depth)")
  map("K", M.repeat_last, "callers of symbol (last depth)")

  local okwk, wk = pcall(require, "which-key")
  if okwk and wk.add then
    pcall(wk.add, { { p, group = "Callstack" } })
  end
end

-- Exposed for the headless test, which drives the collection directly rather
-- than through Telescope.
M._internal = {
  collect = collect,
  path_label = path_label,
  path_to_loclist = path_to_loclist,
  client_for = client_for,
  frames_of = frames_of,
  show = show,
  config = function()
    return config
  end,
  set_config = function(o)
    config = vim.tbl_deep_extend("force", config, o or {})
  end,
}

return M
