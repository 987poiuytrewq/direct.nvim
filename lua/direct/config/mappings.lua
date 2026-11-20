-- Global, buffer-local, and <Plug> mapping installation and ownership.
local M = {}

local constants = require('direct.constants')
local ui = require('direct.ui')

-- Global mapping: normal `-` opens the current buffer's directory.
M.GLOBAL_MAP = {
  action = 'list_buffer',
  mode = 'n',
  lhs = '-',
  rhs = ':<C-U>DirectListBuffer<CR>',
  desc = 'direct: list current buffer directory',
}

-- The buffer-local mappings for filetype=direct buffers are retrofitted when
-- setup changes options. Installed by ftplugin/direct.lua on buffer creation.
M.BUFFER_MAPS = {
  {
    action = 'open',
    mode = 'n',
    lhs = '<CR>',
    rhs = '<Cmd>lua require("direct").open()<CR>',
    description = 'Open the entry under the cursor',
  },
  {
    action = 'open_horizontal',
    mode = 'n',
    lhs = '<C-s>',
    rhs = '<Cmd>lua require("direct").open({ split = "horizontal" })<CR>',
    description = 'Open in a horizontal split',
  },
  {
    action = 'open_vertical',
    mode = 'n',
    lhs = '<C-v>',
    rhs = '<Cmd>lua require("direct").open({ split = "vertical" })<CR>',
    description = 'Open in a vertical split',
  },
  {
    action = 'open_tab',
    mode = 'n',
    lhs = '<C-t>',
    rhs = '<Cmd>lua require("direct").open({ split = "tab" })<CR>',
    description = 'Open in a new tab',
  },
  {
    action = 'list_buffer',
    mode = 'n',
    lhs = '-',
    rhs = '<Cmd>lua require("direct").list(vim.fn.fnamemodify('
      .. 'vim.b.direct_root or vim.api.nvim_buf_get_name(0), ":h"))<CR>',
    description = 'Go to the parent directory',
  },
  {
    action = 'show_help',
    mode = 'n',
    lhs = 'g?',
    rhs = '<Cmd>lua require("direct").show_help()<CR>',
    description = 'Show active key mappings',
  },
  {
    action = 'open_parent_expanded',
    mode = 'n',
    lhs = 'z-',
    rhs = '<Cmd>lua require("direct").open_parent_expanded()<CR>',
    description = 'Go to the parent and expand the directory you left',
  },
  { action = 'undo', mode = 'n', lhs = 'u', rhs = '<Cmd>DirectUndo<CR>', description = 'Undo the last change' },
  { action = 'redo', mode = 'n', lhs = '<C-r>', rhs = '<Cmd>DirectRedo<CR>', description = 'Redo the last change' },
  { action = 'yank', mode = 'n', lhs = 'yy', rhs = '<Cmd>DirectYank<CR>', description = 'Yank the current entry' },
  {
    action = 'yank_uppercase',
    mode = 'n',
    lhs = 'Y',
    rhs = '<Cmd>DirectYank<CR>',
    description = 'Yank the current entry',
  },
  -- Visual `y`: a ranged Ex command raises E20, so call Lua with the visual
  -- range directly; the public yank entry point normalises its order.
  {
    action = 'yank_visual',
    mode = 'v',
    lhs = 'y',
    rhs = '<Cmd>lua require("direct").yank(vim.fn.line("v"), vim.fn.line("."))<CR>',
    description = 'Yank the selected entries',
  },
  { action = 'paste', mode = 'n', lhs = 'p', rhs = '<Cmd>DirectPaste<CR>', description = 'Paste entries' },
  { action = 'paste_uppercase', mode = 'n', lhs = 'P', rhs = '<Cmd>DirectPaste<CR>', description = 'Paste entries' },
  {
    action = 'toggle_hidden',
    mode = 'n',
    lhs = 'gh',
    rhs = '<Cmd>DirectToggleHidden<CR>',
    description = 'Toggle hidden entries',
  },
  {
    action = 'toggle_gitignore',
    mode = 'n',
    lhs = 'gi',
    rhs = '<Cmd>DirectToggleGitIgnore<CR>',
    description = 'Toggle Git-ignore filtering',
  },
  {
    action = 'toggle_directory_collapse',
    mode = 'n',
    lhs = 'gC',
    rhs = '<Cmd>DirectToggleDirectoryCollapse<CR>',
    description = 'Toggle single-entry directory collapsing',
  },
  { action = 'git_add', mode = 'n', lhs = 'ga', rhs = '<Cmd>DirectGit git add -- {}<CR>', description = 'Stage entry' },
  {
    action = 'git_unstage',
    mode = 'n',
    lhs = '<leader>gu',
    rhs = '<Cmd>DirectGit git reset -- {}<CR>',
    description = 'Unstage entry',
  },
  {
    action = 'git_restore',
    mode = 'n',
    lhs = '<leader>gr',
    rhs = '<Cmd>DirectGitRestore<CR>',
    description = 'Restore entry from Git',
  },
  {
    action = 'toggle_git_status',
    mode = 'n',
    lhs = 'gs',
    rhs = '<Cmd>DirectToggleGitStatus<CR>',
    description = 'Toggle changed-files view',
  },
  {
    action = 'git_diff',
    mode = 'n',
    lhs = 'gd',
    rhs = '<Cmd>lua require("direct").git_diff()<CR>',
    description = 'Toggle Git diff view',
  },
  {
    action = 'next_change',
    mode = 'n',
    lhs = ']c',
    rhs = '<Cmd>DirectNextChange<CR>',
    description = 'Go to the next changed entry',
  },
  {
    action = 'previous_change',
    mode = 'n',
    lhs = '[c',
    rhs = '<Cmd>DirectPreviousChange<CR>',
    description = 'Go to the previous changed entry',
  },
  {
    action = 'next_file',
    mode = 'n',
    lhs = ']f',
    rhs = '<Cmd>DirectNextFile<CR>',
    description = 'Go to the next file',
  },
  {
    action = 'previous_file',
    mode = 'n',
    lhs = '[f',
    rhs = '<Cmd>DirectPreviousFile<CR>',
    description = 'Go to the previous file',
  },
}

function M.mapping_catalog(config)
  local result = { [config.GLOBAL_MAP.action] = true }
  for _, entry in ipairs(config.BUFFER_MAPS) do
    result[entry.action] = true
  end
  for _, entry in ipairs(require('direct.folding').KEY_MAPS) do
    result[entry.action] = true
  end
  return result
end

---@param config table
---@param action string
---@param default string
---@return string?
function M.mapping_lhs(config, action, default)
  local mapping = config.options.mappings and config.options.mappings[action]
  if mapping == false then return nil end
  if type(mapping) == 'string' then return mapping end
  return config.options.map_default_keys and default or nil
end

local function open_direct_buffers()
  local bufs = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == constants.FILETYPE then
      bufs[#bufs + 1] = bufnr
    end
  end
  return bufs
end

local function buffer_mapping_rhs(config)
  local rhs = {}
  for _, entry in ipairs(config.BUFFER_MAPS) do
    rhs[entry.rhs] = true
  end
  local folding = require('direct.folding')
  for _, entry in ipairs(folding.KEY_MAPS) do
    if entry.rhs then rhs[entry.rhs] = true end
  end
  for _, entry in ipairs(folding.MOUSE_MAPS) do
    if entry.rhs then rhs[entry.rhs] = true end
  end
  return rhs
end

local function plug_entries(config)
  local entries, seen = {}, {}
  local function add(action, mode, rhs)
    if seen[action] then return end
    seen[action] = true
    entries[#entries + 1] = {
      action = action,
      mode = mode or 'n',
      lhs = '<Plug>(direct-' .. action:gsub('_', '-') .. ')',
      rhs = rhs,
      desc = 'direct: Plug ' .. action,
    }
  end
  add(config.GLOBAL_MAP.action, config.GLOBAL_MAP.mode, config.GLOBAL_MAP.rhs)
  for _, entry in ipairs(config.BUFFER_MAPS) do
    add(entry.action, entry.mode, entry.rhs)
  end
  local folding = require('direct.folding')
  local buffer = require('direct.buffer.buffer')
  for _, entry in ipairs(folding.KEY_MAPS) do
    add(entry.action, 'n', folding.action_callback(entry.action, buffer))
  end
  return entries
end

local function clear_owned_buffer_maps(config, target)
  local rhs = buffer_mapping_rhs(config)
  for _, mode in ipairs({ 'n', 'v' }) do
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(target, mode)) do
      if rhs[map.rhs] then
        local ok, err = pcall(vim.keymap.del, mode, map.lhs, { buffer = target })
        if not ok then
          ui.notify(
            string.format('direct: cannot clear the %s mapping in buffer %d: %s', map.lhs, target, tostring(err)),
            vim.log.levels.WARN
          )
        end
      end
    end
  end
  require('direct.folding').clear_mappings(target)
end

-- Physical buffer mappings follow the `mappings` table; global <Plug> entry
-- points are installed separately.
function M.install_buffer_mappings(config, bufnr)
  local target = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  clear_owned_buffer_maps(config, target)
  for _, entry in ipairs(config.BUFFER_MAPS) do
    local lhs = M.mapping_lhs(config, entry.action, entry.lhs)
    if lhs then
      vim.keymap.set(entry.mode, lhs, entry.rhs, {
        buffer = target,
        silent = true,
        noremap = true,
      })
    end
  end
  require('direct.folding').install_mappings(target, require('direct.buffer.buffer'))
  return true
end

-- Removes only mappings with Direct-owned RHSs.
function M.clear_buffer_mappings(config, bufnr)
  local buffers
  if bufnr ~= nil then
    buffers = { bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr }
  else
    buffers = open_direct_buffers()
  end
  for _, target in ipairs(buffers) do
    -- The handle can go invalid between the snapshot above and this call (the
    -- buffer is unloaded in the meantime) and nvim_buf_call raises on an
    -- invalid buffer id. The buffer is going away anyway, so the failure is
    -- ignored rather than propagated.
    pcall(vim.api.nvim_buf_call, target, function() clear_owned_buffer_maps(config, target) end)
  end
  return true
end

local function clear_global_mapping(config)
  local owned_desc = { ['direct: list current buffer directory'] = true }
  for _, entry in ipairs(plug_entries(config)) do
    owned_desc[entry.desc] = true
  end
  for _, mode in ipairs({ 'n', 'v' }) do
    for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
      if owned_desc[map.desc] then pcall(vim.keymap.del, mode, map.lhs) end
    end
  end
  config._installed = false
end

function M.install_mappings(config)
  clear_global_mapping(config)
  local global_lhs = M.mapping_lhs(config, config.GLOBAL_MAP.action, config.GLOBAL_MAP.lhs)
  if global_lhs then
    vim.keymap.set(config.GLOBAL_MAP.mode, global_lhs, config.GLOBAL_MAP.rhs, {
      noremap = true,
      silent = true,
      desc = 'direct: list current buffer directory',
    })
    config._installed = true
  end
  for _, entry in ipairs(plug_entries(config)) do
    vim.keymap.set(entry.mode, entry.lhs, entry.rhs, {
      noremap = true,
      silent = true,
      desc = entry.desc,
    })
  end
  -- Re-applying options also updates buffer-local maps in already-open listings.
  for _, bufnr in ipairs(open_direct_buffers()) do
    config.install_buffer_mappings(bufnr)
  end
  return true
end

function M.clear_mappings(config)
  clear_global_mapping(config)
  -- Explicitly clear owned mappings. setup() uses install_mappings() to
  -- reconcile defaults and per-action overrides while retaining <Plug> maps.
  for _, bufnr in ipairs(open_direct_buffers()) do
    pcall(vim.api.nvim_buf_call, bufnr, function() clear_owned_buffer_maps(config, bufnr) end)
  end
  return true
end

return M
