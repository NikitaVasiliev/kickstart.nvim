-- bkt_review — review Bitbucket PRs inside Neovim: isolated worktree + Diffview
-- + comment threads overlaid on the diff.
--
--   :BktPr               pick a PR (bkt pr list) -> open review
--   :BktPrReview <id>    open review for a PR id
--   :BktReviewClean      prune the per-PR worktrees
--   :BktPrComments <id>  raw comments JSON (field-mapping debug)
--
-- Flow: create a git worktree under the cache dir, `bkt pr checkout <id>` inside
-- it (PR head as pr/<id>, main checkout untouched), open Diffview comparing the
-- destination branch to the PR head, and overlay existing comment threads.
--
-- Phase A (this file): worktree + diffview + READ-ONLY overlay (signs, virtual
-- text, <CR> thread float). Phase B (next): add comment / reply / resolve.

local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("bkt_review")

local config = {
  prefix = "<leader>p", -- PR review group
  bkt = "bkt",
  worktree_dir = vim.fn.stdpath("cache") .. "/bkt-review",
}

-- active review session: { id, src, dst, root, repo, ws, slug, wt, threads = {byid,roots}, by_path = {path -> {threads}} }
M.active = nil

local function notify(msg, level)
  vim.notify("[bkt-review] " .. msg, level or vim.log.levels.INFO)
end

-- ── value helpers (JSON null = vim.NIL, a truthy userdata) ──────────────────
local function val(v)
  if v == nil or v == vim.NIL then
    return nil
  end
  return v
end

local function first(...)
  local n = select("#", ...)
  for i = 1, n do
    local v = val((select(i, ...)))
    if v ~= nil then
      return v
    end
  end
end

-- safe nested table access: dig(t, "source", "branch", "name")
local function dig(t, ...)
  for _, k in ipairs({ ... }) do
    t = val(t)
    if type(t) ~= "table" then
      return nil
    end
    t = t[k]
  end
  return val(t)
end

local function as_list(v)
  if type(v) ~= "table" then
    return nil
  end
  if vim.islist(v) then
    return v
  end
  for _, key in ipairs({ "values", "pull_requests", "pullRequests", "prs", "results", "comments" }) do
    if type(v[key]) == "table" and vim.islist(v[key]) then
      return v[key]
    end
  end
  for _, x in pairs(v) do
    if type(x) == "table" and vim.islist(x) then
      return x
    end
  end
  return nil
end

-- ── async command runners ───────────────────────────────────────────────────
local function bkt_error(o)
  if o.code ~= 0 then
    return vim.trim((o.stderr ~= "" and o.stderr) or o.stdout or ("exit " .. o.code))
  end
  if (o.stdout or ""):match("^%s*Error:") then
    return vim.trim(o.stdout)
  end
end

-- run a command (list form); cb(ok, stdout, stderr)
local function sh(cmd, cwd, cb)
  vim.system(cmd, { text = true, cwd = cwd }, function(o)
    vim.schedule(function()
      cb(o.code == 0, o.stdout or "", o.stderr or "")
    end)
  end)
end

-- run bkt and decode JSON; cb(decoded|nil, err)
local function bkt_json(args, cwd, cb)
  local cmd = { config.bkt }
  vim.list_extend(cmd, args)
  table.insert(cmd, "--json")
  vim.system(cmd, { text = true, cwd = cwd }, function(o)
    vim.schedule(function()
      local err = bkt_error(o)
      if err then
        return cb(nil, err)
      end
      local ok, decoded = pcall(vim.json.decode, o.stdout)
      if not ok then
        return cb(nil, "non-JSON output: " .. vim.trim(o.stdout):sub(1, 200))
      end
      cb(decoded, nil)
    end)
  end)
end

local function cwd()
  local f = api.nvim_buf_get_name(0)
  return f ~= "" and vim.fs.dirname(f) or vim.fn.getcwd()
end

-- ── comment normalization ───────────────────────────────────────────────────
local function normalize_comments(list)
  local byid = {}
  local function norm(c)
    local inline = val(c.inline) or val(c.anchor) or {}
    local parent = val(c.parent)
    return {
      id = first(c.id, c.commentId),
      parent = (type(parent) == "table" and first(parent.id, parent.parentId)) or val(c.parentId),
      path = first(inline.path, inline.file, c.path),
      to = first(inline.to, inline.toLine, inline.to_line),
      from = first(inline.from, inline.fromLine, inline.from_line),
      text = first(dig(c, "content", "raw"), c.text, c.message, ""),
      author = first(
        dig(c, "user", "display_name"),
        dig(c, "user", "displayName"),
        dig(c, "user", "name"),
        dig(c, "author", "displayName"),
        dig(c, "author", "name"),
        "?"
      ),
      resolved = first(val(c.resolved), val(c.resolution) ~= nil, false),
      replies = {},
    }
  end
  local all = {}
  for _, c in ipairs(list or {}) do
    local n = norm(c)
    if n.id then
      byid[n.id] = n
      all[#all + 1] = n
    end
  end
  local roots = {}
  for _, n in ipairs(all) do
    if n.parent and byid[n.parent] then
      table.insert(byid[n.parent].replies, n)
    else
      roots[#roots + 1] = n
    end
  end
  -- index roots by file path for overlay placement
  local by_path = {}
  for _, t in ipairs(roots) do
    if t.path then
      by_path[t.path] = by_path[t.path] or {}
      table.insert(by_path[t.path], t)
    end
  end
  return { byid = byid, roots = roots, by_path = by_path }
end

-- ── overlay (read-only): signs + virtual text + thread float ────────────────
local function open_float(lines, title)
  -- close any previously-open thread float so jumps don't stack windows
  if M._float_win and api.nvim_win_is_valid(M._float_win) then
    pcall(api.nvim_win_close, M._float_win, true)
  end
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local width = math.min(90, math.max(50, math.floor(vim.o.columns * 0.7)))
  local height = math.max(4, math.min(#lines + 1, math.floor(vim.o.lines * 0.6)))
  local win = api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. (title or "thread") .. " — q to close ",
    title_pos = "center",
  })
  vim.wo[win].wrap = true
  M._float_win = win
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf })
  vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", { buffer = buf })
end

local function thread_lines(t)
  local lines = {}
  local function add(c, depth)
    local pad = string.rep("  ", depth)
    lines[#lines + 1] = pad .. ("**%s**%s"):format(c.author, c.resolved and "  _(resolved)_" or "")
    if c.text == "" then
      lines[#lines + 1] = pad .. "_(no text)_"
    else
      for _, l in ipairs(vim.split(c.text, "\n", { plain = true })) do
        lines[#lines + 1] = pad .. l
      end
    end
    lines[#lines + 1] = ""
    for _, r in ipairs(c.replies) do
      add(r, depth + 1)
    end
  end
  add(t, 0)
  return lines
end

-- line for a thread on the given diff side ('b' = new/to, 'a' = old/from)
local function thread_line(t, side)
  if side == "a" then
    return t.from
  end
  return t.to or t.from
end

-- one-line summary for virtual text / picker (falls back to a reply, then placeholder)
local function summary(t)
  if t.text ~= "" then
    return vim.split(t.text, "\n")[1]
  end
  for _, r in ipairs(t.replies) do
    if r.text ~= "" then
      return "↳ " .. vim.split(r.text, "\n")[1]
    end
  end
  return "(no text)"
end

local function overlay_buffer(bufnr, path, side)
  local s = M.active
  if not s or not api.nvim_buf_is_valid(bufnr) then
    return
  end
  api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local threads = s.threads.by_path[path]
  if not threads then
    return
  end
  local placed = {}
  for _, t in ipairs(threads) do
    local ln = thread_line(t, side)
    if ln and ln >= 1 then
      placed[ln] = t
      local n = 1 + #t.replies
      api.nvim_buf_set_extmark(bufnr, ns, ln - 1, 0, {
        sign_text = t.resolved and "✓" or "▌",
        sign_hl_group = t.resolved and "DiagnosticSignOk" or "DiagnosticSignInfo",
        virt_text = {
          { ("  %s %s: %s"):format(t.resolved and "✓" or "💬", t.author, summary(t)), "Comment" },
          n > 1 and { (" (+%d)"):format(n - 1), "DiagnosticVirtualTextInfo" } or { "", "Comment" },
        },
        virt_text_pos = "eol",
      })
    end
  end
  -- expose placement so the write actions can find the thread under the cursor
  M._buf = M._buf or {}
  M._buf[bufnr] = { path = path, side = side, placed = placed }

  local p = config.prefix
  local function kmap(lhs, fn, desc)
    vim.keymap.set("n", lhs, function()
      fn(bufnr)
    end, { buffer = bufnr, desc = "PR: " .. desc })
  end
  kmap("<CR>", M.open_thread_at, "open thread")
  kmap(p .. "a", M.add_comment, "add comment")
  kmap(p .. "r", M.reply, "reply")
  kmap(p .. "e", M.edit_comment, "edit comment")
  kmap(p .. "d", M.delete_comment, "delete comment")
  kmap(p .. "t", M.toggle_resolve, "resolve / unresolve")
end

-- ── diffview integration ────────────────────────────────────────────────────
local function ensure_hook()
  if M._hooked then
    return true
  end
  pcall(require, "diffview")
  local g = _G.DiffviewGlobal
  if not g or not g.emitter then
    return false
  end
  g.emitter:on("diff_buf_win_enter", function(_, bufnr, _winid, ctx)
    local s = M.active
    if not s then
      return
    end
    -- only act inside our review worktree to avoid touching unrelated diffviews
    if vim.fn.getcwd() ~= s.wt then
      return
    end
    local ok, lib = pcall(require, "diffview.lib")
    local view = ok and lib.get_current_view()
    local path = view and view.cur_entry and view.cur_entry.path
    if not path then
      local name = api.nvim_buf_get_name(bufnr)
      path = name ~= "" and vim.fs.relpath(s.wt, name) or nil
    end
    if path then
      overlay_buffer(bufnr, path, ctx and ctx.symbol or "b")
    end
  end)
  M._hooked = true
  return true
end

-- ── writes: add / reply / edit / delete / resolve ───────────────────────────
-- multi-line editor float; :w / <leader>w submits, q / Esc cancels
local function open_editor(initial, on_submit)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  if initial and initial ~= "" then
    api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(initial, "\n", { plain = true }))
  end
  local width = math.min(80, math.floor(vim.o.columns * 0.6))
  local win = api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = 8,
    style = "minimal",
    border = "rounded",
    title = " comment  (:w / <leader>w submit · q cancel) ",
    title_pos = "center",
  })
  if not initial or initial == "" then
    vim.cmd("startinsert")
  end
  local function close()
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end
  local function submit()
    local text = vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    close()
    if text ~= "" then
      on_submit(text)
    end
  end
  vim.keymap.set("n", "<leader>w", submit, { buffer = buf })
  vim.keymap.set("n", "q", close, { buffer = buf })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf })
  api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = submit })
end

local function thread_at(bufnr)
  local info = M._buf and M._buf[bufnr]
  if not info or not info.placed then
    return nil, info
  end
  return info.placed[api.nvim_win_get_cursor(0)[1]], info
end

local function flatten(t, acc)
  acc[#acc + 1] = t
  for _, r in ipairs(t.replies) do
    flatten(r, acc)
  end
  return acc
end

-- choose a comment in the thread (root or a reply); auto-selects when only one
local function pick_comment(t, verb, cb)
  local list = flatten(t, {})
  if #list == 1 then
    return cb(list[1])
  end
  vim.ui.select(list, {
    prompt = verb .. " which comment?",
    format_item = function(c)
      return ("%s: %s"):format(c.author, summary(c))
    end,
  }, function(c)
    if c then
      cb(c)
    end
  end)
end

local function comment_api_path(cid)
  local s = M.active
  if not (s and s.ws and s.slug) then
    return nil
  end
  return ("/repositories/%s/%s/pullrequests/%s/comments/%s"):format(s.ws, s.slug, s.id, cid)
end

local function api_call(path, method, body, cb)
  local cmd = { config.bkt, "api", path, "--method", method }
  if body then
    vim.list_extend(cmd, { "--input", vim.json.encode(body) })
  end
  sh(cmd, M.active and M.active.wt, function(ok, out, err)
    cb(ok, vim.trim((not ok and (err ~= "" and err or out)) or out or ""))
  end)
end

local function reload_and_refresh(bufnr)
  local s = M.active
  if not s then
    return
  end
  bkt_json({ "pr", "comments", tostring(s.id), "--details" }, s.wt, function(c)
    if c then
      s.threads = normalize_comments(as_list(c) or {})
    end
    local info = M._buf and M._buf[bufnr]
    if info and api.nvim_buf_is_valid(bufnr) then
      overlay_buffer(bufnr, info.path, info.side)
    end
  end)
end

function M.open_thread_at(bufnr)
  local t, info = thread_at(bufnr)
  if t and info then
    open_float(thread_lines(t), ("%s:%s"):format(info.path, thread_line(t, info.side) or "?"))
  end
end

function M.add_comment(bufnr)
  local s, info = M.active, M._buf and M._buf[bufnr]
  if not (s and info) then
    return
  end
  local line = api.nvim_win_get_cursor(0)[1]
  open_editor("", function(text)
    local cmd = { config.bkt, "pr", "comment", tostring(s.id), "--file", info.path, "--text", text }
    vim.list_extend(cmd, info.side == "a" and { "--from-line", tostring(line) } or { "--to-line", tostring(line) })
    sh(cmd, s.wt, function(ok, _, err)
      if not ok then
        return notify("comment failed: " .. err, vim.log.levels.ERROR)
      end
      notify("comment added")
      reload_and_refresh(bufnr)
    end)
  end)
end

function M.reply(bufnr)
  local s, t = M.active, thread_at(bufnr)
  if not (s and t) then
    return notify("no thread on this line")
  end
  open_editor("", function(text)
    sh({ config.bkt, "pr", "comment", tostring(s.id), "--parent", tostring(t.id), "--text", text }, s.wt, function(ok, _, err)
      if not ok then
        return notify("reply failed: " .. err, vim.log.levels.ERROR)
      end
      notify("reply posted")
      reload_and_refresh(bufnr)
    end)
  end)
end

function M.edit_comment(bufnr)
  local t = thread_at(bufnr)
  if not t then
    return notify("no thread on this line")
  end
  pick_comment(t, "edit", function(c)
    local path = comment_api_path(c.id)
    if not path then
      return notify("workspace/repo unknown — cannot edit", vim.log.levels.WARN)
    end
    open_editor(c.text, function(text)
      api_call(path, "PUT", { content = { raw = text } }, function(ok, out)
        if not ok then
          return notify("edit failed: " .. out, vim.log.levels.ERROR)
        end
        notify("comment updated")
        reload_and_refresh(bufnr)
      end)
    end)
  end)
end

function M.delete_comment(bufnr)
  local t = thread_at(bufnr)
  if not t then
    return notify("no thread on this line")
  end
  pick_comment(t, "delete", function(c)
    local path = comment_api_path(c.id)
    if not path then
      return notify("workspace/repo unknown — cannot delete", vim.log.levels.WARN)
    end
    vim.ui.select({ "yes", "no" }, { prompt = ("Delete comment by %s?"):format(c.author) }, function(ans)
      if ans ~= "yes" then
        return
      end
      api_call(path, "DELETE", nil, function(ok, out)
        if not ok then
          return notify("delete failed: " .. out, vim.log.levels.ERROR)
        end
        notify("comment deleted")
        reload_and_refresh(bufnr)
      end)
    end)
  end)
end

function M.toggle_resolve(bufnr)
  local t = thread_at(bufnr)
  if not t then
    return notify("no thread on this line")
  end
  local path = comment_api_path(t.id)
  if not path then
    return notify("workspace/repo unknown — cannot resolve", vim.log.levels.WARN)
  end
  local method = t.resolved and "DELETE" or "POST"
  api_call(path .. "/resolve", method, nil, function(ok, out)
    if not ok then
      return notify((t.resolved and "reopen" or "resolve") .. " failed: " .. out, vim.log.levels.ERROR)
    end
    notify(t.resolved and "reopened" or "resolved")
    reload_and_refresh(bufnr)
  end)
end

-- ── worktree management ─────────────────────────────────────────────────────
local function ensure_worktree(meta, cb)
  local path = config.worktree_dir .. "/" .. meta.repo .. "-pr" .. meta.id
  -- tool-namespaced branch: won't collide with the user's own pr/<id> branches
  local branch = "bkt-review/pr" .. meta.id
  meta.branch = branch

  local function finish()
    -- fetch the destination branch so origin/<dst> exists as the diff base
    sh({ "git", "-C", path, "fetch", "origin", meta.dst or "HEAD" }, nil, function()
      cb(path)
    end)
  end

  local function create()
    vim.fn.mkdir(config.worktree_dir, "p")
    notify(("creating worktree for PR #%s …"):format(meta.id))
    -- free the tool-owned branch if it lingers from a previous review (ignore errors)
    sh({ "git", "-C", meta.root, "branch", "-D", branch }, nil, function()
      sh({ "git", "-C", meta.root, "worktree", "add", "--detach", path, "HEAD" }, nil, function(ok, _, err)
        if not ok then
          return notify("worktree add failed: " .. err, vim.log.levels.ERROR)
        end
        notify(("fetching PR #%s …"):format(meta.id))
        sh({ config.bkt, "pr", "checkout", tostring(meta.id), "--branch", branch }, path, function(ok2, _, e2)
          if not ok2 then
            return notify("pr checkout failed: " .. e2, vim.log.levels.ERROR)
          end
          finish()
        end)
      end)
    end)
  end

  if vim.fn.isdirectory(path) == 1 then
    local cur = vim.fn.systemlist({ "git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD" })[1]
    if cur == branch then
      return finish() -- reuse: already on the PR branch
    end
    -- stale / detached / wrong-branch worktree: remove and recreate
    notify("recreating stale worktree …")
    sh({ "git", "-C", meta.root, "worktree", "remove", "--force", path }, nil, function()
      vim.fn.delete(path, "rf")
      create()
    end)
  else
    create()
  end
end

local function open_review(meta, wt)
  meta.wt = wt
  M.active = meta
  if not ensure_hook() then
    notify("diffview not available", vim.log.levels.ERROR)
    return
  end
  -- load comments (in the worktree so bkt detects the repo), then open diffview
  bkt_json({ "pr", "comments", tostring(meta.id), "--details" }, wt, function(comments, err)
    if comments then
      meta.threads = normalize_comments(as_list(comments) or {})
    else
      meta.threads = { byid = {}, roots = {}, by_path = {} }
      notify("comments load failed (continuing without overlay): " .. err, vim.log.levels.WARN)
    end
    vim.cmd("tabnew")
    vim.cmd("tcd " .. vim.fn.fnameescape(wt))
    local base = meta.dst and ("origin/" .. meta.dst) or "HEAD"
    local okq = pcall(vim.cmd, "DiffviewOpen " .. base .. "...HEAD")
    if not okq then
      pcall(vim.cmd, "DiffviewOpen") -- fallback: working tree
    end
    meta.tab = api.nvim_get_current_tabpage()
    local nthreads = #meta.threads.roots
    notify(("PR #%s — worktree %s — %d threads. <CR> on 💬 to view."):format(meta.id, wt, nthreads))
  end)
end

-- ── resolve PR metadata, then open ──────────────────────────────────────────
local function meta_from_pr(pr, root, repo)
  local full = first(dig(pr, "destination", "repository", "full_name"), dig(pr, "source", "repository", "full_name"))
  local ws, slug = nil, nil
  if full then
    ws, slug = full:match("^([^/]+)/(.+)$")
  end
  return {
    id = tostring(first(pr.id, pr.number)),
    src = dig(pr, "source", "branch", "name"),
    dst = dig(pr, "destination", "branch", "name"),
    root = root,
    repo = repo,
    ws = ws,
    slug = slug,
    url = first(dig(pr, "links", "html", "href")),
    draft = first(val(pr.draft), false),
  }
end

function M.review(pr)
  -- resolve the MAIN repo (not a linked worktree) so the name + worktree base
  -- are correct even when :BktPr is launched from inside an existing review.
  local common = vim.fn.systemlist({ "git", "-C", cwd(), "rev-parse", "--path-format=absolute", "--git-common-dir" })[1]
  if not common or common == "" or vim.v.shell_error ~= 0 then
    return notify("not inside a git repo", vim.log.levels.ERROR)
  end
  local root = vim.fn.fnamemodify(common, ":h")
  local repo = vim.fn.fnamemodify(root, ":t")

  local function go(pr_obj)
    local meta = meta_from_pr(pr_obj, root, repo)
    if not meta.dst then
      notify("could not resolve destination branch; diff base may be wrong", vim.log.levels.WARN)
    end
    ensure_worktree(meta, function(wt)
      open_review(meta, wt)
    end)
  end

  if type(pr) == "table" then
    return go(pr)
  end
  -- bare id: fetch the PR object from the list (with --mine fallback)
  local id = tostring(pr)
  local function fetch(args, retry)
    bkt_json(args, cwd(), function(prs, err)
      if not prs then
        if retry and err:match("%-%-mine is required") then
          return fetch(vim.list_extend(vim.deepcopy(args), { "--mine" }), false)
        end
        return notify("could not fetch PR #" .. id .. ": " .. err, vim.log.levels.ERROR)
      end
      for _, p in ipairs(as_list(prs) or {}) do
        if tostring(first(p.id, p.number)) == id then
          return go(p)
        end
      end
      notify("PR #" .. id .. " not found in list — open via :BktPr picker", vim.log.levels.ERROR)
    end)
  end
  fetch({ "pr", "list" }, true)
end

-- root threads with a file anchor, ordered by file then line
local function sorted_threads(s)
  local items = {}
  for _, t in ipairs(s.threads.roots) do
    if t.path then
      items[#items + 1] = t
    end
  end
  table.sort(items, function(a, b)
    local pa, pb = a.path or "", b.path or ""
    if pa ~= pb then
      return pa < pb
    end
    return (a.to or a.from or 0) < (b.to or b.from or 0)
  end)
  return items
end

-- jump into the open Diffview at a thread's file + line
function M.goto_thread(t)
  local s = M.active
  if s and s.tab and api.nvim_tabpage_is_valid(s.tab) then
    api.nvim_set_current_tabpage(s.tab)
  end
  local line = t.to or t.from or 1
  local ok, lib = pcall(require, "diffview.lib")
  local view = ok and lib.get_current_view()
  if view and t.path then
    pcall(function()
      for _, f in view.files:iter() do
        if f.path == t.path then
          view:set_file(f, true)
          break
        end
      end
    end)
  elseif s and s.wt and t.path then
    vim.cmd("edit " .. vim.fn.fnameescape(s.wt .. "/" .. t.path)) -- fallback when no view
  end
  vim.schedule(function()
    pcall(api.nvim_win_set_cursor, 0, { line, 0 })
    pcall(vim.cmd, "normal! zz")
    -- open the thread itself, not just position the cursor
    open_float(thread_lines(t), ("%s:%s"):format(t.path or "?", line))
  end)
end

-- Telescope (or vim.ui.select) picker over the active review's comment threads.
function M.comments_picker()
  local s = M.active
  if not s or not s.threads then
    return notify("no active review — open one with :BktPr")
  end
  local items = sorted_threads(s)
  if #items == 0 then
    return notify("no comments on this PR")
  end
  local function remember(t) -- keep ]/[ in sync with picker selection
    for i, x in ipairs(items) do
      if x == t then
        s._idx = i
        return
      end
    end
  end

  local function label(t)
    return ("%s %s:%s  %s  %s"):format(
      t.resolved and "✓" or "💬",
      t.path or "?",
      t.to or t.from or "?",
      t.author,
      summary(t)
    )
  end

  local ok = pcall(require, "telescope")
  if not ok then
    return vim.ui.select(items, { prompt = "PR comments", format_item = label }, function(c)
      if c then
        remember(c)
        M.goto_thread(c)
      end
    end)
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local astate = require("telescope.actions.state")
  pickers
    .new({}, {
      prompt_title = "PR #" .. s.id .. " comments",
      finder = finders.new_table({
        results = items,
        entry_maker = function(t)
          return {
            value = t,
            display = label(t),
            ordinal = (t.path or "") .. " " .. t.author .. " " .. summary(t),
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(bufnr)
        actions.select_default:replace(function()
          actions.close(bufnr)
          local e = astate.get_selected_entry()
          if e then
            remember(e.value)
            M.goto_thread(e.value)
          end
        end)
        return true
      end,
    })
    :find()
end

-- cycle to the next (dir=1) / previous (dir=-1) comment thread and open it
function M.goto_relative(dir)
  local s = M.active
  if not s or not s.threads then
    return notify("no active review — open one with :BktPr")
  end
  local items = sorted_threads(s)
  if #items == 0 then
    return notify("no comments on this PR")
  end
  local idx = (s._idx or 0) + dir
  if idx < 1 then
    idx = #items
  elseif idx > #items then
    idx = 1
  end
  s._idx = idx
  notify(("comment %d/%d"):format(idx, #items))
  M.goto_thread(items[idx])
end

-- open the active PR in the browser
function M.open_in_browser()
  local s = M.active
  if not s then
    return notify("no active review — open one with :BktPr")
  end
  local url = s.url
  if not url and s.ws and s.slug then
    url = ("https://bitbucket.org/%s/%s/pull-requests/%s"):format(s.ws, s.slug, s.id)
  end
  if not url then
    return notify("PR url unknown", vim.log.levels.WARN)
  end
  vim.ui.open(url)
  notify("opening " .. url)
end

-- toggle the active PR between draft and ready (bkt pr publish [--undo])
function M.toggle_draft()
  local s = M.active
  if not s then
    return notify("no active review — open one with :BktPr")
  end
  local cmd = { config.bkt, "pr", "publish", tostring(s.id) }
  if not s.draft then
    table.insert(cmd, "--undo") -- currently ready -> back to draft
  end
  sh(cmd, s.wt, function(ok, _, err)
    if not ok then
      return notify("toggle draft failed: " .. err, vim.log.levels.ERROR)
    end
    s.draft = not s.draft
    notify(s.draft and "PR set to draft" or "PR published (ready for review)")
  end)
end

function M.pick(extra)
  local has_extra = extra and #extra > 0
  local args = { "pr", "list" }
  if has_extra then
    vim.list_extend(args, extra)
  end
  local function run(a, may_retry)
    bkt_json(a, cwd(), function(prs, err)
      if not prs then
        if may_retry and err:match("%-%-mine is required") then
          notify("no repo detected — listing your PRs (--mine)")
          return run(vim.list_extend(vim.deepcopy(a), { "--mine" }), false)
        end
        return notify("list failed: " .. err, vim.log.levels.ERROR)
      end
      local list = as_list(prs)
      if not list or #list == 0 then
        return notify("no PRs for this scope — try :BktPr --mine")
      end
      vim.ui.select(list, {
        prompt = "Bitbucket PR",
        format_item = function(p)
          return ("#%s  [%s] %s"):format(first(p.id, p.number), first(p.state, "?"), first(p.title, "?"))
        end,
      }, function(choice)
        if choice then
          M.review(choice)
        end
      end)
    end)
  end
  run(args, not has_extra)
end

function M.clean()
  local base = config.worktree_dir
  if vim.fn.isdirectory(base) == 0 then
    return notify("no worktrees")
  end
  local dirs = vim.fn.globpath(base, "*", false, true)
  if #dirs == 0 then
    return notify("no worktrees")
  end
  local n = 0
  for _, d in ipairs(dirs) do
    -- resolve the main worktree to run `worktree remove` from
    local common = vim.fn.systemlist({ "git", "-C", d, "rev-parse", "--path-format=absolute", "--git-common-dir" })[1]
    local mainwt = common and vim.fn.fnamemodify(common, ":h") or nil
    if mainwt and vim.v.shell_error == 0 then
      vim.fn.system({ "git", "-C", mainwt, "worktree", "remove", "--force", d })
    end
    vim.fn.delete(d, "rf")
    if mainwt then
      vim.fn.system({ "git", "-C", mainwt, "worktree", "prune" })
    end
    n = n + 1
  end
  M.active = nil
  notify(("removed %d worktree(s)"):format(n))
end

function M.raw_comments(id)
  local cmd = { config.bkt, "pr", "comments", tostring(id), "--details", "--json" }
  vim.system(cmd, { text = true, cwd = cwd() }, function(o)
    vim.schedule(function()
      open_float(vim.split(o.stdout ~= "" and o.stdout or o.stderr, "\n", { plain = true }), "raw comments JSON")
    end)
  end)
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  api.nvim_create_user_command("BktPr", function(o)
    M.pick(o.fargs)
  end, { nargs = "*" })
  api.nvim_create_user_command("BktPrReview", function(o)
    M.review(o.args)
  end, { nargs = 1 })
  api.nvim_create_user_command("BktComments", function()
    M.comments_picker()
  end, {})
  api.nvim_create_user_command("BktPrWeb", function()
    M.open_in_browser()
  end, {})
  api.nvim_create_user_command("BktPrDraft", function()
    M.toggle_draft()
  end, {})
  api.nvim_create_user_command("BktReviewClean", function()
    M.clean()
  end, {})
  api.nvim_create_user_command("BktPrComments", function(o)
    M.raw_comments(o.args)
  end, { nargs = 1 })

  -- all keymaps live under the <leader>p (PR review) group
  local p = config.prefix
  local function map(lhs, fn, desc)
    vim.keymap.set("n", p .. lhs, fn, { desc = "PR: " .. desc })
  end
  map("p", function()
    M.pick()
  end, "pick / open PR")
  map("c", function()
    M.comments_picker()
  end, "jump to comment")
  map("]", function()
    M.goto_relative(1)
  end, "next comment")
  map("[", function()
    M.goto_relative(-1)
  end, "prev comment")
  map("o", function()
    M.open_in_browser()
  end, "open PR in browser")
  map("D", function()
    M.toggle_draft()
  end, "toggle draft / ready")
  map("x", function()
    M.clean()
  end, "clean worktrees")

  -- name the which-key group when available
  local okwk, wk = pcall(require, "which-key")
  if okwk and wk.add then
    pcall(wk.add, { { p, group = "PR review" } })
  end
end

return M
