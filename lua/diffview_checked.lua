-- Session-local reviewed-file markers for Diffview.
--
-- Diffview owns the contents of its panels, so this module only adds signs in
-- its own namespace after a panel redraw. State is keyed by the view object and
-- is deliberately discarded when that view closes.
local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("diffview_checked")
local views = setmetatable({}, { __mode = "k" })

local function notify(message, level)
  vim.notify("[diffview] " .. message, level or vim.log.levels.INFO)
end

local function state_for(view)
  local state = views[view]
  if not state then
    state = { checked = {}, attached = false }
    views[view] = state
  end
  return state
end

local function current_view()
  local ok, lib = pcall(require, "diffview.lib")
  return ok and lib.get_current_view() or nil
end

local function current_file(view)
  if not view then
    return nil
  end

  -- Both DiffView and FileHistoryView expose the focused panel's item. The
  -- history view also resolves a commit row to its first changed file.
  if view.panel and view.panel.is_focused and view.panel:is_focused() then
    if view.infer_cur_file then
      local ok, file = pcall(view.infer_cur_file, view)
      if ok and file and file.path then
        return file
      end
    end

    if view.panel.get_item_at_cursor then
      local item = view.panel:get_item_at_cursor()
      if item and item.path then
        return item
      end
    end
  end

  if view.infer_cur_file then
    local ok, file = pcall(view.infer_cur_file, view)
    if ok and file and file.path then
      return file
    end
  end

  return view.cur_entry and view.cur_entry.path and view.cur_entry or nil
end

local function add_sign(bufnr, row, file, checked)
  if checked[file.path] then
    api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
      sign_text = "✓",
      sign_hl_group = "DiffviewCheckedFile",
      priority = 20,
    })
  end
end

local function walk_components(component, callback)
  if not component then
    return
  end
  if component.name == "file" and component.context then
    callback(component.context, component.lstart)
  end
  for _, child in ipairs(component.components or {}) do
    walk_components(child, callback)
  end
end

local function decorate_history_panel(panel, checked)
  local entries = panel.components and panel.components.log and panel.components.log.entries
  if not entries then
    return false
  end

  for index, entry in ipairs(panel.entries or {}) do
    local struct = entries[index]
    local files_component = struct and struct.files and struct.files.comp
    if files_component and files_component.lstart then
      for file_index, file in ipairs(entry.files or {}) do
        add_sign(panel.bufid, files_component.lstart + file_index - 1, file, checked)
      end
    end
  end

  return true
end

function M.refresh(view)
  view = view or current_view()
  if not view or not view.panel or not view.panel.bufid then
    return
  end

  local panel = view.panel
  if not api.nvim_buf_is_valid(panel.bufid) then
    return
  end

  api.nvim_buf_clear_namespace(panel.bufid, ns, 0, -1)
  local checked = state_for(view).checked

  -- FileHistoryPanel renders files as plain lines beneath each commit rather
  -- than as individual components, so map those lines from its component range.
  if decorate_history_panel(panel, checked) then
    return
  end

  local root = panel.components and panel.components.comp
  walk_components(root, function(file, row)
    add_sign(panel.bufid, row, file, checked)
  end)
end

local function schedule_refresh(view)
  local state = views[view]
  if not state then
    return
  end
  state.refresh_generation = (state.refresh_generation or 0) + 1
  local generation = state.refresh_generation

  vim.schedule(function()
    if views[view] then
      M.refresh(view)
    end
  end)

  -- Some interactions (notably expanding a tree while opening a file) queue a
  -- second Diffview render after the first scheduler turn. Repaint once more
  -- after that queue settles, but coalesce bursts of panel updates.
  vim.defer_fn(function()
    if views[view] == state and state.refresh_generation == generation then
      M.refresh(view)
    end
  end, 25)
end

local function watch_panel_buffer(view)
  local state = state_for(view)
  local panel = view.panel
  local bufnr = panel and panel.bufid
  if not bufnr or not api.nvim_buf_is_valid(bufnr) or state.panel_bufnr == bufnr then
    return
  end

  -- Diffview sometimes rebuilds a panel asynchronously after selecting a file.
  -- Watching line changes covers those renders even when they do not flow
  -- through the wrapped panel:redraw method below.
  local attached = api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      schedule_refresh(view)
    end,
    on_detach = function()
      if views[view] == state and state.panel_bufnr == bufnr then
        state.panel_bufnr = nil
      end
    end,
  })
  if attached then
    state.panel_bufnr = bufnr
  end
end

local function attach(view)
  local state = state_for(view)
  if state.attached or not view.panel then
    return
  end
  state.attached = true

  -- There is no public panel-render event. Wrap the instance method, retaining
  -- Diffview's renderer and applying our signs only after it has rebuilt rows.
  local panel = view.panel
  local redraw = panel.redraw
  panel.redraw = function(self, ...)
    local result = { redraw(self, ...) }
    watch_panel_buffer(view)
    -- Apply synchronously first so tree fold/unfold never leaves a visible
    -- frame without markers; schedule_refresh also covers later async renders.
    M.refresh(view)
    schedule_refresh(view)
    return unpack(result)
  end

  if view.emitter then
    view.emitter:on("file_open_post", function()
      schedule_refresh(view)
    end)
  end
  watch_panel_buffer(view)
  schedule_refresh(view)
end

function M.toggle()
  local view = current_view()
  local file = current_file(view)
  if not file then
    return notify("no file selected", vim.log.levels.WARN)
  end

  local checked = state_for(view).checked
  if checked[file.path] then
    checked[file.path] = nil
    notify("unchecked " .. file.path)
  else
    checked[file.path] = true
    notify("checked " .. file.path)
  end
  M.refresh(view)
end

function M.setup()
  if M._setup then
    return
  end
  M._setup = true

  api.nvim_set_hl(0, "DiffviewCheckedFile", { link = "DiagnosticSignOk", default = true })

  local global = rawget(_G, "DiffviewGlobal")
  if not global or not global.emitter then
    return notify("checked-file markers unavailable: Diffview did not initialize", vim.log.levels.WARN)
  end

  global.emitter:on("view_opened", function(_, view)
    attach(view)
  end)
  global.emitter:on("view_closed", function(_, view)
    local state = views[view]
    if state and view.panel and view.panel.bufid and api.nvim_buf_is_valid(view.panel.bufid) then
      api.nvim_buf_clear_namespace(view.panel.bufid, ns, 0, -1)
    end
    views[view] = nil
  end)

  -- Also support reloading this module while a Diffview tab is already open.
  local ok, lib = pcall(require, "diffview.lib")
  if ok then
    for _, view in ipairs(lib.views or {}) do
      attach(view)
    end
  end
end

return M
