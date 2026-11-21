-- Active key mappings for the current Direct listing.
local M = {}

local function active_mappings()
  local config = require('direct.config')
  local entries_by_lhs = {}

  local function add(entry)
    local lhs = config.mapping_lhs(entry.action, entry.lhs)
    if not lhs then return end

    local description = entry.description or entry.desc or entry.action:gsub('_', ' ')
    description = description:gsub('^direct:%s*', '')
    -- Installation order matters if two configured actions reuse the same key:
    -- later buffer mappings, then folding mappings, replace the earlier one.
    entries_by_lhs[(entry.mode or 'n') .. '\0' .. lhs] = {
      action = entry.action,
      lhs = lhs,
      mode = entry.mode or 'n',
      description = description,
      source = type(config.options.mappings[entry.action]) == 'string' and 'custom' or 'default',
    }
  end

  -- Only buffer-local entries are visible inside a Direct listing. In
  -- particular, its `-` is parent navigation, not GLOBAL_MAP's list_buffer.
  for _, entry in ipairs(config.BUFFER_MAPS) do
    add(entry)
  end
  for _, entry in ipairs(require('direct.folding').KEY_MAPS) do
    add(entry)
  end
  for _, entry in ipairs(require('direct.config.mappings').custom_mappings(config)) do
    entries_by_lhs['n\0' .. entry.lhs] = {
      action = 'custom:' .. entry.lhs,
      lhs = entry.lhs,
      mode = 'n',
      description = 'Custom function',
      source = 'custom',
    }
  end

  local entries = {}
  for _, entry in pairs(entries_by_lhs) do
    entries[#entries + 1] = entry
  end
  local mode_order = { n = 1, v = 2 }
  table.sort(entries, function(a, b)
    local a_mode, b_mode = mode_order[a.mode] or 3, mode_order[b.mode] or 3
    if a_mode ~= b_mode then return a_mode < b_mode end
    if a.lhs ~= b.lhs then return a.lhs < b.lhs end
    return a.action < b.action
  end)
  return entries
end

local function pad(value, width) return value .. string.rep(' ', math.max(0, width - vim.fn.strdisplaywidth(value))) end

function M.lines()
  local entries = active_mappings()
  local key_width = 0
  for _, entry in ipairs(entries) do
    key_width = math.max(key_width, vim.fn.strdisplaywidth(entry.lhs))
  end

  local lines = {
    'Direct key mappings',
    'Custom keys override defaults; disabled mappings are omitted.',
    'Press q or <Esc> to close.',
    '',
    'Mode    Key' .. string.rep(' ', math.max(1, key_width - 3)) .. '  Action',
    string.rep('-', 7 + key_width + 2 + 36),
  }
  for _, entry in ipairs(entries) do
    local mode = entry.mode == 'v' and 'Visual' or entry.mode == 'n' and 'Normal' or entry.mode
    lines[#lines + 1] =
      string.format('%s  %s  %-8s  %s', pad(mode, 6), pad(entry.lhs, key_width), entry.source, entry.description)
  end
  return lines
end

function M.show()
  local lines = M.lines()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].filetype = 'direct-key-help'

  local max_width = math.max(1, vim.o.columns - 4)
  local content_width = 0
  for _, line in ipairs(lines) do
    content_width = math.max(content_width, vim.fn.strdisplaywidth(line))
  end
  local width = math.min(content_width, max_width)
  local height = math.max(1, math.min(#lines, vim.o.lines - vim.o.cmdheight - 4))
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = 'minimal',
    border = 'rounded',
    title = ' Direct key help ',
    title_pos = 'center',
    focusable = true,
  })
  vim.wo[winid].wrap = true

  local function close()
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    elseif vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
  for _, lhs in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', lhs, close, {
      buffer = bufnr,
      silent = true,
      desc = 'direct: close key help',
    })
  end
  return bufnr, winid
end

return M
