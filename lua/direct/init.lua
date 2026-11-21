-- lua/direct/init.lua -- public API facade; dispatch and the direct-buffer guard.
-- Current-buffer operations require filetype=direct; listing and the explicit
-- `:DirectPaste {dir}` form are exempt because they do not operate on that buffer.

---@class direct.OpenOptions
---@field split? 'horizontal'|'vertical'|'tab'
---@field reuse? boolean Reuse an existing Direct listing for the target directory.
---@field open_in? 'current'|'new' Open in the current buffer or preserve the source buffer.

---@alias direct.SyncCallback fun(ok: boolean|nil, err: string|nil)

local M = {}

local buffer = require('direct.buffer.buffer')
local register = require('direct.register')
local history = require('direct.history.history')
local config = require('direct.config')
local ui = require('direct.ui')
local constants = require('direct.constants')
local pending = require('direct.pending')
local run = require('direct.run')
local fs = require('direct.fs')
local paths = require('direct.paths')
local trash = require('direct.trash')
local git_restore = require('direct.git_restore')
local events = require('direct.events')

local function paste_and_refresh(destination, name)
  return register.paste(destination, name, function(result, _, _, changed, pasted_entry)
    if not changed then return end
    local ok, refresh_err = pcall(
      function()
        return buffer
          .restore()
          :refresh_after_paste(destination, pasted_entry or (type(result) == 'string' and result or nil))
      end
    )
    if not ok then ui.report_error('refresh the directory after pasting', refresh_err) end
  end)
end

---@param opts direct.Config|nil
function M.setup(opts) return config.setup(opts) end

local function guard(name)
  if vim.bo.filetype == constants.FILETYPE then return true end
  ui.notify('direct: ' .. name .. ' can only be used in a direct buffer', vim.log.levels.ERROR)
  return false
end

local function is_cancelled(err) return type(err) == 'string' and err:find('cancelled', 1, true) ~= nil end

local function refuse_modified_listing_paste()
  local bufnr = vim.api.nvim_get_current_buf()
  if not vim.bo[bufnr].modified then return false end
  local reason = 'cannot paste from a listing with unsaved edits; sync or discard them first'
  ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
  return true, reason
end

---@param path string|nil
---@param options table|nil
function M.list(path, options)
  if pending.refuse('list', 'willRenameFiles') then return nil end
  return buffer.list(path, options)
end

---@param options table|nil
function M.list_buffer(options)
  if pending.refuse('list', 'willRenameFiles') then return nil end
  local root
  if vim.bo.buftype ~= '' then
    root = vim.fn.getcwd()
  else
    root = vim.fn.expand('%:p:h')
    if root == '' then root = vim.fn.getcwd() end
  end
  return buffer.list(root, options)
end

---@param options table|nil
function M.list_cwd(options)
  if pending.refuse('list', 'willRenameFiles') then return nil end
  return buffer.list(vim.fn.getcwd(), options)
end

---@param line string|direct.OpenOptions|nil
---@param options direct.OpenOptions|nil
function M.open(line, options)
  if type(line) == 'table' then
    options, line = line, nil
  end
  options = options or {}
  if pending.refuse('open', 'willRenameFiles') then return nil end
  if not guard('open') then return nil end
  if line == nil then line = vim.fn.getline('.') end
  return buffer.restore():open(line, options)
end

local function entry_from_record(record, root)
  if not record or type(record.name) ~= 'string' or type(record.path) ~= 'string' or record.path == '' then
    return nil
  end
  local kind = record.deleted_kind
  if kind ~= 'file' and kind ~= 'directory' then
    kind = paths.is_directory_name(record.name) and 'directory' or 'file'
  end
  return {
    path = record.path,
    name = paths.strip_directory_marker(record.name),
    type = kind,
    root = root,
    deleted = record.deleted_kind ~= nil,
  }
end

--- Return the unchanged entry record under the cursor, or nil when unavailable.
---@return direct.Entry?
function M.current_entry()
  if vim.bo.filetype ~= constants.FILETYPE then return nil end
  local listing = buffer.restore()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local records = listing:get_entry_records(row, row)
  return records and entry_from_record(records[1], listing.root) or nil
end

--- Return unchanged entry records for the active visual line range, or nil
--- outside a Direct listing or Visual mode.
---@return direct.Entry[]?
function M.selected_entries()
  if vim.bo.filetype ~= constants.FILETYPE then return nil end
  local mode = vim.api.nvim_get_mode().mode
  if mode ~= 'v' and mode ~= 'V' and mode ~= '\22' then return nil end
  local anchor, cursor = vim.fn.line('v'), vim.fn.line('.')
  if anchor < 1 or cursor < 1 then return nil end
  local listing = buffer.restore()
  local first, last = math.min(anchor, cursor), math.max(anchor, cursor)
  local records = listing:get_entry_records(first, last)
  if not records then return nil end
  local entries = {}
  for _, record in ipairs(records) do
    local entry = entry_from_record(record, listing.root)
    if not entry then return nil end
    entries[#entries + 1] = entry
  end
  return entries
end

function M.open_parent_expanded()
  local parent = vim.fn.fnamemodify(buffer.root_for_buffer(), ':h')
  local opened = M.list(parent)
  if not opened then return opened end
  return buffer.expand()
end

function M.show_help()
  if not guard('show key help') then return nil end
  return require('direct.key_help').show()
end

function M.expand()
  if not guard('expand') then return nil end
  return require('direct.buffer.buffer').expand()
end

function M.collapse()
  if not guard('collapse') then return nil end
  return require('direct.buffer.buffer').collapse()
end

function M.toggle()
  if not guard('toggle') then return nil end
  return require('direct.buffer.buffer').toggle()
end

function M.expand_recursive()
  if not guard('expand recursively') then return nil end
  return require('direct.folding').expand_recursive(require('direct.buffer.buffer'))
end

function M.collapse_recursive()
  if not guard('collapse recursively') then return nil end
  -- Collapsing a materialized directory removes its complete descendant tree.
  return require('direct.buffer.buffer').collapse()
end

function M.toggle_recursive()
  if not guard('toggle recursively') then return nil end
  return require('direct.folding').toggle_recursive(require('direct.buffer.buffer'))
end

function M.next_directory()
  if not guard('navigate to the next directory') then return nil end
  return require('direct.folding').navigate_directory(require('direct.buffer.buffer'), 1)
end

function M.previous_directory()
  if not guard('navigate to the previous directory') then return nil end
  return require('direct.folding').navigate_directory(require('direct.buffer.buffer'), -1)
end

---@param callback direct.SyncCallback|nil
function M.sync(callback)
  if not guard('DirectSync') then return nil end
  if pending.refuse('sync') then return nil, 'another direct operation is pending' end
  if type(callback) == 'function' then return buffer.restore():sync_async(callback) end
  return buffer.restore():sync()
end

function M.plan()
  if not guard('DirectPlan') then return nil end
  local listing = buffer.restore()
  local plan, err = listing:plan()
  return require('direct.plan_view').show(plan, err, listing.root)
end

function M.fold_all()
  if not guard('DirectFoldAll') then return nil end
  return require('direct.folding').collapse_all(buffer)
end

function M.unfold_all()
  if not guard('DirectUnfoldAll') then return nil end
  return require('direct.folding').expand_all(buffer)
end

function M.toggle_hidden()
  if not guard('DirectToggleHidden') then return nil end
  if pending.refuse('toggle hidden entries') then return nil end
  return buffer.toggle_hidden()
end

function M.toggle_collapse_single_entry_directories()
  if not guard('DirectToggleDirectoryCollapse') then return nil end
  if pending.refuse('toggle directory collapsing') then return nil end
  return buffer.toggle_collapse_single_entry_directories()
end

function M.toggle_git_status()
  if not guard('DirectToggleGitStatus') then return nil end
  if pending.refuse('toggle Git-status filter') then return nil end
  return buffer.toggle_git_status()
end

function M.toggle_gitignore()
  if not guard('DirectToggleGitIgnore') then return nil end
  if pending.refuse('toggle Git-ignore filtering') then return nil end
  return buffer.toggle_gitignore()
end

function M.show_git_status()
  if not guard('DirectGitStatus') then return nil end
  if pending.refuse('show Git-status view') then return nil end
  return buffer.show_git_status()
end

--- Toggle the committed Git-diff filter for the current Direct listing.
---@param ref string|nil
---@param include_uncommitted boolean|nil
function M.git_diff(ref, include_uncommitted)
  if not guard('DirectGitDiff') then return nil end
  if pending.refuse('change the Git-diff filter') then return nil end
  return buffer.toggle_git_diff(ref, include_uncommitted)
end

function M.next_change()
  if not guard('DirectNextChange') then return nil end
  return buffer.next_change()
end

function M.previous_change()
  if not guard('DirectPreviousChange') then return nil end
  return buffer.previous_change()
end

function M.next_file()
  if not guard('DirectNextFile') then return nil end
  return buffer.next_file()
end

function M.previous_file()
  if not guard('DirectPreviousFile') then return nil end
  return buffer.previous_file()
end

local function path_is_within(root, path)
  root = paths.canonical(fs.realpath(root))
  path = paths.canonical(fs.realpath(path))
  if path == root then return true end
  local prefix = root == '/' and '/' or (root .. '/')
  return path:sub(1, #prefix) == prefix
end

local function reverse(which)
  local command = which == 'undo' and 'DirectUndo' or 'DirectRedo'
  if not guard(command) then return nil end
  if pending.refuse(which) then return nil end

  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].modified or vim.b[bufnr].direct_text_undo_mode == true then
    -- In a dirty listing the familiar keys operate on the buffer's text undo
    -- tree, never on the shared filesystem history. Stay in that mode for the
    -- paired redo even if text undo returns the buffer to its clean baseline.
    vim.cmd(which == 'undo' and 'undo' or 'redo')
    vim.b[bufnr].direct_text_undo_mode = true
    return true
  end

  local options = require('direct.config').options.undo_confirm
  local expected_record
  local event_action
  local root = buffer.restore().root
  if options ~= false then
    local preview, preview_err = history.preview_reverse(which)
    if not preview then return nil, preview_err end
    if not preview.empty then
      expected_record = preview.record
      event_action = preview.action
      local outside = false
      for _, path in ipairs(preview.paths or {}) do
        if not path_is_within(root, path) then
          outside = true
          break
        end
      end
      if options == true or (options == 'elsewhere' and outside) then
        local paths_text = table.concat(preview.paths or {}, '\n')
        local prompt = string.format(
          '%s this filesystem change?\n\n%s\n\nAffected paths:\n%s',
          which == 'undo' and 'Undo' or 'Redo',
          preview.summary,
          paths_text
        )
        if vim.fn.confirm(prompt, which == 'undo' and '&Undo\n&Cancel' or '&Redo\n&Cancel', 2) ~= 1 then return nil end
      end
    end
  end

  local refresh = function(result, reverse_err)
    local refresh_err
    if result ~= nil then
      local ok, listed, list_err = pcall(
        function() return buffer.restore():list({ allow_modified = true, reset_undo = true }) end
      )
      if not ok then
        refresh_err = tostring(listed)
      elseif not listed then
        refresh_err = tostring(list_err)
      end
    end
    if result ~= nil or reverse_err ~= nil then
      events.emit(which == 'undo' and 'DirectUndoPost' or 'DirectRedoPost', {
        root = root,
        actions = result and { result } or (event_action and { event_action } or {}),
        success = result ~= nil and reverse_err == nil and refresh_err == nil,
        error = reverse_err or refresh_err,
        bufnr = bufnr,
      })
    end
  end
  local reverse_options = expected_record and { expected_record = expected_record } or nil
  return history[which .. '_async'](refresh, reverse_options)
end

function M.undo() return reverse('undo') end

function M.redo() return reverse('redo') end

function M.reset_history()
  if pending.refuse('reset history') then return nil end
  local reset, backups = history.reset_history()
  local reset_err = not reset and backups or nil
  events.emit('DirectHistoryResetPost', {
    success = reset == true,
    backups = reset and backups or {},
    error = reset_err,
  })
  return reset, backups
end

function M.trash_list()
  if pending.refuse('list trash') then return nil end
  return trash.show()
end

---@param id string
---@param destination string|nil
---@param force boolean|nil
function M.trash_restore(id, destination, force)
  if pending.refuse('restore trash entry') then return nil end
  local restored, err = trash.restore(id, destination, force)
  if not restored and err and not is_cancelled(err) then
    ui.notify('direct: cannot restore trash entry: ' .. tostring(err), vim.log.levels.ERROR)
  end
  events.emit('DirectTrashPost', {
    operation = 'restore',
    id = id,
    destination = destination,
    force = force == true,
    success = restored == true,
    error = err,
  })
  return restored, err
end

---@param force boolean|nil
function M.trash_empty(force)
  if pending.refuse('empty trash') then return nil end
  local emptied, result = trash.empty(force)
  if not emptied and result and not is_cancelled(result) then
    ui.notify('direct: cannot empty trash: ' .. tostring(result), vim.log.levels.ERROR)
  end
  local empty_err = not emptied and result or nil
  events.emit('DirectTrashPost', {
    operation = 'empty',
    force = force == true,
    success = emptied == true,
    removed = emptied and result.removed or nil,
    protected = emptied and result.protected or nil,
    error = empty_err,
  })
  return emptied, result
end

-- The range is normalised so an upward visual selection works; a nil range means the current line.
---@param first integer|nil
---@param last integer|nil
function M.yank(first, last)
  if pending.refuse('yank') then return nil end
  if not guard('DirectYank') then return nil end
  local line = vim.fn.line('.')
  first = first or line
  last = last or line
  if first > last then
    first, last = last, first
  end
  local b = buffer.restore()
  local bufnr = vim.api.nvim_get_current_buf()
  local was_modified = vim.bo[bufnr].modified
  local sources, path_err = b:get_paths(first, last)
  if not sources then
    ui.notify('direct: cannot yank selection: ' .. tostring(path_err), vim.log.levels.ERROR)
    return nil, path_err
  end
  if #sources == 0 then return true end
  -- The copy runs in the background under the pending guard. An unmodified
  -- listing refreshes once it settles, matching the old synchronous behavior.
  local started, start_err = register.yank_async(sources, function(ok)
    if not ok or was_modified then return end
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if vim.bo[bufnr].filetype ~= constants.FILETYPE then return end
    local refresh_ok, refresh_err = pcall(function() b:list() end)
    if not refresh_ok then ui.report_error('refresh after yanking', refresh_err) end
  end)
  if not started then return nil, start_err end
  return true
end

-- No argument pastes relative to the current row and refreshes the listing;
-- `{dir}` pastes elsewhere, unguarded.
---@param dir string|nil
function M.paste(dir)
  if pending.refuse('paste') then return nil end
  if dir == nil or dir == '' then
    if not guard('DirectPaste') then return nil end
    local refused, reason = refuse_modified_listing_paste()
    if refused then return nil, reason end
    local b = buffer.restore()
    local destination, path_err = b:paste_destination()
    if destination == false then return true end
    if not destination then
      ui.notify('direct: cannot paste: ' .. tostring(path_err), vim.log.levels.ERROR)
      return nil, path_err
    end
    return paste_and_refresh(destination)
  end
  return register.paste(dir)
end

---@param name string
function M.paste_as(name)
  if pending.refuse('paste') then return nil end
  if not guard('DirectPasteAs') then return nil end
  local refused, reason = refuse_modified_listing_paste()
  if refused then return nil, reason end
  local b = buffer.restore()
  local destination, path_err = b:paste_destination()
  if destination == false then return true end
  if not destination then
    ui.notify('direct: cannot paste: ' .. tostring(path_err), vim.log.levels.ERROR)
    return nil, path_err
  end
  return paste_and_refresh(destination, name)
end

---@param command string
function M.run(command)
  if not guard('DirectRun') then return nil end
  if pending.refuse('run a shell command') then return nil end
  return run.current_entry(command)
end

---@param command string
function M.git(command)
  if not guard('DirectGit') then return nil end
  if pending.refuse('run a Git command') then return nil end
  buffer.cancel_git_status()
  return run.current_entry(
    command,
    function(_, bufnr, root) buffer.refresh_git_status(bufnr, root) end,
    { quiet_success = true }
  )
end

function M.restore_git()
  if not guard('DirectGitRestore') then return nil end
  if pending.refuse('restore Git changes') then return nil end
  return git_restore.restore()
end

-- Public API functions are a final error boundary for both Lua callers and the
-- user commands/mappings that delegate to them. Expected failures are returned
-- normally by the implementations; only unexpected raised errors are reported
-- here, so a failure already handled by an operation does not produce a second
-- notification.
local protected_actions = {
  setup = 'apply the configuration',
  list = 'open the directory listing',
  list_buffer = "open the current buffer's directory",
  list_cwd = 'open the current working directory',
  open = 'open the selected entry',
  open_parent_expanded = 'open and expand the parent directory',
  expand = 'expand the selected directory',
  collapse = 'collapse the selected directory',
  toggle = 'toggle the selected directory',
  expand_recursive = 'expand the selected directory recursively',
  collapse_recursive = 'collapse the selected directory recursively',
  toggle_recursive = 'toggle the selected directory recursively',
  next_directory = 'navigate to the next directory',
  previous_directory = 'navigate to the previous directory',
  sync = 'sync the directory listing',
  fold_all = 'collapse the expanded directories',
  unfold_all = 'expand the directories',
  toggle_hidden = 'toggle hidden entries',
  toggle_collapse_single_entry_directories = 'toggle single-entry directory collapsing',
  toggle_git_status = 'toggle the Git-status filter',
  toggle_gitignore = 'toggle Git-ignore filtering',
  show_git_status = 'show the Git-status view',
  next_change = 'navigate to the next changed entry',
  previous_change = 'navigate to the previous changed entry',
  next_file = 'navigate to the next file',
  previous_file = 'navigate to the previous file',
  current_entry = 'get the entry under the cursor',
  selected_entries = 'get the selected entries',
  undo = 'undo the last filesystem action',
  redo = 'redo the last filesystem action',
  reset_history = 'reset the filesystem history',
  trash_list = 'list trashed entries',
  trash_restore = 'restore a trashed entry',
  trash_empty = 'empty unreferenced trash entries',
  yank = 'copy the selected entries to the Direct register',
  paste = 'paste the Direct register',
  paste_as = 'paste the Direct register with the requested name',
  run = 'run the command for the selected entry',
  git = 'run the Git command for the selected entry',
  restore_git = 'restore Git worktree changes for the selected entry',
}

local pack = function(...) return { n = select('#', ...), ... } end
-- Neovim embeds LuaJIT, where `unpack` is the Lua 5.1 global.
local unpack_values = unpack
for name, description in pairs(protected_actions) do
  local implementation = M[name]
  M[name] = function(...)
    local args, count = pack(...), select('#', ...)
    local result = pack(xpcall(function() return implementation(unpack_values(args, 1, count)) end, debug.traceback))
    if not result[1] then return ui.report_error(description, result[2]) end
    return unpack_values(result, 2, result.n)
  end
end

return M
