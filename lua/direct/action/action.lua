-- lua/direct/action.lua -- filesystem action factories and execution safeguards.
-- Grouped moves share a staging path so swaps and chains can be undone without
-- overwriting a name whose contents have not yet been saved elsewhere.

local M = {}

M.fs = require('direct.fs')
M.paths = require('direct.paths')
M.ui = require('direct.ui')
local trash_metadata = require('direct.trash.metadata')

local function lstat(path)
  local ok, stat = pcall(vim.uv.fs_lstat, path)
  return ok and stat or nil
end

-- A restored trash slot keeps an empty reservation marker so a later delete
-- cannot reuse the slot while history can still reverse to it. Register entries
-- pointing at such a slot must fall back to the original path.
M.trash_reserved = trash_metadata.reserved

-- Bound repeated asynchronous answers that still name an occupied destination.
-- On exhaustion, skip the entry; never write to an existing target.
M.PASTE_CLASH_ATTEMPTS = 10

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- rel(path) -> the CWD-relative spelling of a path. `:p:.` resolves the path
-- first so a lexical mismatch (e.g. /tmp vs /private/tmp) cannot suppress the
-- relative form; a path equal to the cwd yields '.'. Strip the trailing
-- filesystem separator from directories so their descriptions do not add `/`
-- (Paste's describe adds its own separator).
function M.rel(path)
  if type(path) ~= 'string' then return tostring(path) end
  local rel = vim.fn.fnamemodify(path, ':p:.')
  if rel == '' then return '.' end
  rel = M.paths.strip_trailing_separator(rel)
  if rel == '' then return M.paths.separator end
  return rel
end

-- Close buffers for the resolved pathname before destructive actions. Do not
-- use inode identity: that would also close buffers for distinct hard links.
-- realpath normalizes symlink prefixes, `..`, and trailing separators while keeping
-- different hard-link names distinct.
-- Guard buffer API work so an unavailable buffer cannot interrupt a destructive
-- action; report failures through the return value rather than raising.
function M.close_src_buffer(src)
  if type(src) ~= 'string' then return true end
  local target = M.fs.realpath(src)
  local ok = pcall(function()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= '' and M.fs.realpath(name) == target then pcall(vim.api.nvim_buf_delete, bufnr, { force = true }) end
    end
  end)
  if not ok then return nil, 'failed to close source buffers' end
  return true
end

-- split_names(str) -> the entry-name list of a serialized `p`/`up` field.
-- Empty fields and repeated spaces deserialize to an empty list or omit empty
-- names; an empty name can never be a real entry.
function M.split_names(str)
  if type(str) ~= 'string' then return {} end
  return vim.split(str, ' ', { plain = true, trimempty = true })
end

-- entry_name_reason(name) -> nil when `name` is one valid basename component.
function M.entry_name_reason(name)
  if type(name) ~= 'string' or name == '' then return 'empty' end
  if not M.paths.valid_utf8(name) then return 'invalid UTF-8' end
  if name == '.' or name == '..' or name:find('/', 1, true) ~= nil then return 'not a basename component' end
  if name:find('\t', 1, true) ~= nil then return 'contains a tab' end
  if name:find('%c') ~= nil then return 'contains a control character' end
  return nil
end

-- path_reason(path) -> nil when a path is valid UTF-8 and has no control bytes.
-- Tab keeps a specific diagnostic; all controls, including NUL and newlines,
-- are rejected before a JSONL record is built.
function M.path_reason(path)
  if type(path) ~= 'string' then return 'invalid path' end
  if path == '' then return 'invalid path' end
  if not M.paths.valid_utf8(path) then return 'invalid UTF-8' end
  if path:find('\t', 1, true) ~= nil then return 'contains a tab' end
  if path:find('%c') ~= nil then return 'contains a control character' end
  return nil
end

-- Build source/destination pairs in ascending source-name order so serialization
-- and clash-prompt order do not depend on the caller's input order.
local function zipped(src_names, dst_names)
  local pairs_list = {}
  local n = math.min(#(src_names or {}), #(dst_names or {}))
  for i = 1, n do
    local ps, pd = src_names[i], dst_names[i]
    if type(ps) == 'string' and type(pd) == 'string' and ps ~= '' and pd ~= '' then
      pairs_list[#pairs_list + 1] = { src = ps, dst = pd }
    end
  end
  table.sort(pairs_list, function(a, b)
    if a.src == b.src then return false end
    return a.src < b.src
  end)
  return pairs_list
end

-- split_pairs(pairs_list) -> src_names, dst_names (the two serialized lists).
function M.split_pairs(pairs_list)
  local src_names, dst_names = {}, {}
  for _, pair in ipairs(pairs_list or {}) do
    src_names[#src_names + 1] = pair.src
    dst_names[#dst_names + 1] = pair.dst
  end
  return src_names, dst_names
end

-- ---------------------------------------------------------------------------
-- Single-entry actions
-- ---------------------------------------------------------------------------

local function move_progress(src, dst)
  local announced, echo_shown = false, false
  local function report(stage, total)
    if stage == 'copying' and not announced then
      announced = true
      M.ui.notify(
        'direct: copying ' .. M.rel(src) .. ' to ' .. M.rel(dst) .. ' across filesystems',
        vim.log.levels.INFO
      )
    elseif type(stage) == 'number' and (stage == total or stage == 1 or stage % 25 == 0) then
      echo_shown = true
      M.ui.notify(string.format('direct: copying %d/%d files', stage, total), vim.log.levels.INFO, { ephemeral = true })
    end
  end
  local function clear()
    if echo_shown then M.ui.notify('', vim.log.levels.INFO, { ephemeral = true }) end
  end
  return report, clear
end

function M.Move(src, dst)
  local self = { name = 'mv', _kind = 'mv', src = src, dst = dst }
  self._execute = function()
    if M.fs.taken(self.dst) and not M.fs.same_entry(self.src, self.dst) then
      return nil, 'destination exists: ' .. tostring(self.dst)
    end
    local ok, close_err = M.close_src_buffer(self.src)
    if not ok then return nil, close_err end
    return M.fs.rename(self.src, self.dst)
  end
  self._execute_async = function(callback)
    if M.fs.taken(self.dst) and not M.fs.same_entry(self.src, self.dst) then
      callback(false, nil, 'destination exists: ' .. tostring(self.dst))
      return
    end
    local ok, err = M.close_src_buffer(self.src)
    if not ok then
      callback(false, nil, err)
      return
    end
    local progress, clear_progress = move_progress(self.src, self.dst)
    M.fs.rename_async(self.src, self.dst, function(moved, result, move_err)
      clear_progress()
      callback(moved, result, move_err)
    end, progress)
  end
  self['do'] = function() return M.execute(self) end
  function self.describe() return 'Moved ' .. M.rel(self.src) .. ' to ' .. M.rel(self.dst) end
  return self
end

-- Remove(src, [dst]) -- resolve an omitted trash destination at construction so
-- the action is immediately serializable. Keep an explicit `dst` (used by
-- deserialize) verbatim so `Restore` reverses to the exact entry. Defer
-- resolution failures to `do`, which returns nil, err for callers to handle.
local function warn_cross_device_trash(src, trash)
  local source_stat, trash_stat = lstat(src), M.fs.stat(trash)
  if
    source_stat
    and source_stat.type == 'directory'
    and trash_stat
    and source_stat.dev ~= nil
    and trash_stat.dev ~= nil
    and source_stat.dev ~= trash_stat.dev
  then
    M.ui.notify(
      'direct: deleting ' .. M.rel(src) .. ' copies its directory tree across filesystems to trash; this may take time',
      vim.log.levels.WARN
    )
  end
end

local function trash_target(self)
  if not self.dst then
    local trash, err = M.paths.ensure_data_dir('trash')
    if not trash then return nil, err end
    self.dst = trash_metadata.first_free(trash, self.src)
  end
  local trash, err = M.paths.ensure_data_dir('trash')
  if not trash then return nil, err end
  return trash
end

local function rollback_trash_metadata(trash_path)
  local cleared, clear_err = trash_metadata.clear(trash_path)
  if not cleared then
    M.ui.notify(
      'direct: could not remove unused trash metadata '
        .. trash_metadata.path(trash_path)
        .. ': '
        .. tostring(clear_err),
      vim.log.levels.WARN
    )
  end
end

local function prepare_remove(self, is_directory)
  local trash, err = trash_target(self)
  if not trash then return nil, err end
  local ok, close_err = M.close_src_buffer(self.src)
  if not ok then return nil, close_err end
  if is_directory then warn_cross_device_trash(self.src, trash) end
  if M.fs.taken(self.dst) then return nil, 'destination exists: ' .. tostring(self.dst) end
  local recorded, record_err = trash_metadata.write(self.dst, self.src)
  if not recorded then return nil, 'could not record trash metadata: ' .. tostring(record_err) end
  return true
end

local function make_remove(src, dst, name, is_directory)
  local self = { name = name, _kind = name, src = src }
  if dst ~= nil then
    self.dst = dst
  else
    local trash = M.paths.data_dir_path('trash')
    if trash then self.dst = trash_metadata.first_free(trash, src) end
  end
  self._execute = function()
    local prepared, prepare_err = prepare_remove(self, is_directory)
    if not prepared then return nil, prepare_err end
    local moved, move_err = M.fs.rename(self.src, self.dst)
    if not moved then
      rollback_trash_metadata(self.dst)
      return nil, move_err
    end
    return moved
  end
  self['do'] = function() return M.execute(self) end
  function self.describe() return 'Removed ' .. M.rel(self.src) end
  self._execute_async = function(callback)
    local prepared, prepare_err = prepare_remove(self, is_directory)
    if not prepared then
      callback(false, nil, prepare_err)
      return
    end
    local progress, clear_progress = move_progress(self.src, self.dst)
    M.fs.rename_async(self.src, self.dst, function(moved, result, move_err)
      clear_progress()
      if not moved then rollback_trash_metadata(self.dst) end
      callback(moved, result, move_err)
    end, progress)
  end
  return self
end

function M.Remove(src, dst) return make_remove(src, dst, 'rm', false) end

function M.RemoveDirectory(src, dst) return make_remove(src, dst, 'rmdir', true) end

local function prepare_restore(self) return M.close_src_buffer(self.src) end

local function finish_restore(self, is_directory)
  local reserved, reserve_err = trash_metadata.write_reservation(self.src, self.dst)
  if not reserved then
    M.ui.notify(
      'direct: restored '
        .. (is_directory and 'directory' or 'entry')
        .. ' but could not reserve its trash slot '
        .. self.src
        .. ' ('
        .. tostring(reserve_err)
        .. ')',
      vim.log.levels.WARN
    )
  end
  if not is_directory then
    -- Keep the restored slot occupied until history can no longer reverse it.
    M.fs.touch(self.src)
    return
  end

  -- Directory slots use an empty directory marker so rename can replace it.
  local made, make_err = M.fs.mkdir_exclusive(self.src)
  if not made then
    M.ui.notify(
      'direct: restored directory, but could not reserve its trash slot ' .. self.src .. ': ' .. tostring(make_err),
      vim.log.levels.WARN
    )
  end
end

local function make_restore(src, dst, name, is_directory)
  local self = { name = name, _kind = name, src = src, dst = dst }
  self._execute = function()
    local ok, err = prepare_restore(self)
    if not ok then return nil, err end
    local restored, restore_err = M.fs.rename(self.src, self.dst)
    if restored then finish_restore(self, is_directory) end
    return restored, restore_err
  end
  self._execute_async = function(callback)
    local ok, err = prepare_restore(self)
    if not ok then
      callback(false, nil, err)
      return
    end
    local progress, clear_progress = move_progress(self.src, self.dst)
    M.fs.rename_async(self.src, self.dst, function(restored, result, restore_err)
      clear_progress()
      if restored then finish_restore(self, is_directory) end
      callback(restored, result, restore_err)
    end, progress)
  end
  self['do'] = function() return M.execute(self) end
  function self.describe() return 'Restored ' .. M.rel(self.dst) end
  return self
end

function M.Restore(src, dst) return make_restore(src, dst, 'rs', false) end

function M.RestoreDirectory(src, dst) return make_restore(src, dst, 'rsdir', true) end

function M.Touch(dst)
  local self = { name = 'touch', _kind = 'touch', dst = dst }
  self._execute = function()
    if M.fs.taken(self.dst) then return nil, 'destination exists: ' .. tostring(self.dst) end
    return M.fs.touch(self.dst)
  end
  self['do'] = function() return M.execute(self) end
  function self.describe() return 'Created ' .. M.rel(self.dst) end
  return self
end

function M.MakeDirectory(dst)
  local self = { name = 'mkdir', _kind = 'mkdir', dst = dst }
  self._execute = function()
    if M.fs.taken(self.dst) then return nil, 'destination exists: ' .. tostring(self.dst) end
    return M.fs.mkdir_exclusive(self.dst)
  end
  self['do'] = function() return M.execute(self) end
  function self.describe() return 'Created ' .. M.rel(self.dst) end
  return self
end

-- ---------------------------------------------------------------------------
-- Multi-actions
-- ---------------------------------------------------------------------------

-- Paste sources normally live in the register content directory. A
-- delete-backed register stores a manifest that points at trash payloads, with
-- the original path as a fallback after undo restores the entry.
local function paste_source(src, name)
  local ok, register = pcall(require, 'direct.register')
  if ok and type(register.resolve) == 'function' then
    local path = register.resolve(src, name)
    if path then return path end
  end
  return M.fs.join(src, name)
end

-- Paste/history hooks are a single contract: before/after-copy journal one
-- entry, before-prompt releases the history lock, after-prompt resumes it (or
-- returns 'pending' and calls resume later), and on-copy-conflict clears the
-- attempted journal entry. Only callback execution uses these hooks.
local process_next_paste_entry

local function finish_paste(run, ok, result, err)
  if run.outcome then return end
  run.outcome = { ok = ok, result = result, err = err }
  if run.asynchronous or ok then run.action.renames = run.copied end
  if run.asynchronous then run.callback(ok, result, err) end
end

local function fail_paste(run, err) finish_paste(run, false, nil, tostring(err or 'paste failed')) end

local function skip_paste_entry(run, pair, notify)
  if notify then M.ui.notify('Skipped ' .. pair.src, vim.log.levels.WARN) end
  run.index = run.index + 1
  process_next_paste_entry(run)
end

local function copy_paste_payload(full_src, full_dst, stat)
  if stat.type == 'file' then return M.fs.copy_file_exclusive(full_src, full_dst) end
  if stat.type == 'directory' then return M.fs.copy_tree_exclusive(full_src, full_dst) end
  return true
end

local function copy_paste_pair(run, pair, full_src, full_dst, stat)
  local action = run.action
  if run.asynchronous and type(action._before_copy) == 'function' then
    local ready, ready_err = action._before_copy(pair, full_src, full_dst)
    if not ready then
      fail_paste(run, ready_err or 'could not journal paste entry')
      return
    end
  end

  local called, ok, extra, code
  if run.asynchronous then
    called, ok, extra, code = pcall(copy_paste_payload, full_src, full_dst, stat)
  else
    ok, extra = copy_paste_payload(full_src, full_dst, stat)
    called = true
  end
  if not called then
    fail_paste(run, ok)
    return
  end
  if not ok then
    if run.asynchronous and code == 'EEXIST' and type(action._on_copy_conflict) == 'function' then
      local cleared, clear_err = action._on_copy_conflict(pair)
      if not cleared then
        fail_paste(run, clear_err or extra or code or 'destination exists')
        return
      end
    end
    fail_paste(run, extra or code or 'copy failed')
    return
  end
  if stat.type == 'directory' and type(extra) == 'table' and #extra > 0 then
    M.ui.notify(
      'Skipped ' .. #extra .. ' ' .. (#extra == 1 and 'entry' or 'entries') .. ' that cannot be copied: ' .. full_src,
      vim.log.levels.WARN
    )
  end
  run.last = full_dst
  run.copied[#run.copied + 1] = { src = pair.src, dst = pair.dst }
  run.index = run.index + 1
  if run.asynchronous and type(action._after_copy) == 'function' then
    local recorded, record_err = action._after_copy(pair, full_src, full_dst)
    if not recorded then
      fail_paste(run, record_err or 'could not record pasted entry')
      return
    end
  end
  process_next_paste_entry(run)
end

local function request_paste_name(run, pair, full_src, stat, attempts)
  local action = run.action
  if attempts >= M.PASTE_CLASH_ATTEMPTS then
    skip_paste_entry(run, pair, true)
    return
  end
  local current = M.fs.join(action.dst, pair.dst)
  local entry_type = M.fs.is_file(current) and 'File' or 'Directory'
  if type(action._before_prompt) == 'function' then
    local called, released, release_err = pcall(action._before_prompt, pair, full_src, current)
    if not called or not released then
      fail_paste(run, called and release_err or released or 'could not release the history lock for paste prompt')
      return
    end
  end
  local called, started, start_err = pcall(
    M.ui.input,
    entry_type .. ' already exists. Paste as: ',
    pair.src,
    'file',
    function(answer)
      if answer == nil or M.entry_name_reason(answer) ~= nil then
        skip_paste_entry(run, pair, true)
        return
      end
      pair.dst = answer
      local resumed = false
      local function continue_after_prompt(ready, resume_err)
        if resumed then return end
        resumed = true
        if ready == 'clash' then return request_paste_name(run, pair, full_src, stat, attempts + 1) end
        if not ready then
          return fail_paste(run, resume_err or 'could not reacquire the history lock after paste prompt')
        end
        local chosen = M.fs.join(action.dst, pair.dst)
        if M.fs.taken(chosen) then
          request_paste_name(run, pair, full_src, stat, attempts + 1)
        else
          copy_paste_pair(run, pair, full_src, chosen, stat)
        end
      end
      if type(action._after_prompt) == 'function' then
        local resumed_called, ready, resume_err =
          pcall(action._after_prompt, pair, full_src, answer, continue_after_prompt)
        if not resumed_called then return fail_paste(run, ready) end
        if ready ~= 'pending' then continue_after_prompt(ready, resume_err) end
      else
        continue_after_prompt(true)
      end
    end,
    function(input_err) fail_paste(run, input_err) end
  )
  if not called then
    fail_paste(run, started)
  elseif started ~= true then
    fail_paste(run, start_err or 'could not start paste input')
  end
end

process_next_paste_entry = function(run)
  local action = run.action
  if run.index > #action.renames then
    local result = run.last
    if not run.asynchronous and result == nil then result = true end
    finish_paste(run, true, result, nil)
    return
  end
  local pair = action.renames[run.index]
  local full_src = paste_source(action.src, pair.src)
  local full_dst = M.fs.join(action.dst, pair.dst)
  local stat = M.fs.stat(full_src)
  if not stat then
    run.index = run.index + 1
    process_next_paste_entry(run)
  elseif stat.type ~= 'file' and stat.type ~= 'directory' then
    if run.asynchronous then
      M.ui.notify('Skipped unsupported register entry: ' .. full_src, vim.log.levels.WARN)
      run.index = run.index + 1
      process_next_paste_entry(run)
    else
      run.copied[#run.copied + 1] = { src = pair.src, dst = pair.dst }
      run.last = full_dst
      run.index = run.index + 1
      process_next_paste_entry(run)
    end
  elseif M.fs.taken(full_dst) then
    if run.asynchronous then
      request_paste_name(run, pair, full_src, stat, 0)
    else
      fail_paste(run, 'paste requires async execution for a destination clash: ' .. tostring(full_dst))
    end
  else
    copy_paste_pair(run, pair, full_src, full_dst, stat)
  end
end

local function execute_paste(action, callback)
  local run = {
    action = action,
    callback = callback,
    asynchronous = type(callback) == 'function',
    copied = {},
    index = 1,
  }
  process_next_paste_entry(run)
  if not run.asynchronous then return run.outcome.result, run.outcome.err end
end

-- Sync and callback execution share the same paste state machine; only clash
-- prompting and the history hooks require callback execution.
function M.Paste(src, dst, src_names, dst_names)
  local self = {
    name = 'p',
    _kind = 'p',
    src = src,
    dst = dst,
    renames = zipped(src_names, dst_names),
  }
  self._execute = function() return execute_paste(self) end
  self._execute_async = function(callback) execute_paste(self, callback) end
  self['do'] = function() return M.execute(self) end
  function self.describe() return 'Pasted into ' .. M.rel(self.dst) .. M.paths.separator end
  return self
end

local function unpaste_refusal(reason)
  M.ui.notify('direct: Unpaste refused: ' .. tostring(reason), vim.log.levels.ERROR)
  return nil, reason
end

local function compare_unpaste_contents(path, reference)
  local ok, matches, err = pcall(M.fs.same_contents, path, reference)
  if not ok then return nil, tostring(matches) end
  return matches, err
end

local function restore_unpaste_captures(captured)
  local failures = {}
  for i = #captured, 1, -1 do
    local item = captured[i]
    if M.fs.taken(item.quarantine) then
      local called, restored, err = pcall(M.fs.rename_noreplace, item.quarantine, item.path, item.identity)
      if not called then
        err, restored = tostring(restored), nil
      end
      if not restored then
        failures[#failures + 1] = item.quarantine
        M.ui.notify(
          'direct: could not restore Unpaste quarantine '
            .. item.quarantine
            .. ' to '
            .. item.path
            .. ' ('
            .. tostring(err)
            .. '); quarantine preserved',
          vim.log.levels.ERROR
        )
      end
    end
  end
  return failures
end

local function capture_unpaste_item(item)
  if item.quarantine then
    local called, moved, err = pcall(M.fs.rename_noreplace, item.path, item.quarantine, item.identity)
    if not called then
      err, moved = tostring(moved), nil
    end
    if not moved then return nil, err end
    local identity, stat = M.fs.entry_identity(item.quarantine)
    if identity == nil or identity.inode == nil or item.identity == nil or identity.inode ~= item.identity.inode then
      return nil, 'captured entry identity differs from the inspected source'
    end
    item.identity = identity
    item.kind = stat and stat.type or nil
    return true
  end
  for _ = 1, 100 do
    local quarantine = M.fs.unique_temp_path(M.fs.dirname(item.path), 'unpaste')
    if type(quarantine) ~= 'string' then return nil, 'could not allocate a unique Unpaste quarantine' end
    local called, moved, err, code = pcall(M.fs.rename_noreplace, item.path, quarantine, item.identity)
    if not called then
      err, moved = tostring(moved), nil
    end
    if moved then
      item.quarantine = quarantine
      local identity, stat = M.fs.entry_identity(quarantine)
      if identity == nil or identity.inode == nil then return nil, 'could not verify captured entry identity' end
      if item.identity == nil or item.identity.inode ~= identity.inode then
        return nil, 'captured entry identity differs from the inspected source'
      end
      item.identity = identity
      item.kind = stat and stat.type or nil
      return true
    end
    if code ~= 'EEXIST' and not tostring(err):find('destination exists', 1, true) then return nil, err end
  end
  return nil, 'could not allocate a unique Unpaste quarantine'
end

local function preflight_unpaste(self)
  -- A re-yank changes the register pointer. The old content path is not enough
  -- to authorize deletion if the live register no longer refers to it.
  local current_register, register_err = require('direct.register').content()
  if current_register == nil or current_register ~= self.dst then
    return nil, register_err or 'register is missing or was re-yanked'
  end

  -- Validate the complete operation without mutation. Files compare bytes;
  -- directories compare exact descendants; symlinks compare readlink targets
  -- without following them.
  local items = {}
  for _, pair in ipairs(self.renames) do
    local path = M.fs.join(self.src, pair.src)
    local reference = require('direct.register').resolve(self.dst, pair.dst) or M.fs.join(self.dst, pair.dst)
    local identity, stat = M.fs.entry_identity(path)
    if identity == nil or identity.inode == nil then return nil, 'cannot inspect pasted entry: ' .. path end
    if not stat or (stat.type ~= 'file' and stat.type ~= 'directory' and stat.type ~= 'link') then
      return nil, 'unsupported pasted entry type: ' .. path
    end
    local matches, compare_err = compare_unpaste_contents(path, reference)
    if matches ~= true then
      return nil,
        'pasted entry does not match register content: '
          .. path
          .. (compare_err and (' (' .. tostring(compare_err) .. ')') or '')
    end
    local item = {
      path = path,
      reference = reference,
      identity = identity,
      kind = stat.type,
      pair = pair,
    }
    local planned = self._journal_items and self._journal_items[#items + 1]
    if planned then
      if planned.src ~= pair.src or planned.dst ~= pair.dst or planned.identity.inode ~= identity.inode then
        return nil, 'journaled Unpaste plan no longer matches: ' .. path
      end
      item.quarantine = planned.quarantine
    end
    items[#items + 1] = item
  end
  return items
end

local function begin_unpaste_recovery(self, items)
  if type(self._on_unpaste_begin) == 'function' then
    local ready, ready_err = self._on_unpaste_begin(items)
    if not ready then return nil, 'could not prepare Unpaste recovery: ' .. tostring(ready_err) end
    self._journal_active = true
  end
  return true
end

local function capture_unpaste_items(self, items)
  local captured = {}
  for _, item in ipairs(items) do
    captured[#captured + 1] = item
    local ok, err = capture_unpaste_item(item)
    if not ok then
      local reason = 'could not capture pasted entry: ' .. item.path .. ' (' .. tostring(err) .. ')'
      if not self._journal_active then
        restore_unpaste_captures(captured)
      else
        for _, captured_item in ipairs(captured) do
          if M.fs.taken(captured_item.quarantine) then
            M.ui.notify('direct: Unpaste quarantine preserved at ' .. captured_item.quarantine, vim.log.levels.ERROR)
          end
        end
      end
      return nil, reason
    end
    if type(self._after_unpaste_capture) == 'function' then
      local recorded, record_err = self._after_unpaste_capture(#captured, item)
      if not recorded then return nil, 'could not record captured Unpaste entry: ' .. tostring(record_err) end
    end
    local matches, compare_err = compare_unpaste_contents(item.quarantine, item.reference)
    if matches ~= true then
      local reason = 'captured entry no longer matches register content: '
        .. item.path
        .. (compare_err and (' (' .. tostring(compare_err) .. ')') or '')
      if not self._journal_active then
        restore_unpaste_captures(captured)
      else
        M.ui.notify('direct: Unpaste quarantine preserved at ' .. item.quarantine, vim.log.levels.ERROR)
      end
      return nil, reason
    end
  end
  return captured
end

local function prepare_unpaste_deletion(self, captured)
  if type(self._before_unpaste_delete) == 'function' then
    local ready, ready_err = self._before_unpaste_delete(captured)
    if not ready then return nil, 'could not prepare Unpaste deletion: ' .. tostring(ready_err) end
  end
  return true
end

local function delete_unpaste_items(self, captured)
  for i, item in ipairs(captured) do
    local current = M.fs.entry_identity(item.quarantine)
    if current == nil or current.inode == nil or current.inode ~= item.identity.inode then
      M.ui.notify('direct: Unpaste quarantine changed; preserved at ' .. item.quarantine, vim.log.levels.ERROR)
      for j = i + 1, #captured do
        if M.fs.taken(captured[j].quarantine) then
          M.ui.notify('direct: Unpaste entry preserved at ' .. captured[j].quarantine, vim.log.levels.ERROR)
        end
      end
      return nil, 'captured entry changed before deletion: ' .. item.quarantine
    end
    local matches, compare_err = compare_unpaste_contents(item.quarantine, item.reference)
    if matches ~= true then
      M.ui.notify('direct: Unpaste entry preserved at ' .. item.quarantine, vim.log.levels.ERROR)
      for j = i + 1, #captured do
        if M.fs.taken(captured[j].quarantine) then
          M.ui.notify('direct: Unpaste entry preserved at ' .. captured[j].quarantine, vim.log.levels.ERROR)
        end
      end
      return nil, 'captured entry changed before deletion: ' .. tostring(compare_err or item.quarantine)
    end
    local deleted, delete_err
    local called
    if item.kind == 'directory' then
      called, deleted, delete_err = pcall(M.fs.rm_tree, item.quarantine)
    else
      called, deleted, delete_err = pcall(M.fs.rm_file, item.quarantine)
    end
    if not called then
      delete_err, deleted = tostring(deleted), nil
    end
    if not deleted or M.fs.taken(item.quarantine) then
      for j = i, #captured do
        if M.fs.taken(captured[j].quarantine) then
          M.ui.notify('direct: Unpaste entry preserved at ' .. captured[j].quarantine, vim.log.levels.ERROR)
        end
      end
      return nil, 'could not delete captured entry ' .. item.quarantine .. ': ' .. tostring(delete_err)
    end
    self._completed_renames[#self._completed_renames + 1] = {
      src = item.pair.src,
      dst = item.pair.dst,
    }
    if type(self._after_unpaste_delete) == 'function' then
      local recorded, record_err = self._after_unpaste_delete(i, item)
      if not recorded then return nil, 'could not record deleted Unpaste entry: ' .. tostring(record_err) end
    end
  end
  return true
end

-- Unpaste verifies every pasted target against the current register copy, then
-- captures all targets under same-directory quarantine names before deleting
-- any of them. This is the inverse of Paste; it never deletes by the original P
-- pathname after the capture phase.
function M.Unpaste(src, dst, src_names, dst_names)
  local self = {
    name = 'up',
    _kind = 'up',
    src = src,
    dst = dst,
    renames = zipped(src_names, dst_names),
    _completed_renames = {},
  }
  self._execute = function()
    self._completed_renames = {}
    local items, preflight_err = preflight_unpaste(self)
    if not items then return unpaste_refusal(preflight_err) end

    local started, start_err = begin_unpaste_recovery(self, items)
    if not started then return unpaste_refusal(start_err) end

    -- Phase B: atomically capture and re-verify every target before deletion.
    local captured, capture_err = capture_unpaste_items(self, items)
    if not captured then return unpaste_refusal(capture_err) end

    local ready, ready_err = prepare_unpaste_deletion(self, captured)
    if not ready then return unpaste_refusal(ready_err) end

    -- Phase C removes only captured Q paths; failures preserve remaining Qs.
    local deleted, delete_err = delete_unpaste_items(self, captured)
    if not deleted then return unpaste_refusal(delete_err) end
    return true
  end
  self['do'] = function() return M.execute(self) end
  function self.describe() return 'Reversed paste into ' .. M.rel(self.src) .. M.paths.separator end
  return self
end

-- Human summaries
-- ---------------------------------------------------------------------------

-- describe_action(action) -> a human-readable description, never serialized text.
function M.describe_action(action)
  if type(action) == 'table' and type(action.describe) == 'function' then return action.describe() end
  return tostring(action)
end

-- summarize(actions) joins descriptions with `, ` and uppercases only the first
-- character of the resulting string.
function M.summarize(actions)
  local parts = {}
  for _, action in ipairs(actions or {}) do
    parts[#parts + 1] = M.describe_action(action)
  end
  local summary = table.concat(parts, ', ')
  if #summary > 0 then summary = summary:sub(1, 1):upper() .. summary:sub(2) end
  return summary
end

local moves = require('direct.action.moves')
M.first_free_temp = moves.first_free_temp
M.stage_moves = moves.stage_moves
M.plan_move_steps = moves.plan_move_steps
M.move_groups = moves.move_groups
M.Group = function(actions) return moves.make_group(M, actions) end
local registry = require('direct.action.registry')
registry.attach(M)
M.serialize_group = registry.serialize_group
M.execute = registry.execute
M.execute_async = registry.execute_async
M.Batch = registry.Batch
M.serialize = registry.serialize
M.deserialize = registry.deserialize
M.reverse_action = registry.reverse_action
M.reverse = registry.reverse

return M
