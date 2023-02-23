local cache = require("oil.cache")
local columns = require("oil.columns")
local fs = require("oil.fs")
local util = require("oil.util")
local view = require("oil.view")
local FIELD = require("oil.constants").FIELD
local M = {}

---@alias oil.Diff oil.DiffNew|oil.DiffDelete|oil.DiffChange

---@class oil.DiffNew
---@field type "new"
---@field name string
---@field entry_type oil.EntryType
---@field id nil|integer
---@field link nil|string

---@class oil.DiffDelete
---@field type "delete"
---@field name string
---@field id integer
---
---@class oil.DiffChange
---@field type "change"
---@field entry_type oil.EntryType
---@field name string
---@field column string
---@field value any

---@param name string
---@return string
---@return boolean
local function parsedir(name)
  local isdir = vim.endswith(name, "/")
  if isdir then
    name = name:sub(1, name:len() - 1)
  end
  return name, isdir
end

---Parse a single line in a buffer
---@param adapter oil.Adapter
---@param line string
---@param column_defs oil.ColumnSpec[]
---@return nil|table Parsed entry data
---@return nil|oil.InternalEntry If the entry already exists
---@return nil|string Error message
M.parse_line = function(adapter, line, column_defs)
  local ret = {}
  local value, rem = line:match("^/(%d+) (.+)$")
  if not value then
    return nil, nil, "Malformed ID at start of line"
  end
  ret.id = tonumber(value)
  for _, def in ipairs(column_defs) do
    local name = util.split_config(def)
    value, rem = columns.parse_col(adapter, rem, def)
    if not value then
      return nil, nil, string.format("Parsing %s failed", name)
    end
    ret[name] = value
  end
  local name = rem
  if name then
    local isdir
    name, isdir = parsedir(vim.trim(name))
    if name ~= "" then
      ret.name = name
    end
    ret._type = isdir and "directory" or "file"
  end
  local entry = cache.get_entry_by_id(ret.id)
  if not entry then
    return ret
  end

  -- Parse the symlink syntax
  local meta = entry[FIELD.meta]
  local entry_type = entry[FIELD.type]
  if entry_type == "link" and meta and meta.link then
    local name_pieces = vim.split(ret.name, " -> ", { plain = true })
    if #name_pieces ~= 2 then
      ret.name = ""
      return ret
    end
    ret.name = parsedir(vim.trim(name_pieces[1]))
    ret.link_target = name_pieces[2]
    ret._type = "link"
  end

  -- Try to keep the same file type
  if entry_type ~= "directory" and entry_type ~= "file" and ret._type ~= "directory" then
    ret._type = entry[FIELD.type]
  end

  return ret, entry
end

---@param bufnr integer
---@return oil.Diff[]
---@return table[] Parsing errors
M.parse = function(bufnr)
  local diffs = {}
  local errors = {}
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local adapter = util.get_adapter(bufnr)
  if not adapter then
    table.insert(errors, {
      lnum = 0,
      col = 0,
      message = string.format("Cannot parse buffer '%s': No adapter", bufname),
    })
    return diffs, errors
  end
  local scheme, path = util.parse_url(bufname)
  local column_defs = columns.get_supported_columns(scheme)
  local parent_url = scheme .. path
  local children = cache.list_url(parent_url)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
  local original_entries = {}
  for _, child in pairs(children) do
    if view.should_display(child, bufnr) then
      original_entries[child[FIELD.name]] = child[FIELD.id]
    end
  end
  local seen_names = {}
  local function check_dupe(name, i)
    if fs.is_mac or fs.is_windows then
      -- mac and windows use case-insensitive filesystems
      name = name:lower()
    end
    if seen_names[name] then
      table.insert(errors, { message = "Duplicate filename", lnum = i - 1, col = 0 })
    else
      seen_names[name] = true
    end
  end
  for i, line in ipairs(lines) do
    if line:match("^/%d+") then
      local parsed_entry, entry, err = M.parse_line(adapter, line, column_defs)
      if not parsed_entry then
        table.insert(errors, {
          message = err,
          lnum = i - 1,
          col = 0,
        })
        goto continue
      end
      if not parsed_entry.name or parsed_entry.name:match("/") or not entry then
        local message
        if not parsed_entry.name then
          message = "No filename found"
        elseif not entry then
          message = "Could not find existing entry (was the ID changed?)"
        else
          message = "Filename cannot contain '/'"
        end
        table.insert(errors, {
          message = message,
          lnum = i - 1,
          col = 0,
        })
        goto continue
      end
      check_dupe(parsed_entry.name, i)
      local meta = entry[FIELD.meta]
      if original_entries[parsed_entry.name] == parsed_entry.id then
        if entry[FIELD.type] == "link" and (not meta or meta.link ~= parsed_entry.link_target) then
          table.insert(diffs, {
            type = "new",
            name = parsed_entry.name,
            entry_type = "link",
            link = parsed_entry.link_target,
          })
        else
          original_entries[parsed_entry.name] = nil
        end
      else
        table.insert(diffs, {
          type = "new",
          name = parsed_entry.name,
          entry_type = parsed_entry._type,
          id = parsed_entry.id,
          link = parsed_entry.link_target,
        })
      end

      for _, col_def in ipairs(column_defs) do
        local col_name = util.split_config(col_def)
        if columns.compare(adapter, col_name, entry, parsed_entry[col_name]) then
          table.insert(diffs, {
            type = "change",
            name = parsed_entry.name,
            entry_type = entry[FIELD.type],
            column = col_name,
            value = parsed_entry[col_name],
          })
        end
      end
    else
      local name, isdir = parsedir(vim.trim(line))
      if vim.startswith(name, "/") then
        table.insert(errors, {
          message = "Paths cannot start with '/'",
          lnum = i - 1,
          col = 0,
        })
        goto continue
      end
      if name ~= "" then
        local link_pieces = vim.split(name, " -> ", { plain = true })
        local entry_type = isdir and "directory" or "file"
        local link
        if #link_pieces == 2 then
          entry_type = "link"
          name, link = unpack(link_pieces)
        end
        check_dupe(name, i)
        table.insert(diffs, {
          type = "new",
          name = name,
          entry_type = entry_type,
          link = link,
        })
      end
    end
    ::continue::
  end

  for name, child_id in pairs(original_entries) do
    table.insert(diffs, {
      type = "delete",
      name = name,
      id = child_id,
    })
  end

  return diffs, errors
end

return M
