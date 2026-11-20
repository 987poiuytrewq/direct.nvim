-- Public configuration facade. Option validation and mapping lifecycle live in
-- focused modules while existing callers continue to use direct.config.

local M = {}
local options = require('direct.config.options')
local mappings = require('direct.config.mappings')
local ui = require('direct.ui')

---@type direct.Config
M.defaults = options.defaults
---@type direct.Config
M.options = vim.deepcopy(M.defaults)

M.GLOBAL_MAP = mappings.GLOBAL_MAP
M.BUFFER_MAPS = mappings.BUFFER_MAPS

-- Lifecycle state. `_setup_called` short-circuits the VimEnter handler once the
-- user has configured the plugin; `_vim_enter_installed` makes that handler
-- one-shot. `_installed` tracks only the global mapping owned by Direct.
M._setup_called = false
M._vim_enter_installed = false
M._installed = vim.fn.maparg(M.GLOBAL_MAP.lhs, M.GLOBAL_MAP.mode) == M.GLOBAL_MAP.rhs

---@param action string
---@param default string
---@return string?
function M.mapping_lhs(action, default) return mappings.mapping_lhs(M, action, default) end

---@param bufnr integer
---@return boolean
function M.install_buffer_mappings(bufnr) return mappings.install_buffer_mappings(M, bufnr) end

---@param bufnr? integer
---@return boolean
function M.clear_buffer_mappings(bufnr) return mappings.clear_buffer_mappings(M, bufnr) end

---@return boolean
function M.install_mappings() return mappings.install_mappings(M) end

---@return boolean
function M.clear_mappings() return mappings.clear_mappings(M) end

-- setup(opts) replaces, rather than merges with, the previous option table.
-- Validation collects every issue before emitting one report.
---@param opts direct.Config|nil
---@return direct.Config
function M.setup(opts)
  opts = opts or {}
  local next_options, errors = options.resolve(opts, function() return mappings.mapping_catalog(M) end)
  M.options = next_options
  M._setup_called = true
  if #errors > 0 then ui.notify(table.concat(errors, '\n'), vim.log.levels.ERROR) end
  M.install_mappings()
  return M.options
end

-- on_vim_enter -> boolean (installed?). The VimEnter handler installs the
-- default mapping at most once and only when setup was never called.
function M.on_vim_enter()
  if M._setup_called or M._vim_enter_installed then return false end
  M._vim_enter_installed = true
  M.install_mappings()
  return true
end

-- install_deferred -> boolean (installed now?). The entry point that
-- plugin/direct.lua calls at load: when VimEnter has already fired (`-l`, or a
-- startup that sourced the plugin late) install immediately; otherwise defer to
-- a one-shot VimEnter autocmd.
function M.install_deferred()
  if vim.v.vim_did_enter == 1 then return M.on_vim_enter() end
  local group = vim.api.nvim_create_augroup('direct_deferred', { clear = true })
  vim.api.nvim_create_autocmd('VimEnter', {
    group = group,
    pattern = '*',
    once = true,
    callback = function() M.on_vim_enter() end,
  })
  return false
end

return M
