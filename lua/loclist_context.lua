local M = {}
M.quickfixtextfunc = "v:lua.LoclistContextQuickfixTextFunc"

local function node_text(bufnr, node)
  local ok, text = pcall(vim.treesitter.get_node_text, node, bufnr)
  if not ok or not text then
    return nil
  end

  text = vim.trim(text:gsub("%s+", " "))
  if text == "" or #text > 120 then
    return nil
  end

  return text
end

local function first_field_text(bufnr, node, fields)
  for _, field in ipairs(fields) do
    local ok, nodes = pcall(node.field, node, field)
    if ok and nodes then
      for _, child in ipairs(nodes) do
        local text = node_text(bufnr, child)
        if text then
          return text
        end
      end
    end
  end
end

local function identifier_text(bufnr, node)
  local type = node:type()
  if type == "identifier" or type == "field_identifier" or type == "property_identifier" then
    return node_text(bufnr, node)
  end

  local ok, named_children = pcall(node.named_child_count, node)
  if not ok then
    return nil
  end

  for i = 0, named_children - 1 do
    local name = identifier_text(bufnr, node:named_child(i))
    if name then
      return name
    end
  end
end

local function is_function_like(node)
  local type = node:type()
  return type == "function_declaration"
    or type == "function_definition"
    or type == "function_statement"
    or type == "local_function"
    or type == "function_item"
    or type == "function_expression"
    or type == "function_literal"
    or type == "arrow_function"
    or type == "lambda"
    or type == "lambda_expression"
    or type == "method"
    or type == "method_declaration"
    or type == "method_definition"
    or type == "constructor_declaration"
    or type == "closure_expression"
end

local function function_name(bufnr, node)
  local name = first_field_text(bufnr, node, { "name" })
  if name then
    return name
  end

  local ok, declarators = pcall(node.field, node, "declarator")
  if ok and declarators then
    for _, declarator in ipairs(declarators) do
      name = identifier_text(bufnr, declarator)
      if name then
        return name
      end
    end
  end

  local parent = node:parent()
  if parent then
    name = first_field_text(bufnr, parent, { "name", "left" })
    if name then
      return name
    end
  end
end

local function loaded_bufnr(item, opts)
  if item.bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end

  if item.bufnr and item.bufnr > 0 and vim.api.nvim_buf_is_valid(item.bufnr) then
    if opts.load and not vim.api.nvim_buf_is_loaded(item.bufnr) then
      vim.fn.bufload(item.bufnr)
    end
    return item.bufnr
  end

  if item.filename and item.filename ~= "" then
    local bufnr = vim.fn.bufnr(item.filename)
    if bufnr < 0 and opts.load then
      bufnr = vim.fn.bufadd(item.filename)
    end

    if bufnr > 0 and opts.load and not vim.api.nvim_buf_is_loaded(bufnr) then
      vim.fn.bufload(bufnr)
    end

    if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then
      return bufnr
    end
  end
end

local function ensure_filetype(bufnr)
  if vim.bo[bufnr].filetype ~= "" then
    return
  end

  local ok, filetype = pcall(vim.filetype.match, {
    buf = bufnr,
    filename = vim.api.nvim_buf_get_name(bufnr),
  })

  if ok and filetype and filetype ~= "" then
    vim.bo[bufnr].filetype = filetype
  end
end

function M.enclosing_function_name(item, opts)
  opts = opts or {}
  local bufnr = loaded_bufnr(item, opts)
  if not bufnr then
    return nil
  end

  ensure_filetype(bufnr)

  local row = math.max((item.lnum or 1) - 1, 0)
  local col = math.max((item.col or 1) - 1, 0)
  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok_parser or not parser then
    return nil
  end
  pcall(parser.parse, parser)

  local ok, node = pcall(vim.treesitter.get_node, {
    bufnr = bufnr,
    pos = { row, col },
    ignore_injections = false,
  })

  if not ok or not node then
    return nil
  end

  while node do
    if is_function_like(node) then
      return function_name(bufnr, node)
    end
    node = node:parent()
  end
end

function M.extend_item(item, opts)
  local name = M.enclosing_function_name(item, opts)
  if not name then
    return item
  end

  local user_data = type(item.user_data) == "table" and vim.deepcopy(item.user_data) or {}
  local text = user_data.loclist_context_original_text
    or (type(item.text) == "string" and item.text or vim.inspect(item.text))
  item.text = text
  user_data.loclist_context_name = name
  user_data.loclist_context_original_text = text
  item.user_data = user_data

  return item
end

function M.extend_items(items, opts)
  local extended = {}
  for _, item in ipairs(items or {}) do
    table.insert(extended, M.extend_item(vim.deepcopy(item), opts))
  end
  return extended
end

function M.refresh(win, opts)
  win = win or 0
  opts = opts or {}

  local data = vim.fn.getloclist(win, { idx = 0, items = 0, title = 0 })
  if not data.items or #data.items == 0 then
    return
  end

  vim.fn.setloclist(win, {}, "r", {
    idx = data.idx,
    items = M.extend_items(data.items, opts),
    quickfixtextfunc = M.quickfixtextfunc,
    title = data.title,
  })
end

local function truncate(value, width)
  if #value <= width then
    return value
  end
  return value:sub(1, width - 3) .. "..."
end

local function item_filename(item)
  local filename = item.filename
  if (not filename or filename == "") and item.bufnr and item.bufnr > 0 then
    filename = vim.fn.bufname(item.bufnr)
  end

  if not filename or filename == "" then
    return ""
  end

  return vim.fn.fnamemodify(filename, ":.")
end

local function item_text(item)
  local user_data = type(item.user_data) == "table" and item.user_data or {}
  if user_data.loclist_context_original_text then
    return user_data.loclist_context_original_text
  end
  return type(item.text) == "string" and item.text or vim.inspect(item.text)
end

function M.quickfix_text(info)
  local data
  if info.quickfix == 1 then
    data = vim.fn.getqflist({ id = info.id, items = 0 })
  else
    data = vim.fn.getloclist(info.winid, { id = info.id, items = 0 })
  end

  local items = data.items or {}
  local lines = {}
  local function_width = 28

  for idx = info.start_idx, info.end_idx do
    local item = items[idx]
    if item then
      local user_data = type(item.user_data) == "table" and item.user_data or {}
      local name = truncate(user_data.loclist_context_name or "", function_width)
      local location = item.lnum and item.lnum > 0 and string.format("%d col %d", item.lnum, item.col or 0) or ""

      table.insert(
        lines,
        string.format(
          "%s|%s| " .. "%-" .. function_width .. "s" .. " | %s",
          item_filename(item),
          location,
          name,
          item_text(item)
        )
      )
    end
  end

  return lines
end

_G.LoclistContextQuickfixTextFunc = function(info)
  return require("loclist_context").quickfix_text(info)
end

return M
