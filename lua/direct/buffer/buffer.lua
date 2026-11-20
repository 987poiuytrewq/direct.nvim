-- lua/direct/buffer/buffer.lua -- assemble the Direct buffer model and lifecycle.
-- Listing, row state, navigation, open, and sync implementations live in the
-- focused modules under direct.buffer and install methods on the shared model.

local M = {}

-- Module tables are captured once so tests can stub `fs.rename`
-- `history.log`, `register.yank`, `ui.notify`,... on the very tables the
-- code below resolves through.
local fs = require('direct.fs')
local paths = require('direct.paths')
local ui = require('direct.ui')
local highlight = require('direct.highlight')
local git = require('direct.git')
local constants = require('direct.constants')
local folding = require('direct.folding')
local listing = require('direct.buffer.listing')
local rows = require('direct.buffer.rows')
local buffer_state = require('direct.buffer.state')
local states = buffer_state.states
local deleted_guards = buffer_state.deleted_guards
local state_generations = {}
local next_state_generation = 0
local git_status_timeout_notified = {}
local row_ids_by_row = rows.row_ids_by_row
local current_row_record = rows.current_row_record
local refresh_icons = rows.refresh_icons
M._state_for_test = rows.state_for_test
M.entry_path = listing.entry_path
M.ignore_set = listing.ignore_set
M.read = listing.read

local function ensure_git_snapshot(state) return state.git_status end

local refresh_highlights

local function start_git_status(bufnr, state, timeout_ms)
  if state.git_status_cancel then state.git_status_cancel() end
  local request = {}
  state.git_status_request = request
  state.git_status_pending = true
  local cancel = git.read_async(state.root, timeout_ms, function(snapshot, err)
    if not vim.api.nvim_buf_is_valid(bufnr) or states[bufnr] ~= state or state.git_status_request ~= request then
      return
    end
    if not fs.stat(state.root) then return end
    state.git_status_request = nil
    state.git_status_cancel = nil
    state.git_status_pending = false
    state.git_status = snapshot or false

    if err then
      local key = paths.canonical(state.root)
      if not git_status_timeout_notified[key] then
        git_status_timeout_notified[key] = true
        ui.notify('direct: Git status unavailable for ' .. state.root .. ': ' .. tostring(err), vim.log.levels.WARN)
      end
    end

    if snapshot and not vim.bo[bufnr].modified then
      local expand_git_view = state.git_expand_all == true
      state.git_expand_all = false
      vim.api.nvim_buf_call(bufnr, function()
        if states[bufnr] == state and not vim.bo[bufnr].modified then
          M.list(state.root, { git_status_resolved = true, git_status = snapshot })
          if expand_git_view then require('direct.folding').expand_all(M) end
        end
      end)
      return
    end

    local row_ids = row_ids_by_row(bufnr)
    refresh_highlights(bufnr, state, row_ids)
    refresh_icons(bufnr, state, row_ids)
  end)
  if state.git_status_request == request then state.git_status_cancel = cancel end
end

function M.cancel_git_status(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = states[bufnr]
  if not state then return false end
  if state.git_status_cancel then state.git_status_cancel() end
  state.git_status_cancel = nil
  state.git_status_request = nil
  state.git_status_pending = false
  return true
end

refresh_highlights = function(bufnr, state, row_ids)
  local options = require('direct.config').options
  local snapshot = ensure_git_snapshot(state)
  local display_rows = {}
  row_ids = row_ids or row_ids_by_row(bufnr)
  for row = 0, vim.api.nvim_buf_line_count(bufnr) - 1 do
    local id = row_ids[row]
    local rec = id and state.rows[id]
    if rec then
      local status, conflict
      if snapshot then
        status, conflict = git.status_for(snapshot, rec.path)
      end
      display_rows[#display_rows + 1] = {
        row = row,
        depth = rec.depth or 0,
        status = status,
        conflict = conflict,
        first_status = snapshot and git.first_status_for(snapshot, rec.path) or nil,
        deleted_kind = rec.deleted_kind,
      }
    end
  end
  highlight.render(bufnr, display_rows, options)
end

-- Refresh Git-only decorations for a loaded direct buffer without changing its
-- text or list-time filesystem snapshot.
function M.refresh_git_status(bufnr, root)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_loaded(bufnr) or vim.bo[bufnr].filetype ~= constants.FILETYPE then return false end
  local state = states[bufnr]
  if not state or (root and state.root ~= root) then return false end
  state.git_status = nil
  local options = require('direct.config').options
  if not options.git.enabled then
    state.git_status = false
    refresh_highlights(bufnr, state)
    refresh_icons(bufnr, state)
    return true
  end
  refresh_highlights(bufnr, state)
  refresh_icons(bufnr, state)
  start_git_status(bufnr, state, options.git.timeout_ms)
  return true
end

local merge_deleted_entries, hide_deleted_expansions
local capture_deleted_guard_snapshot, restore_deleted_rows, attach_deleted_guard

local sync_plan = require('direct.buffer.sync_plan')
buffer_state.sync_plan = sync_plan
M._component_reason = sync_plan.component_reason
M._nested_path_reason = sync_plan.nested_path_reason
local pending = require('direct.pending')
M._pending_for_test = pending
local pending_sync = buffer_state.pending_sync
local reconcile_undone_materialization

local Buffer = {}
Buffer.__index = Buffer
buffer_state.Buffer = Buffer

-- Display rows are identified by extmarks rather than their spelling.  In
-- particular, child rows are never interpreted as root-relative filenames.
-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

-- current_entry([name]) -> `name` when it names an existing filesystem entry
-- else nil. Defaults to the current buffer's stored name: the buffer name
-- `nvim_buf_get_name` returns (the resolved spelling). `same_path` makes the
-- spelling irrelevant, so no `bufname('%')` accessor is needed.
function M.current_entry(name)
  if name == nil then name = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()) end
  if type(name) ~= 'string' or name == '' then return nil end
  if fs.stat(name) then return name end
  return nil
end

-- ---------------------------------------------------------------------------
-- sync-boundary framing guard
-- ---------------------------------------------------------------------------

-- unsafe_path_reason(path) -> the shared `action.path_reason`, which rejects
-- invalid UTF-8 and controls before any sync side effect. This boundary keeps
-- its early, user-facing refusal; action serialization applies the same guard
-- to every emitted record.
-- Attach tree-integrity and edited-subtree planning methods.
local tree_plan = require('direct.buffer.tree')
buffer_state.tree_plan = tree_plan
local undo_state = require('direct.buffer.undo_state')
reconcile_undone_materialization = undo_state.reconcile_undone_materialization
buffer_state.reconcile_undone_materialization = reconcile_undone_materialization

-- ---------------------------------------------------------------------------
local row_state = require('direct.buffer.row_state')
Buffer.expand = row_state.expand
Buffer.collapse = row_state.collapse
local merge_status_deleted_entries = row_state.merge_deleted_entries
merge_deleted_entries = function(directory, lines, git_snapshot, show_hidden, diff_snapshot)
  local result, deleted = merge_status_deleted_entries(directory, lines, git_snapshot, show_hidden)
  if not diff_snapshot then return result, deleted end
  local with_diff, diff_deleted = merge_status_deleted_entries(directory, result, diff_snapshot, show_hidden)
  for path, kind in pairs(diff_deleted) do
    deleted[path] = kind
  end
  return with_diff, deleted
end
hide_deleted_expansions = row_state.hide_deleted_expansions
capture_deleted_guard_snapshot = row_state.capture_deleted_guard_snapshot
restore_deleted_rows = row_state.restore_deleted_rows
buffer_state.restore_deleted_rows = restore_deleted_rows
attach_deleted_guard = row_state.attach_deleted_guard

-- Buffer options
-- ---------------------------------------------------------------------------

local function ensure_direct_syntax(bufnr)
  vim.api.nvim_buf_call(bufnr, function()
    if vim.b.current_syntax ~= 'direct' then
      if vim.b.current_syntax ~= nil then vim.cmd('syntax clear') end
      vim.b.current_syntax = nil
      vim.bo.syntax = 'direct'
      -- `syntax=direct` does not source a syntax file when the user's global
      -- syntax loader is off. Source this small buffer-local syntax explicitly
      -- so direct listings still get their filename highlights in that setup.
      if vim.b.current_syntax ~= 'direct' then vim.cmd('runtime! syntax/direct.vim') end
    else
      vim.bo.syntax = 'direct'
    end
  end)
end

local function set_options(bufnr)
  next_state_generation = next_state_generation + 1
  local generation = next_state_generation
  state_generations[bufnr] = generation
  vim.bo[bufnr].buftype = 'acwrite'
  vim.bo[bufnr].buflisted = true
  vim.bo[bufnr].swapfile = false
  -- Keep a dirty listing available while navigating to another directory even
  -- when the user's global 'hidden' option is off.
  vim.bo[bufnr].bufhidden = 'hide'
  vim.bo[bufnr].filetype = constants.FILETYPE
  ensure_direct_syntax(bufnr)
  -- BufWriteCmd <buffer>: modified listings sync, while a clean `:write`
  -- refreshes from disk instead of interpreting external changes as deletions.
  -- Each buffer owns a shared group outside `direct` so re-sourcing
  -- plugin/direct.lua can clear its global handlers without removing this one.
  -- Clear only this buffer's previous handler so relisting cannot stack handlers.
  local group = vim.api.nvim_create_augroup('direct-buffer', { clear = false })
  pcall(vim.api.nvim_clear_autocmds, { group = group, buffer = bufnr })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = bufnr,
    callback = function()
      if state_generations[bufnr] ~= generation then return end
      local function release_state()
        if state_generations[bufnr] ~= generation then return end
        state_generations[bufnr] = nil
        states[bufnr] = nil
        deleted_guards[bufnr] = nil
      end
      local save_wiped = pending.save_wiped(bufnr, release_state)
      local active_sync_wiped = not save_wiped
        and pending.active_for_buffer(bufnr, 'sync')
        and pending.defer_cleanup(bufnr, release_state)
      if save_wiped or active_sync_wiped then
        ui.notify(
          'direct: listing buffer is gone; its save continues in the background. '
            .. 'The journal will recover an interrupted operation on the next start.',
          vim.log.levels.WARN
        )
        return
      end
      local operation = pending_sync[bufnr]
      if operation then
        if operation.cancel then operation.cancel() end
        operation.cleanup()
      end
      release_state()
    end,
    desc = 'direct: release listing row state when the buffer is wiped',
  })
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    group = group,
    buffer = bufnr,
    callback = function(args)
      vim.api.nvim_set_current_buf(args.buf)
      if vim.bo[args.buf].modified then
        if not pending.can_queue_save() then
          pending.refuse('sync')
          return
        end
        local listing_buffer = M.restore()
        local completed, result, sync_err, sync_detail = false, nil, nil, nil
        pending.enqueue_save(args.buf, function(done)
          if not vim.api.nvim_buf_is_valid(args.buf) then
            done(nil, 'listing buffer was closed before its queued save could start')
            return true
          end
          vim.api.nvim_buf_call(args.buf, function()
            local started, start_err = listing_buffer:sync_async(done)
            if not started then done(nil, start_err) end
          end)
          return true
        end, function(ok, err, detail)
          completed, result, sync_err, sync_detail = true, ok, err, detail
        end)
        while not completed do
          local _, wait_err = vim.wait(60000, function() return completed end, 10)
          if wait_err == -2 then
            ui.notify('direct: stopped waiting for the save; it continues in the background', vim.log.levels.INFO)
            return
          end
        end
        if result == nil then error(sync_detail or sync_err or 'direct sync refused') end
      else
        if pending.refuse('sync') then return end
        M.restore():list({ reset_undo = true })
      end
    end,
    desc = 'direct: sync the listing on :write',
  })
  vim.api.nvim_create_autocmd('BufReadCmd', {
    group = group,
    buffer = bufnr,
    callback = function(args)
      vim.api.nvim_set_current_buf(args.buf)
      M.restore():list({ reset_undo = true })
    end,
    desc = 'direct: refresh the listing on :edit',
  })
  vim.api.nvim_create_autocmd('TextChanged', {
    group = group,
    buffer = bufnr,
    callback = function()
      local state = states[bufnr]
      if state then restore_deleted_rows(bufnr, state) end
      reconcile_undone_materialization(bufnr)
      -- Edits such as `J` can move display extmarks from a deleted row into
      -- the middle of the surviving line. Rebuild them from row identities.
      state = states[bufnr]
      if state and state.decorations_dirty and not state.pending_deleted_restore then
        local row_ids = row_ids_by_row(bufnr)
        refresh_highlights(bufnr, state, row_ids)
        refresh_icons(bufnr, state, row_ids)
      end
    end,
    desc = 'direct: reconcile child rows and refresh display marks after text changes',
  })
  vim.api.nvim_create_autocmd('TextChangedI', {
    group = group,
    buffer = bufnr,
    callback = function()
      local state = states[bufnr]
      if state then restore_deleted_rows(bufnr, state) end
      state = states[bufnr]
      if state and (state.decorations_dirty or state.icon_line_count ~= vim.api.nvim_buf_line_count(bufnr)) then
        local row_ids = row_ids_by_row(bufnr)
        refresh_highlights(bufnr, state, row_ids)
        refresh_icons(bufnr, state, row_ids)
      end
    end,
    desc = 'direct: refresh display marks when insert-mode edits change line count',
  })
  folding.install_mappings(bufnr, M)
  attach_deleted_guard(bufnr)
  capture_deleted_guard_snapshot(bufnr, states[bufnr])
end

-- ---------------------------------------------------------------------------
-- Attach / create
-- ---------------------------------------------------------------------------

-- direct_root keeps a directory listing's filesystem path independent of its
-- buffer name. This is needed when reuse is disabled because Neovim requires
-- buffer names to be unique.
function M.root_for_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype == constants.FILETYPE then
    local root = vim.b[bufnr].direct_root
    if type(root) == 'string' and root ~= '' then return root end
  end
  return vim.api.nvim_buf_get_name(bufnr)
end

-- Capture current_entry before switching buffers. Reuse uses path identity so
-- symlink aliases still select the same listing.
function M.Buffer(path, options)
  options = options or {}
  local configured = require('direct.config').options.buffers
  local reuse = options.reuse
  if reuse == nil then reuse = configured.reuse end
  local open_in = options.open_in
  if open_in == nil then open_in = configured.open_in end
  local root = paths.root(path)
  local self = setmetatable({
    root = root,
    current_entry = M.current_entry(),
  }, Buffer)

  if reuse then
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      local name = M.root_for_buffer(bufnr)
      -- Compare by path identity, never `==` (a symlinked prefix makes the buffer
      -- name and root different spellings of the same directory) and never
      -- `vim.fn.bufnr` (which pattern-matches and is spelling-sensitive).
      if name ~= '' and fs.same_path(name, root) then
        vim.api.nvim_set_current_buf(bufnr)
        vim.b[bufnr].direct_root = root
        return self
      end
    end
  end

  local bufnr
  if not reuse then
    -- Neovim forbids two buffers with the same name (E95). Keep the real root
    -- in buffer-local metadata and give this independent listing a readable,
    -- unique URI.
    bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_name(bufnr, string.format('direct://%s#%d', root, bufnr))
  elseif open_in == 'new' then
    bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_name(bufnr, root)
  else
    vim.cmd('enew')
    bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(bufnr, root)
  end
  vim.b[bufnr].direct_root = root
  return self
end

-- Buffer attach/list behavior is isolated from row expansion and sync.
local collapse = require('direct.buffer.collapse')
buffer_state.collapse_single_entry_paths = collapse.collapse_single_entry_paths

buffer_state.list_hooks = {
  merge_deleted_entries = merge_deleted_entries,
  hide_deleted_expansions = hide_deleted_expansions,
  refresh_highlights = refresh_highlights,
  refresh_icons = refresh_icons,
  set_options = set_options,
  start_git_status = start_git_status,
}
buffer_state.list_parent = M

-- Attach root listing and buffer methods in one visible place.
local list = require('direct.buffer.list')
M.restore = list.restore
M.list = list.list
Buffer.place_cursor = list.place_cursor
Buffer.list = list.list_buffer

function M.expand()
  if pending.refuse('expand', 'willRenameFiles') then return nil end
  local buffer = M.restore()
  return buffer:expand(vim.api.nvim_win_get_cursor(0)[1])
end

function M.collapse()
  if pending.refuse('collapse', 'willRenameFiles') then return nil end
  local buffer = M.restore()
  return buffer:collapse(vim.api.nvim_win_get_cursor(0)[1])
end

function M.toggle()
  if pending.refuse('toggle', 'willRenameFiles') then return nil end
  local bufnr = vim.api.nvim_get_current_buf()
  local rec = current_row_record(bufnr, vim.api.nvim_win_get_cursor(0)[1] - 1)
  if rec and states[bufnr] and states[bufnr].expanded[rec.id] then return M.collapse() end
  return M.expand()
end

function M.toggle_hidden()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].modified then
    local reason = 'cannot toggle hidden entries with unsaved edits; sync or discard them first'
    ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
    return nil, reason
  end
  local state = states[bufnr]
  if not state then
    local reason = 'direct listing state is unavailable; re-list this directory'
    ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
    return nil, reason
  end
  local previous = {
    view_show_hidden = state.view_show_hidden,
    view_show_hidden_override = state.view_show_hidden_override,
    expanded = state.expanded,
    known_children = state.known_children,
    directory_snapshots = state.directory_snapshots,
    materialization_undos = state.materialization_undos,
    materialization_recoveries = state.materialization_recoveries,
    collapse_undos = state.collapse_undos,
  }
  state.view_show_hidden = not state.view_show_hidden
  state.view_show_hidden_override = true
  -- Rebuild from the root so every expanded subtree uses the same visibility
  -- setting; doing this only changes the view and is not text-undoable.
  state.expanded = {}
  state.known_children = {}
  state.directory_snapshots = {}
  state.materialization_undos = {}
  state.materialization_recoveries = {}
  state.collapse_undos = {}
  local listed, err = M.restore():list({ reset_undo = true })
  if not listed then
    for key, value in pairs(previous) do
      state[key] = value
    end
    return nil, err
  end
  return listed
end

function M.toggle_collapse_single_entry_directories()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].modified then
    local reason = 'cannot toggle directory collapsing with unsaved edits; sync or discard them first'
    ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
    return nil, reason
  end
  local state = states[bufnr]
  if not state then
    local reason = 'direct listing state is unavailable; re-list this directory'
    ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
    return nil, reason
  end
  local previous = {
    view_collapse_single_entry_directories = state.view_collapse_single_entry_directories,
    view_collapse_single_entry_directories_override = state.view_collapse_single_entry_directories_override,
    expanded = state.expanded,
    known_children = state.known_children,
    directory_snapshots = state.directory_snapshots,
    materialization_undos = state.materialization_undos,
    materialization_recoveries = state.materialization_recoveries,
    collapse_undos = state.collapse_undos,
  }
  state.view_collapse_single_entry_directories = not state.collapse_single_entry_directories
  state.view_collapse_single_entry_directories_override = true
  state.expanded = {}
  state.known_children = {}
  state.directory_snapshots = {}
  state.materialization_undos = {}
  state.materialization_recoveries = {}
  state.collapse_undos = {}
  local listed, err = M.restore():list({ reset_undo = true })
  if not listed then
    for key, value in pairs(previous) do
      state[key] = value
    end
    return nil, err
  end
  return listed
end

local function set_git_status_only(enabled)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].modified then
    local reason = 'cannot change the Git-status filter with unsaved edits; sync or discard them first'
    ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
    return nil, reason
  end
  local state = states[bufnr]
  if not state then
    local reason = 'direct listing state is unavailable; re-list this directory'
    ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
    return nil, reason
  end
  if state.view_git_status_only == enabled then
    if enabled then return require('direct.folding').expand_all(M) end
    return true
  end
  local previous = {
    view_git_status_only = state.view_git_status_only,
    expanded = state.expanded,
    known_children = state.known_children,
    directory_snapshots = state.directory_snapshots,
    materialization_undos = state.materialization_undos,
    materialization_recoveries = state.materialization_recoveries,
    collapse_undos = state.collapse_undos,
  }
  state.view_git_status_only = enabled
  state.git_expand_all = enabled
  -- Rebuild at every level from a fresh Git snapshot; the view must not leave
  -- stale child rows behind when the filter is enabled or disabled.
  state.expanded = {}
  state.known_children = {}
  state.directory_snapshots = {}
  state.materialization_undos = {}
  state.materialization_recoveries = {}
  state.collapse_undos = {}
  local listed, err = M.restore():list({ reset_undo = true })
  if not listed then
    for key, value in pairs(previous) do
      state[key] = value
    end
    return nil, err
  end
  if enabled then return require('direct.folding').expand_all(M) end
  return listed
end

function M.toggle_gitignore()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = states[bufnr]
  if vim.bo[bufnr].modified then
    local only_unfiltered = state ~= nil and state.view_respect_gitignore == true
    local saw_timeout = false
    for _, snapshot in ipairs(state and state.directory_snapshots or {}) do
      if snapshot.respect_gitignore then
        if snapshot.git_timeout or snapshot.git_unfiltered then
          saw_timeout = true
        elseif snapshot.git_repo ~= false then
          only_unfiltered = false
          break
        end
      end
    end
    if only_unfiltered and saw_timeout then
      state.view_respect_gitignore = false
      state.view_respect_gitignore_override = true
      for _, snapshot in ipairs(state.directory_snapshots or {}) do
        if snapshot.respect_gitignore then
          snapshot.respect_gitignore = false
          snapshot.git_timeout = false
          snapshot.git_timeout_error = nil
          snapshot.git_unfiltered = false
          snapshot.git_retry_snapshot = nil
          snapshot.git = nil
        end
      end
      listing.set_git_timeout_indicator(bufnr, state)
      ui.notify('direct: Git-ignore filtering disabled; unsaved listing edits were preserved', vim.log.levels.INFO)
      return true
    end
    local reason = 'cannot toggle Git-ignore filtering with unsaved edits; sync or discard them first'
    ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
    return nil, reason
  end
  if not state then
    local reason = 'direct listing state is unavailable; re-list this directory'
    ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
    return nil, reason
  end
  local previous = {
    view_respect_gitignore = state.view_respect_gitignore,
    view_respect_gitignore_override = state.view_respect_gitignore_override,
    expanded = state.expanded,
    known_children = state.known_children,
    directory_snapshots = state.directory_snapshots,
    materialization_undos = state.materialization_undos,
    materialization_recoveries = state.materialization_recoveries,
    collapse_undos = state.collapse_undos,
  }
  state.view_respect_gitignore = not state.view_respect_gitignore
  state.view_respect_gitignore_override = true
  -- Rebuild from the root so every expanded level uses the same Git rules.
  state.expanded = {}
  state.known_children = {}
  state.directory_snapshots = {}
  state.materialization_undos = {}
  state.materialization_recoveries = {}
  state.collapse_undos = {}
  local listed, err = M.restore():list({ reset_undo = true })
  if not listed then
    for key, value in pairs(previous) do
      state[key] = value
    end
    return nil, err
  end
  return listed
end

function M.toggle_git_status()
  local state = states[vim.api.nvim_get_current_buf()]
  if not state then return set_git_status_only(true) end
  return set_git_status_only(not state.view_git_status_only)
end

function M.show_git_status() return set_git_status_only(true) end

local function set_git_diff_only(ref, include_uncommitted)
  local bufnr = vim.api.nvim_get_current_buf()
  if ref ~= nil and type(ref) ~= 'string' then
    local reason = 'Git ref must be a string'
    ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
    return nil, reason
  end
  if vim.bo[bufnr].modified then
    local reason = 'cannot change the Git-diff filter with unsaved edits; sync or discard them first'
    ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
    return nil, reason
  end
  local state = states[bufnr]
  if not state then
    local reason = 'direct listing state is unavailable; re-list this directory'
    ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
    return nil, reason
  end

  local active_snapshot = type(state.git_diff_snapshot) == 'table' and state.git_diff_snapshot or nil
  local same_ref = ref == nil or (active_snapshot and vim.trim(ref) == active_snapshot.ref)
  local same_uncommitted = include_uncommitted == nil
    or (active_snapshot and include_uncommitted == active_snapshot.include_uncommitted)
  local turning_off = state.view_git_diff_only and same_ref and same_uncommitted
  local snapshot = false
  if not turning_off then
    local err
    snapshot, err = git.compare_snapshot(state.root, ref, {
      include_uncommitted = include_uncommitted == true,
    })
    if not snapshot then
      ui.notify('direct: cannot compare Git diff: ' .. tostring(err), vim.log.levels.ERROR)
      return nil, err
    end
  end

  local previous = {
    view_git_diff_only = state.view_git_diff_only,
    git_diff_snapshot = state.git_diff_snapshot,
    expanded = state.expanded,
    known_children = state.known_children,
    directory_snapshots = state.directory_snapshots,
    materialization_undos = state.materialization_undos,
    materialization_recoveries = state.materialization_recoveries,
    collapse_undos = state.collapse_undos,
  }
  state.view_git_diff_only = not turning_off
  state.git_diff_snapshot = snapshot
  state.expanded = {}
  state.known_children = {}
  state.directory_snapshots = {}
  state.materialization_undos = {}
  state.materialization_recoveries = {}
  state.collapse_undos = {}
  local listed, err = M.restore():list({
    reset_undo = true,
    git_diff_resolved = true,
    git_diff_only = not turning_off,
    git_diff_snapshot = snapshot,
  })
  if not listed then
    for key, value in pairs(previous) do
      state[key] = value
    end
    return nil, err
  end
  if not turning_off then return folding.expand_all(M) end
  return listed
end

function M.toggle_git_diff(ref, include_uncommitted) return set_git_diff_only(ref, include_uncommitted) end

-- Attach navigation and folding-adapter methods in one visible place.
local navigation = require('direct.buffer.navigation')
M.navigate_git_status = navigation.navigate_git_status
M.next_change = navigation.next_change
M.previous_change = navigation.previous_change
M.navigate_file = navigation.navigate_file
M.next_file = navigation.next_file
M.previous_file = navigation.previous_file
M._folding_context = navigation._folding_context
M.expand_recursive = navigation.expand_recursive
M.toggle_recursive = navigation.toggle_recursive
M.expand_all = navigation.expand_all
M.collapse_all = navigation.collapse_all

-- Attach sync methods together so Buffer's public implementation is easy to find.
local sync = require('direct.buffer.sync')
Buffer.sync = sync.sync
Buffer.sync_async = sync.sync_async
Buffer.plan = sync.plan

-- Opening and row-path operations are kept separate from listing and sync.
local open = require('direct.buffer.open')
Buffer.open = open.open
Buffer.get_paths = open.get_paths
Buffer.get_entry_path = open.get_entry_path
Buffer.get_entry_record = open.get_entry_record
Buffer.paste_destination = open.paste_destination
Buffer.refresh_after_paste = open.refresh_after_paste

return M
