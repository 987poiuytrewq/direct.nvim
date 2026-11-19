-- Root listing and attachment operations for direct buffers.
local M = {}

local action_mod = require('direct.action.action')
local constants = require('direct.constants')
local fs = require('direct.fs')
local git = require('direct.git')
local listing = require('direct.buffer.listing')
local paths = require('direct.paths')
local rows = require('direct.buffer.rows')
local ui = require('direct.ui')
local buffer_state = require('direct.buffer.state')

local states = buffer_state.states
local namespace = buffer_state.namespace
local next_id = rows.next_id
local set_row_mark = rows.set_row_mark
local row_ids_by_row = rows.row_ids_by_row
local current_row_record = rows.current_row_record
local row_path = rows.row_path
local is_dir_line = rows.is_dir_line
local set_directory_snapshot = listing.set_directory_snapshot
local set_git_timeout_indicator = listing.set_git_timeout_indicator

local function parent()
  -- buffer.lua attaches itself after loading this module. Keeping the owning
  -- parent table in shared state also keeps method seams coherent across the
  -- test harness's module reload boundaries.
  local buffer_module = buffer_state.list_parent
  assert(type(buffer_module) == 'table', 'buffer.list parent is not attached')
  return buffer_module
end

local function hook(name)
  local hooks = buffer_state.list_hooks
  local callback = hooks and hooks[name]
  assert(type(callback) == 'function', 'buffer.list hook is unavailable: ' .. name)
  return callback
end

local function indent_size() return require('direct.config').options.indent_size end

local function list_with_snapshot(root, show_hidden, respect_gitignore)
  return listing.list_with_snapshot(root, parent().read, show_hidden, respect_gitignore)
end

local function filter_git_status_lines(root, lines, snapshot)
  local filtered = {}
  for _, line in ipairs(lines or {}) do
    if git.status_for(snapshot, parent().entry_path(root, line)) then filtered[#filtered + 1] = line end
  end
  return filtered
end

local function filter_git_diff_lines(root, lines, snapshot)
  local filtered = {}
  for _, line in ipairs(lines or {}) do
    if git.status_for(snapshot, parent().entry_path(root, line)) then filtered[#filtered + 1] = line end
  end
  return filtered
end

local function merge_deleted_entries(...) return hook('merge_deleted_entries')(...) end

local function hide_deleted_expansions(...) return hook('hide_deleted_expansions')(...) end

local function reconcile_undone_materialization(bufnr)
  local reconcile = buffer_state.reconcile_undone_materialization
  if reconcile then return reconcile(bufnr) end
end

local function refresh_highlights(...) return hook('refresh_highlights')(...) end

local function refresh_icons(...) return hook('refresh_icons')(...) end

local function set_options(...) return hook('set_options')(...) end

local function start_git_status(...) return hook('start_git_status')(...) end

local function collapse_single_entry_paths(...)
  local collapse = buffer_state.collapse_single_entry_paths
  assert(type(collapse) == 'function', 'buffer.list collapse helper is unavailable')
  return collapse(...)
end

local function path_identity(path) return fs.path_identity(path, fs.stat(path)) end

local function add_identity(index, identity, value)
  if not identity then return end
  local function add(bucket, key)
    if not key then return end
    local entry = bucket[key]
    if not entry then
      entry = { count = 0 }
      bucket[key] = entry
    end
    entry.count = entry.count + 1
    if entry.count == 1 then entry.only = value end
    if entry.count > 1 then entry.only = nil end
  end
  add(index.by_path, identity.path)
  if identity.inode then
    add(index.by_inode, identity.inode)
  else
    add(index.unknown_by_path, identity.path)
  end
end

local function matching_identity_values(index, identity)
  if not identity then return nil, 0 end
  if not identity.inode then
    local entry = index.by_path[identity.path]
    return entry and entry.only, entry and entry.count or 0
  end
  local inode = index.by_inode[identity.inode]
  local unknown = index.unknown_by_path[identity.path]
  local count = (inode and inode.count or 0) + (unknown and unknown.count or 0)
  if count == 1 then return (inode and inode.only) or (unknown and unknown.only), count end
  return nil, count
end

local function identity_is_duplicated(identity, counts)
  if not identity then return false end
  if identity.inode then
    return (counts.by_inode[identity.inode] or 0) > 1 or (counts.unknown_by_path[identity.path] or 0) > 0
  end
  return (counts.by_path[identity.path] or 0) > 1
end

local function count_identity(counts, identity)
  if not identity then return end
  counts.by_path[identity.path] = (counts.by_path[identity.path] or 0) + 1
  if identity.inode then
    counts.by_inode[identity.inode] = (counts.by_inode[identity.inode] or 0) + 1
  else
    counts.unknown_by_path[identity.path] = (counts.unknown_by_path[identity.path] or 0) + 1
  end
end

local function modified_listing_reason()
  return 'cannot refresh a listing with unsaved edits; sync or discard them first'
end

local function modified_listing_at(root)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if
        name ~= ''
        and vim.bo[bufnr].filetype == constants.FILETYPE
        and vim.bo[bufnr].modified
        and fs.same_path(parent().root_for_buffer(bufnr), root)
      then
        return bufnr
      end
    end
  end
end

local function discard_left_clean_listing(source, target, open_in)
  if open_in ~= 'current' or source == target or not vim.api.nvim_buf_is_valid(source) then return end
  if #vim.fn.win_findbuf(source) > 0 then return end
  if vim.bo[source].filetype == constants.FILETYPE and not vim.bo[source].modified then
    pcall(vim.api.nvim_buf_delete, source, { force = false })
  end
end

-- Attach to the current buffer's directory without listing; the caller decides when to refresh.
function M.restore()
  local bufnr = vim.api.nvim_get_current_buf()
  local buffer_module = parent()
  local name = buffer_module.root_for_buffer(bufnr)
  return setmetatable({
    root = paths.root(name),
    current_entry = buffer_module.current_entry(),
  }, buffer_state.Buffer)
end

-- List a directory in an attached direct buffer.
function M.list(path, options)
  options = options or {}
  local root = paths.root(path)
  local configured = require('direct.config').options.buffers
  local reuse = options.reuse
  if reuse == nil then reuse = configured.reuse end
  local open_in = options.open_in
  if open_in == nil then open_in = configured.open_in end
  local source_bufnr = vim.api.nvim_get_current_buf()
  if reuse and not options.discard and modified_listing_at(root) then
    local reason = modified_listing_reason()
    ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
    return nil, reason
  end

  if not reuse and not options.discard then
    local modified = modified_listing_at(root)
    if modified then
      local answer = vim.fn.confirm(
        'A listing of ' .. root .. ' has unsaved edits. Switch to it instead?',
        '&Switch to existing listing\n&Open another listing\n&Cancel',
        1
      )
      if answer == 1 then
        vim.api.nvim_set_current_buf(modified)
        discard_left_clean_listing(source_bufnr, modified, open_in)
        return M.restore()
      end
      if answer ~= 2 then return nil, 'listing creation cancelled' end
    end
  end

  local buffer = parent().Buffer(root, options)
  local target_bufnr = vim.api.nvim_get_current_buf()
  local listed, err = buffer:list(options)
  if not listed then return nil, err end
  if not reuse then discard_left_clean_listing(source_bufnr, target_bufnr, open_in) end
  return buffer
end

-- ---------------------------------------------------------------------------
-- listing
-- ---------------------------------------------------------------------------

-- Restore the cursor to the pre-attach entry; leave it unchanged if that entry
-- no longer exists. Reset the column on a match.
function M.place_cursor(self, lines, row_identities, entry_identity)
  if self.current_entry == nil then return end
  local bufnr = vim.api.nvim_get_current_buf()
  for index, line in ipairs(lines) do
    local matches
    if row_identities and entry_identity then
      matches = fs.path_identities_match(row_identities[index], entry_identity)
    else
      local record = current_row_record(bufnr, index - 1)
      local path = row_path(self.root, record, line) or parent().entry_path(self.root, line)
      matches = fs.same_path(path, self.current_entry)
    end
    if matches then
      pcall(vim.api.nvim_win_set_cursor, 0, { index, 0 })
      return
    end
  end
end

-- Refresh the listing and restore cursor/options; mark unmodified after refresh.
--
-- (hardening): a directory can hold an entry whose NAME carries a
-- newline (or another control character / a tab). Such a name can never be a
-- buffer line -- `nvim_buf_set_lines` raises "'replacement string' item contains
-- newlines" -- so listing that directory used to abort the whole listing. The
-- representability guard (`action.path_reason`, the same one the history framing
-- uses) drops every unrepresentable line BEFORE the set, notifies per dropped
-- entry, and lists the survivors. A ' ' (space) name is NOT dropped: a space is
-- representable and must still list.
function M.list_buffer(self, options)
  options = options or {}
  local bufnr = vim.api.nvim_get_current_buf()
  if
    vim.bo[bufnr].filetype == constants.FILETYPE
    and vim.bo[bufnr].modified
    and not options.discard
    and not options.allow_modified
  then
    local reason = modified_listing_reason()
    ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
    return nil, reason
  end
  local old_state = states[bufnr]
  if old_state and old_state.git_status_cancel then
    old_state.git_status_cancel()
    old_state.git_status_cancel = nil
    old_state.git_status_request = nil
  end
  local view_git_status_only = old_state and old_state.view_git_status_only == true or false
  local view_git_diff_only = old_state and old_state.view_git_diff_only == true or false
  local git_diff_snapshot = old_state and old_state.git_diff_snapshot or false
  if options.git_diff_resolved then
    view_git_diff_only = options.git_diff_only == true
    git_diff_snapshot = options.git_diff_snapshot or false
  end
  local show_hidden_override
  if old_state and old_state.view_show_hidden_override and type(old_state.view_show_hidden) == 'boolean' then
    show_hidden_override = old_state.view_show_hidden
  end
  local respect_gitignore_override
  if
    old_state
    and old_state.view_respect_gitignore_override
    and type(old_state.view_respect_gitignore) == 'boolean'
  then
    respect_gitignore_override = old_state.view_respect_gitignore
  end
  local collapse_enabled = require('direct.config').options.collapse_single_entry_directories == true
  if
    old_state
    and old_state.view_collapse_single_entry_directories_override
    and type(old_state.view_collapse_single_entry_directories) == 'boolean'
  then
    collapse_enabled = old_state.view_collapse_single_entry_directories
  end
  local lines, snapshot, err = list_with_snapshot(self.root, show_hidden_override, respect_gitignore_override)
  if not lines then
    ui.notify('direct: cannot list ' .. tostring(self.root) .. ': ' .. tostring(err), vim.log.levels.ERROR)
    return nil, err
  end

  local safe = {}
  for _, line in ipairs(lines) do
    local reason = action_mod.path_reason(parent().entry_path(self.root, line))
    if reason ~= nil then
      ui.notify('direct: skipping unlistable entry (' .. reason .. '): ' .. line, vim.log.levels.ERROR)
    else
      safe[#safe + 1] = line
    end
  end

  local git_options = require('direct.config').options.git
  local show_deleted = git_options.enabled and git_options.show_deleted ~= false
  local git_snapshot = false
  if git_options.enabled then git_snapshot = nil end
  if git_options.enabled and options.git_status_resolved then git_snapshot = options.git_status or false end
  if view_git_status_only then safe = filter_git_status_lines(self.root, safe, git_snapshot) end
  if view_git_diff_only then safe = filter_git_diff_lines(self.root, safe, git_diff_snapshot) end
  local merged, deleted_paths = merge_deleted_entries(
    self.root,
    safe,
    show_deleted and git_snapshot or nil,
    snapshot.show_hidden,
    view_git_diff_only and git_diff_snapshot or nil
  )
  safe = merged
  if view_git_status_only then safe = filter_git_status_lines(self.root, safe, git_snapshot) end
  if view_git_diff_only then safe = filter_git_diff_lines(self.root, safe, git_diff_snapshot) end
  local unlistable_deleted = {}
  for path in pairs(deleted_paths) do
    local reason = action_mod.path_reason(path)
    if reason then
      deleted_paths[path] = nil
      unlistable_deleted[vim.fs.normalize(path)] = true
      ui.notify('direct: skipping unlistable Git-deleted entry (' .. reason .. '): ' .. path, vim.log.levels.ERROR)
    end
  end
  if next(unlistable_deleted) then
    local filtered = {}
    for _, line in ipairs(safe) do
      if not unlistable_deleted[vim.fs.normalize(parent().entry_path(self.root, line))] then
        filtered[#filtered + 1] = line
      end
    end
    safe = filtered
  end
  if next(deleted_paths) == nil then deleted_paths = {} end

  local collapsed_components, nested_snapshots
  if collapse_enabled then
    local collapse_err
    safe, collapsed_components, nested_snapshots, collapse_err = collapse_single_entry_paths(self.root, safe, {
      capture = true,
      show_hidden = snapshot.show_hidden,
      respect_gitignore = snapshot.respect_gitignore,
      status_only = view_git_status_only,
      git_status = git_snapshot,
      git_diff_only = view_git_diff_only,
      git_diff = git_diff_snapshot,
      deleted_paths = deleted_paths,
    })
    if not safe then
      ui.notify('direct: cannot inspect single-entry directories: ' .. tostring(collapse_err), vim.log.levels.ERROR)
      return nil, collapse_err
    end
  end

  reconcile_undone_materialization(bufnr)
  old_state = states[bufnr]
  local new_identities, new_identity_by_path, new_counts =
    {}, {}, {
      by_path = {},
      by_inode = {},
      unknown_by_path = {},
    }
  for index, line in ipairs(safe) do
    local identity = path_identity(parent().entry_path(self.root, line))
    new_identities[index] = identity
    if identity then new_identity_by_path[identity.path] = identity end
    count_identity(new_counts, identity)
  end

  local old_expanded, old_deleted = {}, {}
  local old_known_children = {}
  local deleted_visibility_changed = old_state and old_state.view_show_deleted ~= show_deleted
  local old_index = { by_path = {}, by_inode = {}, unknown_by_path = {} }
  if old_state and not deleted_visibility_changed then
    old_expanded = old_state.expanded or {}
    if not show_deleted then
      old_expanded = vim.deepcopy(old_expanded)
      hide_deleted_expansions(old_expanded, old_state.rows)
    end
    old_known_children = old_state.known_children or {}
    local old_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local old_row_ids = row_ids_by_row(bufnr)
    for row, line in ipairs(old_lines) do
      local id = old_row_ids[row - 1]
      local rec = id and old_state.rows[id]
      -- Reuse a root only while its extmark still identifies the unchanged
      -- row. Edited text may happen to equal another root's name; that is not
      -- an identity change.
      if rec and rec.kind == 'root' and rec.deleted_kind then
        old_deleted[vim.fs.normalize(rec.path)] = rec
      elseif rec and rec.kind == 'root' and line == rec.text and line == rec.name and rec.path then
        -- Use the current identity for a same-spelling row, preserving the
        -- established behavior for entries replaced at that path. Keep the
        -- live lookup for old paths without a visible same-spelling row,
        -- because an alias may still point to that entry.
        local identity = rec.identity and new_identity_by_path[rec.identity.path]
        if not identity then identity = path_identity(rec.path) end
        local candidate = { record = rec, identity = identity }
        add_identity(old_index, candidate.identity, candidate)
      end
    end
  end

  local state = {
    root = self.root,
    rows = {},
    expanded = old_expanded,
    -- This survives collapse and re-listing so a directory previously observed
    -- to be non-empty cannot be trashed just because its rows are hidden.
    known_children = old_known_children,
    root_ids = {},
    next_id = old_state and old_state.next_id or 0,
    display_ids = {},
    materialization_undos = {},
    directory_snapshots = old_state and not deleted_visibility_changed and vim.deepcopy(
      old_state.directory_snapshots or {}
    ) or {},
    materialization_recoveries = old_state and not deleted_visibility_changed and vim.deepcopy(
      old_state.materialization_recoveries or {}
    ) or {},
    collapse_undos = old_state and not deleted_visibility_changed and vim.deepcopy(old_state.collapse_undos or {})
      or {},
    view_show_hidden = snapshot.show_hidden,
    view_respect_gitignore = snapshot.respect_gitignore,
    view_collapse_single_entry_directories = collapse_enabled,
    view_collapse_single_entry_directories_override = old_state
        and old_state.view_collapse_single_entry_directories_override
      or false,
    view_show_deleted = show_deleted,
    view_show_hidden_override = old_state and old_state.view_show_hidden_override or false,
    view_respect_gitignore_override = old_state and old_state.view_respect_gitignore_override or false,
    view_git_status_only = view_git_status_only,
    view_git_diff_only = view_git_diff_only,
    git_diff_snapshot = git_diff_snapshot,
    collapse_single_entry_directories = collapse_enabled,
    git_status = git_snapshot,
    git_status_pending = git_options.enabled and not options.git_status_resolved,
    git_expand_all = old_state and old_state.git_expand_all == true or false,
  }
  set_directory_snapshot(state, snapshot)
  for _, child_snapshot in ipairs(nested_snapshots or {}) do
    set_directory_snapshot(state, child_snapshot)
  end
  local roots = {}
  local used_root = {}
  for line_index, line in ipairs(safe) do
    local path = parent().entry_path(self.root, line)
    local identity = new_identities[line_index]
    local deleted_kind = deleted_paths[vim.fs.normalize(path)]
    local rec
    if deleted_kind then
      rec = old_deleted[vim.fs.normalize(path)]
    else
      local candidate, candidate_count = matching_identity_values(old_index, identity)
      rec = candidate_count == 1 and candidate and candidate.record or nil
    end
    -- Equivalent spellings may occur more than once (for example two symlink
    -- aliases). Reuse only a unique prior identity for a unique new row.
    if rec and not identity_is_duplicated(identity, new_counts) and not used_root[rec.id] then
      used_root[rec.id] = true
    else
      rec = { id = next_id(state), kind = 'root' }
    end
    rec.kind, rec.name, rec.text, rec.depth = 'root', line, line, 0
    rec.deleted_kind = deleted_kind
    rec.path = parent().entry_path(self.root, line)
    rec.identity = identity
    local path_components = collapsed_components and collapsed_components[line_index]
    rec.collapsed_components = path_components and #path_components > 1 and path_components or nil
    state.rows[rec.id] = rec
    state.root_ids[#state.root_ids + 1] = rec.id
    roots[#roots + 1] = rec
  end

  local rendered = {}
  local spaces_per_level = indent_size()
  local function render_children(parent_id, parent_path, depth)
    local expansion = state.expanded[parent_id]
    if not expansion then return end
    for _, child in ipairs(expansion.children) do
      child.kind, child.parent, child.depth = 'child', parent_id, depth
      child.path = parent().entry_path(parent_path, child.name)
      child.text = string.rep(' ', spaces_per_level * depth) .. child.name
      state.rows[child.id] = child
      rendered[#rendered + 1] = {
        text = child.text,
        id = child.id,
        identity = path_identity(child.path),
      }
      state.display_ids[#state.display_ids + 1] = child.id
      render_children(child.id, child.path, depth + 1)
    end
  end
  for root_index, rec in ipairs(roots) do
    rendered[#rendered + 1] = {
      text = rec.text,
      id = rec.id,
      identity = new_identities[root_index],
    }
    state.display_ids[#state.display_ids + 1] = rec.id
    if is_dir_line(rec.name) then render_children(rec.id, rec.path, 1) end
  end
  for id in pairs(state.expanded) do
    if not state.rows[id] then state.expanded[id] = nil end
  end
  for id in pairs(state.known_children) do
    if not state.rows[id] then state.known_children[id] = nil end
  end

  local display = {}
  local display_identities = {}
  for index, row in ipairs(rendered) do
    display[index] = row.text
    display_identities[index] = row.identity
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  -- Initial listings and committed internal refreshes establish a fresh text
  -- undo baseline. Ordinary re-lists preserve prior expansion undo sequences.
  local reset_undo = options.reset_undo or options.discard or not old_state
  local undo_levels = vim.bo[bufnr].undolevels
  if reset_undo then vim.bo[bufnr].undolevels = -1 end
  if old_state then old_state.suppress_deleted_guard = true end
  local ok, seterr = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, display)
  if old_state then old_state.suppress_deleted_guard = nil end
  if reset_undo then vim.bo[bufnr].undolevels = undo_levels end
  if not ok then
    ui.notify('direct: cannot list ' .. tostring(self.root) .. ': ' .. tostring(seterr), vim.log.levels.ERROR)
    return nil, seterr
  end
  states[bufnr] = state
  set_git_timeout_indicator(bufnr, state)
  vim.b[bufnr].direct_text_undo_mode = false
  for row, item in ipairs(rendered) do
    set_row_mark(bufnr, row - 1, item.id)
  end
  local row_ids = row_ids_by_row(bufnr)
  refresh_highlights(bufnr, state, row_ids)
  refresh_icons(bufnr, state, row_ids)
  state.materialization_seq = vim.fn.undotree().seq_cur
  set_options(bufnr)
  self:place_cursor(display, display_identities, self.current_entry and path_identity(self.current_entry) or nil)
  if self.current_entry == nil then
    pcall(vim.api.nvim_win_set_cursor, 0, {
      math.max(1, math.min(cursor[1], #display)),
      cursor[2],
    })
  end
  vim.bo[bufnr].modified = false
  if state.git_status_pending then start_git_status(bufnr, state, git_options.timeout_ms) end
  require('direct.events').emit('DirectListPost', {
    root = self.root,
    actions = {},
    bufnr = bufnr,
  })
  return true
end
return M
