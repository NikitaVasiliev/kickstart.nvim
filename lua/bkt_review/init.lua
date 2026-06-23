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
  -- prefer the current file's dir, but fall back to the tab cwd when the
  -- buffer has no real path (e.g. a diffview:// panel) — otherwise git/bkt
  -- run in a bogus dir and switching PRs from inside a review fails.
  local f = api.nvim_buf_get_name(0)
  if f ~= "" then
    local dir = vim.fs.dirname(f)
    if vim.fn.isdirectory(dir) == 1 then
      return dir
    end
  end
  return vim.fn.getcwd()
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
  return buf, win
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
  -- place signs only for existing threads, but always wire the keymaps below so
  -- you can add a comment on a file that has no comments yet
  local placed = {}
  for _, t in ipairs(s.threads.by_path[path] or {}) do
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

-- jump into the open Diffview at a thread's file + line, then open the thread
function M.goto_thread(t)
  local s = M.active
  if s and s.tab and api.nvim_tabpage_is_valid(s.tab) then
    api.nvim_set_current_tabpage(s.tab)
  end
  local line = t.to or t.from or 1
  local side = t.to and "b" or "a" -- new side for `to`, old side for `from`
  local ok, lib = pcall(require, "diffview.lib")
  local view = ok and lib.get_current_view()

  local function show_thread()
    open_float(thread_lines(t), ("%s:%s"):format(t.path or "?", line))
  end

  if not view or not t.path then
    if s and s.wt and t.path then
      vim.cmd("edit " .. vim.fn.fnameescape(s.wt .. "/" .. t.path))
      pcall(api.nvim_win_set_cursor, 0, { line, 0 })
      pcall(vim.cmd, "normal! zz")
    end
    return show_thread()
  end

  local same = view.cur_entry and view.cur_entry.path == t.path
  pcall(function()
    for _, f in view.files:iter() do
      if f.path == t.path then
        view:set_file(f, true)
        break
      end
    end
  end)

  -- focus the correct diff window and place the cursor; retry until the diff
  -- buffer has finished loading (set_file is async), then open the thread.
  local function place(attempts)
    local v = lib.get_current_view()
    local win = v and v.cur_layout and (v.cur_layout[side] or v.cur_layout:get_main_win())
    if win and win.id and api.nvim_win_is_valid(win.id) then
      local buf = api.nvim_win_get_buf(win.id)
      local lc = api.nvim_buf_line_count(buf)
      if lc < line and attempts > 0 then
        return vim.defer_fn(function()
          place(attempts - 1)
        end, 50)
      end
      api.nvim_set_current_win(win.id)
      pcall(api.nvim_win_set_cursor, win.id, { math.min(line, lc), 0 })
      pcall(vim.cmd, "normal! zz")
    end
    show_thread()
  end

  if same then
    place(0)
  else
    vim.defer_fn(function()
      place(4)
    end, 50)
  end
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

-- ── export comments to revdiff format ───────────────────────────────────────
local function append_thread_text(lines, t)
  local function add(c, depth)
    local pad = string.rep("  ", depth)
    local arrow = depth > 0 and "↳ " or ""
    local body = c.text ~= "" and c.text or "(no text)"
    local parts = vim.split(body, "\n", { plain = true })
    lines[#lines + 1] = ("%s%s%s%s: %s"):format(pad, arrow, c.author, c.resolved and " (resolved)" or "", parts[1])
    for i = 2, #parts do
      lines[#lines + 1] = pad .. "  " .. parts[i]
    end
    for _, r in ipairs(c.replies) do
      add(r, depth + 1)
    end
  end
  add(t, 0)
end

-- Write the active PR's comment threads as a revdiff history file (and show it).
-- Format matches scripts/revdiff-review/README.md so the revdiff Claude skill
-- consumes it via "use my latest revdiff annotations".
function M.export_revdiff()
  local s = M.active
  if not s then
    return notify("no active review — open one with :BktPr")
  end
  local inline = sorted_threads(s)
  local generals = {}
  for _, t in ipairs(s.threads.roots) do
    if not t.path then
      generals[#generals + 1] = t
    end
  end
  if #inline == 0 and #generals == 0 then
    return notify("no comments to export")
  end

  sh({ "git", "-C", s.wt, "rev-parse", "--short", "HEAD" }, nil, function(_, sha)
    sha = vim.trim(sha or "")
    local paths, seen = {}, {}
    for _, t in ipairs(inline) do
      if not seen[t.path] then
        seen[t.path] = true
        paths[#paths + 1] = t.path
      end
    end
    local diffcmd = { "git", "-C", s.wt, "diff" }
    if s.dst then
      table.insert(diffcmd, "origin/" .. s.dst .. "...HEAD")
    end
    table.insert(diffcmd, "--")
    vim.list_extend(diffcmd, paths)
    sh(diffcmd, nil, function(_, diffout)
      local lines = { "# Review: " .. os.date("%Y-%m-%d %H:%M:%S"), "path: " .. (s.wt or s.root or "") }
      if sha ~= "" then
        lines[#lines + 1] = "commit: " .. sha
      end
      vim.list_extend(lines, { "", "## Annotations", "" })
      for _, t in ipairs(inline) do
        local ln = t.to or t.from
        lines[#lines + 1] = ln and ("## %s:%d (line)"):format(t.path, ln) or ("## %s (file-level)"):format(t.path)
        append_thread_text(lines, t)
        lines[#lines + 1] = ""
      end
      for _, t in ipairs(generals) do
        lines[#lines + 1] = "## (general)"
        append_thread_text(lines, t)
        lines[#lines + 1] = ""
      end
      vim.list_extend(lines, { "---", "", "## Diff", "" })
      if diffout and diffout ~= "" then
        vim.list_extend(lines, vim.split(diffout, "\n", { plain = true }))
      end

      -- open in a fresh scratch buffer (no file written, nothing copied)
      local buf = api.nvim_create_buf(true, true)
      api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].filetype = "markdown"
      pcall(api.nvim_buf_set_name, buf, ("bkt://pr/%s/revdiff.md"):format(s.id))
      vim.cmd("tabnew")
      api.nvim_win_set_buf(0, buf)
      notify(("PR #%s comments in revdiff format — %d threads"):format(s.id, #inline + #generals))
    end)
  end)
end

-- re-fetch the PR (new commits + comments) and refresh the diff + overlay
function M.refresh()
  local s = M.active
  if not s then
    return notify("no active review — open one with :BktPr")
  end
  notify("refreshing PR #" .. s.id .. " …")

  local function finish()
    bkt_json({ "pr", "comments", tostring(s.id), "--details" }, s.wt, function(c)
      if c then
        s.threads = normalize_comments(as_list(c) or {})
      end
      if s.tab and api.nvim_tabpage_is_valid(s.tab) then
        pcall(api.nvim_set_current_tabpage, s.tab)
      end
      pcall(vim.cmd, "DiffviewRefresh")
      local bufnr = api.nvim_get_current_buf()
      local info = M._buf and M._buf[bufnr]
      if info and api.nvim_buf_is_valid(bufnr) then
        overlay_buffer(bufnr, info.path, info.side)
      end
      notify(("PR #%s refreshed — %d threads"):format(s.id, #s.threads.roots))
    end)
  end

  local function fetch_dest_then_finish()
    sh({ "git", "-C", s.wt, "fetch", "origin", s.dst or "HEAD" }, nil, finish)
  end

  -- fetch everything, then fast-forward the PR branch if it moved (ff-only is
  -- non-destructive: it won't clobber local commits/edits, just fails)
  sh({ "git", "-C", s.wt, "fetch", "--all", "--prune" }, nil, function()
    if s.src then
      sh({ "git", "-C", s.wt, "merge", "--ff-only", "origin/" .. s.src }, nil, function(ok)
        if not ok then
          notify("PR branch not fast-forwarded (diverged/local changes) — comments+diff refreshed", vim.log.levels.WARN)
        end
        fetch_dest_then_finish()
      end)
    else
      fetch_dest_then_finish()
    end
  end)
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

-- ── pipelines (Bitbucket Cloud) ─────────────────────────────────────────────
-- generic picker: telescope when available, else vim.ui.select
local function select_one(items, opts, on_choice)
  if not items or #items == 0 then
    return notify(opts.empty or "nothing to select")
  end
  if not pcall(require, "telescope") then
    return vim.ui.select(items, { prompt = opts.prompt, format_item = opts.label }, function(c)
      if c then
        on_choice(c)
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
      prompt_title = opts.prompt,
      finder = finders.new_table({
        results = items,
        entry_maker = function(it)
          local disp = opts.label(it)
          return { value = it, display = disp, ordinal = (opts.ordinal and opts.ordinal(it)) or disp }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(bufnr, map)
        actions.select_default:replace(function()
          actions.close(bufnr)
          local e = astate.get_selected_entry()
          if e then
            on_choice(e.value)
          end
        end)
        for lhs, fn in pairs(opts.actions or {}) do
          map({ "i", "n" }, lhs, function()
            actions.close(bufnr)
            local e = astate.get_selected_entry()
            if e then
              fn(e.value)
            end
          end)
        end
        return true
      end,
    })
    :find()
end

local function remote_ws_slug(dir)
  local url = (vim.fn.systemlist({ "git", "-C", dir, "remote", "get-url", "origin" })[1] or "")
  local ws, slug = url:match("bitbucket%.org[:/]([^/]+)/([^/]+)")
  if slug then
    slug = slug:gsub("%.git$", "")
  end
  return ws, slug
end

-- fetch recent runs with rich target data (PR/branch) via the raw API, falling
-- back to bkt's plain list when ws/slug or the API call is unavailable
local function fetch_pipelines(cb)
  local ws, slug = remote_ws_slug(cwd())
  local function plain()
    bkt_json({ "pipeline", "list", "--limit", "30" }, cwd(), function(d)
      cb(as_list(d) or {})
    end)
  end
  if not (ws and slug) then
    return plain()
  end
  bkt_json({
    "api",
    ("/repositories/%s/%s/pipelines/"):format(ws, slug),
    "--param",
    "sort=-created_on",
    "--param",
    "pagelen=30",
  }, cwd(), function(data)
    if data then
      cb(as_list(data) or {})
    else
      plain()
    end
  end)
end

local STATUS_ICON = { SUCCESSFUL = "✓", FAILED = "✗", STOPPED = "■", ERROR = "✗", EXPIRED = "■" }

local function pipeline_status(p)
  local res = dig(p, "state", "result", "name") or dig(p, "result", "name")
  if res and res ~= "" then
    return ("%s %s"):format(STATUS_ICON[res] or "•", res:lower())
  end
  local st = dig(p, "state", "name") or ""
  local stage = dig(p, "state", "stage", "name")
  if st == "IN_PROGRESS" or stage == "RUNNING" then
    return "● running"
  end
  if st == "PENDING" then
    return "◌ pending"
  end
  return "• " .. (st ~= "" and st:lower() or "?")
end

local function pipeline_target(p)
  local pr = dig(p, "target", "pullrequest")
  if pr then
    return ("PR #%s %s"):format(tostring(first(pr.id, "?")), first(pr.title, "") or "")
  end
  local ref = dig(p, "target", "ref_name") or dig(p, "target", "ref", "name")
  if ref and ref ~= "" then
    return ref
  end
  local src = dig(p, "target", "source")
  if src then
    return src .. " → " .. (dig(p, "target", "destination") or "?")
  end
  return (dig(p, "target", "type") or "-"):gsub("^pipeline_", ""):gsub("_target$", "")
end

local function pipeline_label(p)
  local created = (first(p.created_on, "") or ""):sub(1, 16):gsub("T", " ")
  return ("#%-4s %-11s %s  %s"):format(
    tostring(first(p.build_number, "?")),
    pipeline_status(p),
    created,
    pipeline_target(p)
  )
end

local function pipeline_id(p)
  return tostring(first(p.build_number, p.uuid))
end

local function show_buffer(lines, name, ft)
  local buf = api.nvim_create_buf(true, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft or "markdown"
  pcall(api.nvim_buf_set_name, buf, name)
  vim.cmd("tabnew")
  api.nvim_win_set_buf(0, buf)
end

-- pick a recent pipeline run, then call cb(id)
local function pipeline_choose(prompt, cb)
  fetch_pipelines(function(list)
    select_one(list, { prompt = prompt, label = pipeline_label, empty = "no pipelines" }, function(p)
      cb(pipeline_id(p))
    end)
  end)
end

-- List: fzf-style picker of recent runs; <CR> view, <C-l> logs
function M.pipeline_list()
  fetch_pipelines(function(list)
    select_one(list, {
      prompt = "Pipelines",
      label = pipeline_label,
      empty = "no pipelines",
      actions = {
        ["<C-l>"] = function(p)
          M.pipeline_logs(pipeline_id(p))
        end,
      },
    }, function(p)
      M.pipeline_view(pipeline_id(p))
    end)
  end)
end

-- rerun the entire pipeline by re-triggering its target (raw API)
function M.pipeline_rerun(p)
  local ws, slug = remote_ws_slug(cwd())
  if not (ws and slug) then
    return notify("can't derive workspace/repo to rerun", vim.log.levels.WARN)
  end
  local t = val(p.target) or {}
  local target
  if t.ref_name then
    target = { ref_type = t.ref_type or "branch", type = "pipeline_ref_target", ref_name = t.ref_name }
  elseif t.source then
    target = { type = "pipeline_pullrequest_target", source = t.source }
    if t.destination then
      target.destination = t.destination
    end
    if dig(t, "pullrequest", "id") then
      target.pullrequest = { id = t.pullrequest.id }
    end
  else
    return notify("can't determine pipeline target to rerun", vim.log.levels.WARN)
  end
  if dig(t, "selector", "pattern") then
    target.selector = { type = t.selector.type, pattern = t.selector.pattern }
  end
  notify("rerunning pipeline …")
  sh({
    config.bkt,
    "api",
    ("/repositories/%s/%s/pipelines/"):format(ws, slug),
    "--method",
    "POST",
    "--input",
    vim.json.encode({ target = target }),
  }, cwd(), function(ok, out, err)
    if not ok then
      return notify("rerun failed: " .. (err ~= "" and err or out), vim.log.levels.ERROR)
    end
    local okj, resp = pcall(vim.json.decode, out)
    local n = okj and dig(resp, "build_number")
    notify(n and ("rerun triggered → #" .. n) or "rerun triggered")
  end)
end

-- View: pick a run, show a readable step breakdown with actions
function M.pipeline_view(id)
  if not id then
    return pipeline_choose("View pipeline", function(pid)
      M.pipeline_view(pid)
    end)
  end
  id = tostring(id)
  M._last_pipeline = id -- remember for :BktPipelineLast / <leader>pPV
  bkt_json({ "pipeline", "view", id }, cwd(), function(data, err)
    if not data then
      return notify("pipeline view failed: " .. err, vim.log.levels.ERROR)
    end
    local p = data.pipeline or data
    local steps = as_list(data.steps) or {}
    local build = tostring(first(p.build_number, id))
    local lines = {
      ("Pipeline #%s   %s"):format(build, pipeline_status(p)),
      pipeline_target(p),
      "",
      "Steps:",
    }
    local step_at = {}
    for _, st in ipairs(steps) do
      lines[#lines + 1] = ("  %-13s %s"):format(pipeline_status(st), st.name or "?")
      step_at[#lines] = st
    end
    vim.list_extend(lines, { "", "<CR> step logs · L all logs · r rerun · q close" })

    local buf, win = open_float(lines, "pipeline #" .. build)
    vim.wo[win].wrap = false
    local function km(lhs, fn)
      vim.keymap.set("n", lhs, fn, { buffer = buf })
    end
    km("<CR>", function()
      local st = step_at[api.nvim_win_get_cursor(0)[1]]
      if st then
        pcall(api.nvim_win_close, win, true)
        M.pipeline_logs(build, st.uuid)
      end
    end)
    km("L", function()
      pcall(api.nvim_win_close, win, true)
      M.pipeline_logs(build)
    end)
    km("r", function()
      pcall(api.nvim_win_close, win, true)
      M.pipeline_rerun(p)
    end)
  end)
end

-- View the most recently viewed pipeline again
function M.pipeline_view_last()
  if not M._last_pipeline then
    return notify("no pipeline viewed yet — use the list/view picker first")
  end
  M.pipeline_view(M._last_pipeline)
end

-- Logs: fetch logs into a new buffer (optionally for a specific step)
function M.pipeline_logs(id, step)
  local function go(pid)
    notify("fetching logs for pipeline #" .. pid .. " …")
    local cmd = { config.bkt, "pipeline", "logs", tostring(pid) }
    if step then
      vim.list_extend(cmd, { "--step", step })
    end
    sh(cmd, cwd(), function(ok, out, err)
      local text = (out and out ~= "" and out) or err
      if not ok and (not out or out == "") then
        return notify("pipeline logs failed: " .. err, vim.log.levels.ERROR)
      end
      local name = step and ("bkt://pipeline/%s/step-logs"):format(pid) or ("bkt://pipeline/%s/logs"):format(pid)
      show_buffer(vim.split(text, "\n", { plain = true }), name, "log")
    end)
  end
  if id then
    go(id)
  else
    pipeline_choose("Logs for pipeline", go)
  end
end

-- names defined under pipelines.custom in bitbucket-pipelines.yml.
-- reads the selected ref's file (origin/<ref>) so the options match the branch
-- being triggered, falling back to the working copy.
local function custom_pipelines(dir, ref)
  local lines
  if ref then
    local out = vim.fn.systemlist({ "git", "-C", dir, "show", ("origin/%s:bitbucket-pipelines.yml"):format(ref) })
    if vim.v.shell_error == 0 and out[1] then
      lines = out
    end
  end
  if not lines then
    local path = dir .. "/bitbucket-pipelines.yml"
    if vim.fn.filereadable(path) == 0 then
      return {}
    end
    lines = vim.fn.readfile(path)
  end
  local in_pipelines, in_custom, custom_indent = false, false, nil
  local names = {}
  for _, line in ipairs(lines) do
    if not (line:match("^%s*#") or line:match("^%s*$")) then
      local indent = #(line:match("^(%s*)"))
      local key = line:match("^%s*([%w%._/%-]+):")
      if indent == 0 then
        in_pipelines = key == "pipelines"
        in_custom = false
      elseif in_pipelines and not in_custom then
        if key == "custom" then
          in_custom, custom_indent = true, indent
        end
      elseif in_custom then
        if indent <= custom_indent then
          in_custom = false
        elseif indent == custom_indent + 2 and key then
          names[#names + 1] = key
        end
      end
    end
  end
  return names
end

-- Run: select a branch (ref) and a pipeline definition, then trigger
function M.pipeline_run()
  local function trigger(ref, custom)
    if not custom or custom == "" then
      notify("triggering pipeline on " .. ref .. " …")
      return sh({ config.bkt, "pipeline", "run", "--ref", ref }, cwd(), function(ok, out, err)
        if not ok then
          return notify("pipeline run failed: " .. (err ~= "" and err or out), vim.log.levels.ERROR)
        end
        notify("pipeline triggered on " .. ref)
      end)
    end
    local ws, slug = remote_ws_slug(cwd())
    if not (ws and slug) then
      notify("can't derive workspace/repo — running default pipeline", vim.log.levels.WARN)
      return trigger(ref, nil)
    end
    local body = {
      target = {
        ref_type = "branch",
        type = "pipeline_ref_target",
        ref_name = ref,
        selector = { type = "custom", pattern = custom },
      },
    }
    sh({
      config.bkt,
      "api",
      ("/repositories/%s/%s/pipelines/"):format(ws, slug),
      "--method",
      "POST",
      "--input",
      vim.json.encode(body),
    }, cwd(), function(ok, out, err)
      if not ok then
        return notify("custom pipeline failed: " .. (err ~= "" and err or out), vim.log.levels.ERROR)
      end
      notify(("pipeline '%s' triggered on %s"):format(custom, ref))
    end)
  end

  local function with_ref(ref)
    if not ref or ref == "" then
      return
    end
    local customs = custom_pipelines(cwd(), ref) -- from the selected ref's yml
    if #customs == 0 then
      return trigger(ref, nil) -- only the default/branch pipeline exists
    end
    local DEFAULT = "default (branch/PR pipeline)"
    local options = { DEFAULT }
    vim.list_extend(options, customs)
    select_one(options, { prompt = "Pipeline for " .. ref, label = function(o)
      return o
    end }, function(choice)
      trigger(ref, choice ~= DEFAULT and choice or nil)
    end)
  end

  local raw = vim.fn.systemlist({ "git", "-C", cwd(), "for-each-ref", "--format=%(refname:short)", "refs/remotes/origin" })
  local branches = {}
  for _, b in ipairs(raw) do
    local name = b:gsub("^origin/", "")
    if name ~= "" and name ~= "HEAD" then
      branches[#branches + 1] = name
    end
  end
  if #branches == 0 then
    vim.ui.input({ prompt = "Pipeline ref (branch): ", default = "main" }, with_ref)
  else
    select_one(branches, { prompt = "Run pipeline on branch", label = function(b)
      return b
    end }, with_ref)
  end
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
  api.nvim_create_user_command("BktPrRefresh", function()
    M.refresh()
  end, {})
  api.nvim_create_user_command("BktPrRevdiff", function()
    M.export_revdiff()
  end, {})
  api.nvim_create_user_command("BktPipelines", function()
    M.pipeline_list()
  end, {})
  api.nvim_create_user_command("BktPipelineView", function(o)
    M.pipeline_view(o.args ~= "" and o.args or nil)
  end, { nargs = "?" })
  api.nvim_create_user_command("BktPipelineLast", function()
    M.pipeline_view_last()
  end, {})
  api.nvim_create_user_command("BktPipelineLogs", function(o)
    M.pipeline_logs(o.args ~= "" and o.args or nil)
  end, { nargs = "?" })
  api.nvim_create_user_command("BktPipelineRun", function()
    M.pipeline_run()
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
  map("R", function()
    M.refresh()
  end, "refresh PR (fetch + comments)")
  map("E", function()
    M.export_revdiff()
  end, "export comments → revdiff")
  map("D", function()
    M.toggle_draft()
  end, "toggle draft / ready")
  map("x", function()
    M.clean()
  end, "clean worktrees")

  -- pipelines subgroup: <leader>pP…
  map("Pl", function()
    M.pipeline_list()
  end, "pipelines: list")
  map("Pv", function()
    M.pipeline_view()
  end, "pipelines: view")
  map("PV", function()
    M.pipeline_view_last()
  end, "pipelines: view last")
  map("PL", function()
    M.pipeline_logs()
  end, "pipelines: logs → buffer")
  map("Pr", function()
    M.pipeline_run()
  end, "pipelines: run (branch + pipeline)")

  -- name the which-key groups when available
  local okwk, wk = pcall(require, "which-key")
  if okwk and wk.add then
    pcall(wk.add, { { p, group = "PR review" }, { p .. "P", group = "Pipelines" } })
  end
end

return M
