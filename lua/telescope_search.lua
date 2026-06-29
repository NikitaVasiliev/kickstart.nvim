-- Telescope search helpers:
--   * live_grep with a <C-f> toggle for literal (ripgrep --fixed-strings) search
--   * two-step "pick a directory, then grep / find files under it" flows
local M = {}

-- Live grep with an in-picker literal toggle.
-- <C-f> (insert + normal) flips ripgrep --fixed-strings on/off, preserving the
-- typed query and showing "[literal]" in the title. Accepts pass-through opts
-- such as `cwd` and a base `prompt_title`.
function M.live_grep(opts)
  opts = opts or {}
  local builtin = require("telescope.builtin")
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local base_title = opts.prompt_title or "Live Grep"

  local function open(default_text, fixed)
    local merged = vim.tbl_extend("force", opts, {
      default_text = default_text,
      additional_args = fixed and { "--fixed-strings" } or {},
      prompt_title = base_title .. (fixed and " [literal]" or ""),
      attach_mappings = function(prompt_bufnr, map)
        local function toggle()
          local line = action_state.get_current_line()
          actions.close(prompt_bufnr)
          open(line, not fixed)
        end
        map("i", "<C-f>", toggle)
        map("n", "<C-f>", toggle)
        return true
      end,
    })
    builtin.live_grep(merged)
  end

  open("", false)
end

-- Open a directory picker (matching the <leader>fd convention) and call
-- cb(absolute_dir) with the selected directory.
function M.pick_dir(cb)
  local builtin = require("telescope.builtin")
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  builtin.find_files({
    prompt_title = "Select directory",
    find_command = { "find", ".", "-type", "d" },
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if not entry then
          return
        end
        local dir = vim.fn.fnamemodify(entry.path or entry.value, ":p")
        cb(dir)
      end)
      return true
    end,
  })
end

-- Pick a directory, then live grep (with literal toggle) under it.
function M.grep_in_dir()
  M.pick_dir(function(dir)
    M.live_grep({ cwd = dir, prompt_title = "Grep in " .. vim.fn.fnamemodify(dir, ":~") })
  end)
end

-- Pick a directory, then find files under it.
function M.find_files_in_dir()
  M.pick_dir(function(dir)
    require("telescope.builtin").find_files({
      cwd = dir,
      prompt_title = "Files in " .. vim.fn.fnamemodify(dir, ":~"),
    })
  end)
end

return M
