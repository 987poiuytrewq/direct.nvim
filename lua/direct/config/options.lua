-- Configuration defaults and validation.
local M = {}

local platform = require('direct.platform')

---@class direct.Icons
---@field file? string
---@field folder? string
---@field folder_open? string
---@field deleted_file? string
---@field deleted_folder? string
---@field deleted_folder_open? string
---@field provider? 'auto'|'mini'|'devicons'|false|fun(name: string, type: string): string?, string?

---@class direct.TrashRetention
---@field max_age_days? integer
---@field max_size_bytes? integer

---@alias direct.GitSymbolName 'added'|'deleted'|'modified'|'renamed'|'ignored'|'staged'|'conflict'

---@class direct.GitSymbols
---@field added? string
---@field deleted? string
---@field modified? string
---@field renamed? string
---@field ignored? string
---@field staged? string
---@field conflict? string

---@class direct.GitConfig
---@field enabled? boolean
---@field timeout_ms? integer Deadline for the background Git status query.
---@field ignore_timeout_ms? integer Deadline for Git-ignore queries.
---@field show_symbols? boolean
---@field show_deleted? boolean
---@field symbols? table<direct.GitSymbolName, string>

---@class direct.BufferConfig
---@field reuse? boolean Reuse an existing Direct listing for the same directory.
---@field open_in? 'current'|'new' Open targets in the current buffer or preserve the source buffer.

---@class direct.ListEntry
---@field name string
---@field type string

---@alias direct.SortComparator fun(a: direct.ListEntry, b: direct.ListEntry): boolean

---@class direct.Entry
---@field path string Absolute path represented by this listing row.
---@field name string Entry name without the trailing directory marker.
---@field type 'file'|'directory'
---@field root string Absolute root of the current listing.
---@field deleted boolean Whether this is a Git-deleted, view-only row.

---@alias direct.CustomAction fun(entry: direct.Entry)

---@class direct.Config
---@field map_default_keys? boolean
---@field directory_separator? '/'|'\\'
---@field sort? 'name'|'natural'|direct.SortComparator
---@field sort_directories_first? boolean
---@field is_hidden? fun(name: string, path: string, type: string): boolean|nil
---@field show_hidden? boolean
---@field respect_gitignore? boolean
---@field collapse_single_entry_directories? boolean
---@field indent_size? integer
---@field undo_confirm? boolean|'elsewhere'
---@field history_limit? integer
---@field trash_retention? false|direct.TrashRetention
---@field mappings? table<string, string|false|direct.CustomAction>
---@field show_folder_icons? boolean
---@field show_file_icons? boolean
---@field show_filetype_icons? boolean
---@field color_file_icons? boolean
---@field icons? direct.Icons
---@field max_recursive_expand_depth? false|integer
---@field git? direct.GitConfig
---@field buffers? direct.BufferConfig

---@type direct.Config
local defaults = {
  map_default_keys = true,
  directory_separator = platform.separator,
  sort = 'name',
  sort_directories_first = true,
  show_hidden = true,
  respect_gitignore = true,
  collapse_single_entry_directories = true,
  indent_size = 2,
  undo_confirm = 'elsewhere',
  history_limit = 1000,
  trash_retention = { max_age_days = 90 },
  mappings = {},
  show_folder_icons = true,
  show_file_icons = true,
  show_filetype_icons = true,
  color_file_icons = true,
  icons = {
    file = '\u{f15b}',
    folder = '\u{f07b}',
    folder_open = '\u{f07c}',
    deleted_file = '\u{f016}',
    deleted_folder = '\u{f114}',
    deleted_folder_open = '\u{f115}',
    provider = 'auto',
  },
  max_recursive_expand_depth = false,
  buffers = {
    reuse = true,
    open_in = 'current',
  },
  git = {
    enabled = true,
    timeout_ms = 1000,
    ignore_timeout_ms = 200,
    show_symbols = true,
    show_deleted = true,
    symbols = {
      added = '\u{f067}',
      deleted = '\u{f068}',
      modified = '\u{f01f}',
      renamed = '\u{f061}',
      ignored = '\u{f070}',
      staged = '\u{f00c}',
      conflict = '\u{f00d}',
    },
  },
}

M.defaults = defaults

local function sorted_keys(value)
  local keys = {}
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

local function error_list(message) return { message } end

local function resolve_buffer_options(value)
  local errors = {}
  if type(value) ~= 'table' then
    errors[#errors + 1] = 'direct: invalid buffers: expected a table'
    return vim.deepcopy(defaults.buffers), errors
  end
  local result = vim.deepcopy(defaults.buffers)
  for _, key in ipairs(sorted_keys(value)) do
    local option = value[key]
    if key == 'reuse' then
      if type(option) == 'boolean' then
        result.reuse = option
      else
        errors[#errors + 1] = 'direct: invalid buffers.reuse: expected a boolean'
      end
    elseif key == 'open_in' then
      if option == 'current' or option == 'new' then
        result.open_in = option
      else
        errors[#errors + 1] = "direct: invalid buffers.open_in: expected 'current' or 'new'"
      end
    else
      errors[#errors + 1] = 'direct: invalid buffers.' .. tostring(key) .. ': unknown setting'
    end
  end
  return result, errors
end

local icon_variants = {
  file = true,
  folder = true,
  folder_open = true,
  deleted_file = true,
  deleted_folder = true,
  deleted_folder_open = true,
}

local function resolve_icon_options(value)
  local errors = {}
  local function report_invalid_icon_option(key, reason)
    local option = key == '' and 'icons' or ('icons.' .. key)
    errors[#errors + 1] = string.format('direct: invalid %s: %s', option, reason)
  end

  if type(value) ~= 'table' then
    report_invalid_icon_option('', 'expected a table')
    return vim.deepcopy(defaults.icons), errors
  end

  local result = vim.deepcopy(defaults.icons)
  for _, key in ipairs(sorted_keys(value)) do
    local option = value[key]
    if key == 'provider' then
      if
        option == 'auto'
        or option == 'mini'
        or option == 'devicons'
        or option == false
        or type(option) == 'function'
      then
        result.provider = option
      else
        report_invalid_icon_option(key, "expected 'auto', 'mini', 'devicons', false, or a function")
      end
    elseif not icon_variants[key] then
      report_invalid_icon_option(
        tostring(key),
        'unknown icon; expected file, folder, folder_open, deleted_file, deleted_folder, or deleted_folder_open'
      )
    elseif type(option) ~= 'string' or option == '' then
      report_invalid_icon_option(key, 'expected a non-empty glyph string')
    else
      result[key] = option
    end
  end
  return result, errors
end

local function resolve_git_options(value)
  local errors = {}
  local function report_invalid_git_option(key, reason)
    errors[#errors + 1] = string.format('direct: invalid git.%s: %s', key, reason)
  end

  if type(value) ~= 'table' then
    report_invalid_git_option('', 'expected a table')
    return vim.deepcopy(defaults.git), errors
  end

  local result = vim.deepcopy(defaults.git)
  for _, key in ipairs(sorted_keys(value)) do
    local option = value[key]
    if key == 'enabled' then
      if type(option) == 'boolean' then
        result.enabled = option
      else
        report_invalid_git_option(key, 'expected a boolean')
      end
    elseif key == 'timeout_ms' then
      if type(option) == 'number' and option >= 1 and option % 1 == 0 then
        result.timeout_ms = option
      else
        report_invalid_git_option(key, 'expected a positive integer')
      end
    elseif key == 'ignore_timeout_ms' then
      if type(option) == 'number' and option >= 1 and option % 1 == 0 then
        result.ignore_timeout_ms = option
      else
        report_invalid_git_option(key, 'expected a positive integer')
      end
    elseif key == 'show_symbols' then
      if type(option) == 'boolean' then
        result.show_symbols = option
      else
        report_invalid_git_option(key, 'expected a boolean')
      end
    elseif key == 'show_deleted' then
      if type(option) == 'boolean' then
        result.show_deleted = option
      else
        report_invalid_git_option(key, 'expected a boolean')
      end
    elseif key == 'symbols' then
      if type(option) ~= 'table' then
        report_invalid_git_option(key, 'expected a table')
      else
        for _, status in ipairs(sorted_keys(option)) do
          local symbol = option[status]
          if result.symbols[status] == nil then
            report_invalid_git_option('symbols.' .. tostring(status), 'unknown status symbol')
          elseif type(symbol) ~= 'string' or vim.fn.strdisplaywidth(symbol) > 1 then
            report_invalid_git_option('symbols.' .. status, 'expected an empty string or one display cell')
          else
            result.symbols[status] = symbol
          end
        end
      end
    else
      report_invalid_git_option(tostring(key), 'unknown setting')
    end
  end
  return result, errors
end

local function resolve_trash_retention(value)
  local errors = {}
  if value == false then return false, errors end
  if type(value) ~= 'table' then
    errors[#errors + 1] = 'direct: trash_retention must be false or a table with max_age_days and/or max_size_bytes'
    return false, errors
  end
  local result = {}
  for _, key in ipairs(sorted_keys(value)) do
    local limit = value[key]
    if
      (key ~= 'max_age_days' and key ~= 'max_size_bytes')
      or type(limit) ~= 'number'
      or limit < 1
      or limit % 1 ~= 0
    then
      errors[#errors + 1] =
        'direct: trash_retention limits must be positive integers named max_age_days or max_size_bytes'
    else
      result[key] = limit
    end
  end
  if next(result) == nil then
    errors[#errors + 1] = 'direct: trash_retention needs a valid max_age_days or max_size_bytes limit'
    return false, errors
  end
  return result, errors
end

local function resolve_mappings(value, mapping_catalog)
  local errors = {}
  if type(value) ~= 'table' then
    errors[#errors + 1] = 'direct: mappings must be a table'
    return {}, errors
  end
  local known = type(mapping_catalog) == 'function' and mapping_catalog() or mapping_catalog or {}
  local result = {}
  for _, action in ipairs(sorted_keys(value)) do
    local key = value[action]
    if type(action) == 'string' and action ~= '' and known[action] then
      if key == false or (type(key) == 'string' and key ~= '') then
        result[action] = key
      else
        errors[#errors + 1] = 'direct: mappings.' .. action .. ' must be a non-empty key or false'
      end
    elseif type(action) == 'string' and action ~= '' and type(key) == 'function' then
      result[action] = key
    else
      errors[#errors + 1] = 'direct: unknown mapping action ' .. tostring(action)
    end
  end
  return result, errors
end

local function boolean_rule(key)
  return function(value)
    if type(value) == 'boolean' then return value end
    return nil, error_list(string.format('direct: %s must be a boolean', key))
  end
end

local function positive_integer_rule(message)
  return function(value)
    if type(value) == 'number' and value >= 1 and value % 1 == 0 then return value end
    return nil, error_list('direct: ' .. message)
  end
end

local function passthrough(value) return value end

local option_schema = {
  -- These options historically passed through unchanged; keep their existing
  -- semantics while still declaring them in the option table.
  { key = 'map_default_keys', default = defaults.map_default_keys, validate = passthrough },
  {
    key = 'directory_separator',
    default = defaults.directory_separator,
    type = "'/' or '\\'",
    validate = function(value)
      if value == '/' or value == '\\' then return value end
      return nil, error_list('direct: directory_separator must be "/" or "\\\\"')
    end,
  },
  {
    key = 'sort',
    default = defaults.sort,
    type = "'name', 'natural', or a comparator function",
    validate = function(value)
      if value == 'name' or value == 'natural' or type(value) == 'function' then return value end
      return nil, error_list("direct: sort must be 'name', 'natural', or a comparator function")
    end,
  },
  {
    key = 'sort_directories_first',
    default = defaults.sort_directories_first,
    validate = boolean_rule('sort_directories_first'),
  },
  {
    key = 'is_hidden',
    default = defaults.is_hidden,
    type = 'function',
    validate = function(value)
      if type(value) == 'function' then return value end
      return nil, error_list('direct: is_hidden must be a function')
    end,
  },
  { key = 'show_hidden', default = defaults.show_hidden, validate = boolean_rule('show_hidden') },
  { key = 'respect_gitignore', default = defaults.respect_gitignore, validate = boolean_rule('respect_gitignore') },
  {
    key = 'collapse_single_entry_directories',
    default = defaults.collapse_single_entry_directories,
    validate = boolean_rule('collapse_single_entry_directories'),
  },
  {
    key = 'indent_size',
    default = defaults.indent_size,
    type = 'integer > 1',
    validate = function(value)
      if type(value) == 'number' and value > 1 and value % 1 == 0 then return value end
      return nil, error_list('direct: indent_size must be an integer greater than 1')
    end,
  },
  {
    key = 'undo_confirm',
    default = defaults.undo_confirm,
    type = "true, false, or 'elsewhere'",
    validate = function(value)
      if value == false or value == true or value == 'elsewhere' then return value end
      return nil, error_list("direct: undo_confirm must be true, false, or 'elsewhere'")
    end,
  },
  {
    key = 'history_limit',
    default = defaults.history_limit,
    validate = positive_integer_rule('history_limit must be a positive integer'),
  },
  {
    key = 'trash_retention',
    default = defaults.trash_retention,
    type = 'false or table',
    validate = resolve_trash_retention,
  },
  {
    key = 'mappings',
    default = defaults.mappings,
    type = 'table',
    validate = resolve_mappings,
  },
  { key = 'show_folder_icons', default = defaults.show_folder_icons, validate = passthrough },
  { key = 'show_file_icons', default = defaults.show_file_icons, validate = passthrough },
  {
    key = 'show_filetype_icons',
    default = defaults.show_filetype_icons,
    validate = boolean_rule('show_filetype_icons'),
  },
  {
    key = 'color_file_icons',
    default = defaults.color_file_icons,
    validate = boolean_rule('color_file_icons'),
  },
  { key = 'icons', default = defaults.icons, type = 'table', validate = resolve_icon_options },
  {
    key = 'max_recursive_expand_depth',
    default = defaults.max_recursive_expand_depth,
    type = 'false or positive integer',
    validate = function(value)
      if value == false or (type(value) == 'number' and value >= 1 and value % 1 == 0) then return value end
      return nil, error_list('direct: max_recursive_expand_depth must be false or a positive integer')
    end,
  },
  { key = 'buffers', default = defaults.buffers, type = 'table', validate = resolve_buffer_options },
  { key = 'git', default = defaults.git, type = 'table', validate = resolve_git_options },
}

local known_options = {}
for _, spec in ipairs(option_schema) do
  known_options[spec.key] = true
end

---@param opts direct.Config|nil
---@param mapping_catalog fun(): table<string, boolean>
---@return direct.Config options
---@return string[] errors
function M.resolve(opts, mapping_catalog)
  opts = opts or {}
  local resolved, errors = vim.deepcopy(defaults), {}
  for _, spec in ipairs(option_schema) do
    local value = opts[spec.key]
    if value ~= nil then
      local option, option_errors = spec.validate(value, mapping_catalog)
      for _, message in ipairs(option_errors or {}) do
        errors[#errors + 1] = message
      end
      if option ~= nil then resolved[spec.key] = option end
    end
  end
  local unknown = {}
  for key in pairs(opts) do
    if not known_options[key] then unknown[#unknown + 1] = key end
  end
  table.sort(unknown, function(a, b) return tostring(a) < tostring(b) end)
  for _, key in ipairs(unknown) do
    errors[#errors + 1] = string.format("direct: unknown option '%s'", tostring(key))
  end
  return resolved, errors
end

return M
