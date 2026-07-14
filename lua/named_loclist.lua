_G.NamedLoclists = _G.NamedLoclists or {}

local M = {}
local loclist_context = require("loclist_context")

function M.add_current()
  local item = loclist_context.extend_item({
    bufnr = vim.api.nvim_get_current_buf(),
    lnum = vim.fn.line("."),
    col = vim.fn.col("."),
    text = vim.fn.getline("."),
  })

  vim.fn.setloclist(0, {}, "a", {
    items = { item },
    quickfixtextfunc = loclist_context.quickfixtextfunc,
  })
end

function M.save(name)
  if not name or name == "" then
    return
  end

  local data = vim.fn.getloclist(0, { all = 1 })
  if not data.items or #data.items == 0 then
    vim.notify("Loclist empty", vim.log.levels.INFO)
    return
  end

  _G.NamedLoclists[name] = {
    items = data.items,
    title = data.title or name,
  }

  vim.notify("Saved loclist: " .. name, vim.log.levels.INFO)
end

function M.restore(name)
  local saved = _G.NamedLoclists[name]
  if not saved then
    vim.notify("No such loclist: " .. name, vim.log.levels.WARN)
    return
  end

  vim.fn.setloclist(0, {}, "r", {
    items = saved.items,
    quickfixtextfunc = loclist_context.quickfixtextfunc,
    title = saved.title,
  })

  vim.cmd("lopen")
end

function M.telescope_switch()
  local names = vim.tbl_keys(_G.NamedLoclists)

  require("telescope.pickers")
    .new({}, {
      prompt_title = "Named Loclists",
      finder = require("telescope.finders").new_table({
        results = names,
      }),
      sorter = require("telescope.config").values.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        require("telescope.actions").select_default:replace(function()
          require("telescope.actions").close(prompt_bufnr)
          local selection = require("telescope.actions.state").get_selected_entry()
          M.restore(selection[1])
        end)
        return true
      end,
    })
    :find()
end

return M
