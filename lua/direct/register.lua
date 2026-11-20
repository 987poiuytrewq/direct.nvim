-- lua/direct/register.lua -- persistent yank/paste register.
-- Names and destinations are checked before copying; skipped entries are reported.

local M = {}

M.fs = require('direct.fs')
M.paths = require('direct.paths')
M.action = require('direct.action.action')
M.history = require('direct.history.history')
M.log = require('direct.log')
M.ui = require('direct.ui')
M.pending = require('direct.pending')
local file_operations = require('direct.file_operations')
local events = require('direct.events')
local store = require('direct.register.store')

function M.content() return store.content() end

local function content_identity() return store.content_identity() end

function M.entries(dir) return store.entries(dir) end

function M.entry_path(dir, name) return store.entry_path(dir, name) end

local resolve_entry = store.resolve_entry

function M.resolve(dir, name) return store.resolve(dir, name) end

function M.entry_names(dir) return store.entry_names(dir) end

function M.prune_unreferenced(undo_lines, redo_lines, force)
  return store.prune_unreferenced(undo_lines, redo_lines, force)
end

function M.size_bytes() return store.size_bytes() end

local function cleanup_unreferenced(undo_lines, redo_lines)
  local called, cleaned, clean_err = pcall(M.prune_unreferenced, undo_lines, redo_lines, true)
  if not called then
    clean_err, cleaned = cleaned, nil
  end
  if not cleaned then
    M.ui.notify('direct: could not clean old register copies: ' .. tostring(clean_err), vim.log.levels.WARN)
  end
end

-- yank(sources) -> true | nil, err. `sources` is a list of absolute paths.
function M.yank(sources, options)
  options = options or {}
  if not options.bypass_pending and M.pending.refuse('yank') then return nil, 'another direct operation is pending' end
  if type(sources) ~= 'table' then return nil, 'register.yank: a list of sources is required' end
  -- Validate all user paths, source existence, and basename components before
  -- classifying logs: a refused yank must not reset recognized legacy history.
  for _, src in ipairs(sources) do
    local valid, path_err = M.paths.validate_canonical_path(src)
    if not valid then
      local message = 'cannot yank: ' .. tostring(path_err)
      M.ui.notify('direct: ' .. message, vim.log.levels.ERROR)
      return nil, message
    end
    local st = M.fs.stat(src)
    if not st then
      local message = 'cannot yank: ' .. tostring(src)
      M.ui.notify('direct: ' .. message, vim.log.levels.ERROR)
      return nil, message
    end
    local name = M.fs.basename(M.fs.abspath(src))
    local reason = M.action.entry_name_reason(name)
    if reason ~= nil then
      local msg = 'cannot yank: entry name ' .. reason .. ': ' .. tostring(name)
      M.ui.notify('direct: ' .. msg, vim.log.levels.ERROR)
      return nil, msg
    end
  end
  return M.history.with_lock(function()
    local preflight, preflight_err = M.history.preflight(sources)
    if not preflight then return nil, preflight_err end
    local dir, err = M.paths.ensure_data_dir('register')
    if not dir then
      M.ui.notify('direct: register unavailable: ' .. tostring(err), vim.log.levels.ERROR)
      return nil, err
    end
    local sorted = vim.deepcopy(sources)
    table.sort(sorted)
    local dst = M.paths.join(dir, M.paths.digest(sorted))
    if not M.fs.exists(dst) then
      local ok, merr = M.fs.mkdirp(dst)
      if not ok then return nil, merr end
    end
    -- A digest collision with an older delete-backed register would make paste
    -- read the stale manifest instead of the newly copied entries.
    if M.fs.exists(store.manifest_path(dst)) then
      local ok, merr = M.fs.rm_file(store.manifest_path(dst))
      if not ok then return nil, merr end
    end
    for _, src in ipairs(sources) do
      -- _yank_one returns true[, skipped] on success and nil, err on failure.
      local ok, skipped = M._yank_one(dst, src)
      if not ok then return nil, skipped end
      -- Report each raw source path in input order.
      M.ui.notify('Yanked ' .. src, vim.log.levels.INFO)
      -- Yank destroys nothing, so skip unsupported entries rather than fail the
      -- whole operation, but report every omission.
      local n = skipped ~= nil and #skipped or 0
      if n > 0 then
        M.ui.notify(
          'Skipped ' .. n .. ' ' .. (n == 1 and 'entry' or 'entries') .. ' that cannot be copied: ' .. src,
          vim.log.levels.WARN
        )
      end
    end
    local ok, werr = M.log.write(M.paths.join(dir, 'content'), { dst })
    if not ok then return nil, werr end
    cleanup_unreferenced(preflight.undo_lines, preflight.redo_lines)
    return true
  end)
end

-- _yank_one_async(dst, src, callback) -> true. Asynchronous counterpart of
-- _yank_one: files copy with fs.copy_file_async, directories with
-- fs.copy_tree_async after removing a stale entry of the same name.
function M._yank_one_async(dst, src, callback)
  local st = M.fs.stat(src)
  if not st then return callback(false, 'cannot yank: ' .. tostring(src)) end
  local name = M.fs.basename(M.fs.abspath(src))
  if name == nil or name == '' then return callback(false, 'cannot yank: no basename for ' .. tostring(src)) end
  local reason = M.action.entry_name_reason(name)
  if reason ~= nil then return callback(false, 'cannot yank: entry name ' .. reason .. ': ' .. tostring(name)) end
  local entry = M.paths.join(dst, name)
  if st.type == 'file' then
    return M.fs.copy_file_async(src, entry, function(ok, err) callback(ok, err) end)
  elseif st.type == 'directory' then
    if M.fs.exists(entry) then
      local ok, err = M.fs.rm_tree(entry)
      if not ok then return callback(false, err) end
    end
    return M.fs.copy_tree_async(src, entry, function(ok, skipped, err)
      if ok then
        callback(true, skipped)
      else
        callback(false, err)
      end
    end)
  end
  return callback(false, 'cannot yank: unsupported entry type for ' .. tostring(src))
end

-- yank_async(sources[, callback]) -> true | nil, err. Explicit yanks keep a
-- copy because their source stays in place and may change. The history lock is
-- held only for preflight and the final register-pointer switch; the private
-- snapshot copy runs in the background under the pending guard.
function M.yank_async(sources, callback)
  if M.pending.refuse('yank') then return nil, 'another direct operation is pending' end
  if type(sources) ~= 'table' then return nil, 'register.yank_async: a list of sources is required' end
  for _, src in ipairs(sources) do
    local valid, path_err = M.paths.validate_canonical_path(src)
    if not valid then
      local message = 'cannot yank: ' .. tostring(path_err)
      M.ui.notify('direct: ' .. message, vim.log.levels.ERROR)
      return nil, message
    end
    local st = M.fs.stat(src)
    if not st then
      local message = 'cannot yank: ' .. tostring(src)
      M.ui.notify('direct: ' .. message, vim.log.levels.ERROR)
      return nil, message
    end
    local name = M.fs.basename(M.fs.abspath(src))
    local reason = M.action.entry_name_reason(name)
    if reason ~= nil then
      local message = 'cannot yank: entry name ' .. reason .. ': ' .. tostring(name)
      M.ui.notify('direct: ' .. message, vim.log.levels.ERROR)
      return nil, message
    end
  end

  local began, begin_err = M.pending.begin('yank')
  if not began then
    M.ui.notify('direct: cannot yank: ' .. tostring(begin_err), vim.log.levels.WARN)
    return nil, begin_err
  end
  local lock_held, finished, dst = false, false, nil
  local previous_content, previous_identity
  local copied_sources, skipped_sources = {}, {}

  local function acquire_lock(on_acquired)
    if lock_held then
      on_acquired(true)
      return true
    end
    return M.history.lock.acquire_async(function(acquired, err)
      if acquired then lock_held = true end
      on_acquired(acquired, err)
    end)
  end

  local function release_lock()
    if not lock_held then return true end
    lock_held = false
    local released, err = M.history.lock.release()
    if not released then
      M.ui.notify('direct: could not release the history lock: ' .. tostring(err), vim.log.levels.ERROR)
    end
    return released, err
  end

  local function settle(ok, err)
    if finished then return end
    finished = true
    release_lock()
    if not ok then
      local removed, remove_err = store.discard_async_snapshot(dst)
      if not removed then
        M.ui.notify(
          'direct: incomplete register copy preserved at ' .. tostring(dst) .. ': ' .. tostring(remove_err),
          vim.log.levels.WARN
        )
      end
    end
    M.pending.finish()
    if not ok and err ~= nil then M.ui.notify('direct: cannot yank: ' .. tostring(err), vim.log.levels.ERROR) end
    if type(callback) == 'function' then
      local called, callback_err = pcall(callback, ok, err)
      if not called then M.ui.report_error('refresh after yanking', callback_err) end
    end
  end

  local function fail_start(err)
    settle(false, err)
    return nil, err
  end

  local started, start_err = acquire_lock(function(acquired, acquire_err)
    if not acquired then return fail_start(acquire_err) end
    local initial_state, initial_preflight_err = M.history.preflight(sources)
    if not initial_state then return fail_start(initial_preflight_err) end
    previous_content = M.content()
    previous_identity = content_identity()

    local dir, dir_err = M.paths.ensure_data_dir('register')
    if not dir then return fail_start(dir_err) end
    local sorted = vim.deepcopy(sources)
    table.sort(sorted)
    dst, dir_err = store.allocate_async_snapshot_dir(dir)
    if not dst then return fail_start(dir_err) end
    local released, release_err = release_lock()
    if not released then return fail_start(release_err) end

    local function switch_register(callback_after_switch)
      local switch_started, switch_start_err = acquire_lock(function(locked, lock_err)
        if not locked then return callback_after_switch(nil, lock_err) end
        local state, preflight_err = M.history.preflight(sources)
        if not state then return callback_after_switch(nil, preflight_err) end
        local current_content = M.content()
        local current_identity = content_identity()
        if current_content ~= previous_content or not vim.deep_equal(current_identity, previous_identity) then
          return callback_after_switch(nil, 'register changed while yank was copying; the newer register was kept')
        end
        local snapshot, rename_err = store.commit_async_snapshot(dst, dir, sorted)
        if not snapshot then return callback_after_switch(nil, rename_err) end
        dst = snapshot
        local written, write_err = M.log.write(M.paths.join(dir, 'content'), { dst })
        if not written then return callback_after_switch(nil, write_err) end
        cleanup_unreferenced(state.undo_lines, state.redo_lines)
        for _, src in ipairs(copied_sources) do
          M.ui.notify('Yanked ' .. src, vim.log.levels.INFO)
          local skipped = skipped_sources[src]
          local n = skipped ~= nil and #skipped or 0
          if n > 0 then
            M.ui.notify(
              'Skipped ' .. n .. ' ' .. (n == 1 and 'entry' or 'entries') .. ' that cannot be copied: ' .. src,
              vim.log.levels.WARN
            )
          end
        end
        callback_after_switch(true)
      end)
      if not switch_started then callback_after_switch(nil, switch_start_err) end
    end

    local index = 1
    local function next_source()
      if index > #sources then
        return switch_register(function(switched, switch_err)
          if not switched then return settle(false, switch_err) end
          settle(true)
        end)
      end
      local src = sources[index]
      index = index + 1
      M._yank_one_async(dst, src, function(ok, skipped_or_err)
        if not ok then return settle(false, skipped_or_err) end
        copied_sources[#copied_sources + 1] = src
        if skipped_or_err ~= nil then skipped_sources[src] = skipped_or_err end
        next_source()
      end)
    end
    next_source()
  end)
  if not started then return fail_start(start_err) end
  return true
end

-- yank_deleted(entries[, options]) -> true | nil, err. `entries` is a list of
-- { src = original path, dst = resolved trash payload }. Nothing is copied: the
-- register content directory only holds a manifest that points paste and the
-- undo proof at the trash payloads already created by the delete actions.
function M.yank_deleted(entries, options)
  options = options or {}
  if not options.bypass_pending and M.pending.refuse('yank') then return nil, 'another direct operation is pending' end
  if type(entries) ~= 'table' or #entries == 0 then
    return nil, 'register.yank_deleted: a non-empty list of entries is required'
  end
  local sources = {}
  for _, entry in ipairs(entries) do
    if type(entry) ~= 'table' or type(entry.src) ~= 'string' or type(entry.dst) ~= 'string' then
      return nil, 'register.yank_deleted: each entry needs a source and trash path'
    end
    local valid, path_err = M.paths.validate_canonical_path(entry.src)
    if not valid then
      local message = 'cannot yank: ' .. tostring(path_err)
      M.ui.notify('direct: ' .. message, vim.log.levels.ERROR)
      return nil, message
    end
    if not M.paths.validate_canonical_path(entry.dst) then
      local message = 'cannot yank: invalid trash path'
      M.ui.notify('direct: ' .. message, vim.log.levels.ERROR)
      return nil, message
    end
    local name = M.fs.basename(M.fs.abspath(entry.src))
    local reason = M.action.entry_name_reason(name)
    if reason ~= nil then
      local message = 'cannot yank: entry name ' .. reason .. ': ' .. tostring(name)
      M.ui.notify('direct: ' .. message, vim.log.levels.ERROR)
      return nil, message
    end
    sources[#sources + 1] = entry.src
  end
  return M.history.with_lock(function()
    local preflight, preflight_err = M.history.preflight(sources)
    if not preflight then return nil, preflight_err end
    local dir, err = M.paths.ensure_data_dir('register')
    if not dir then
      M.ui.notify('direct: register unavailable: ' .. tostring(err), vim.log.levels.ERROR)
      return nil, err
    end
    local trash_paths = {}
    for _, entry in ipairs(entries) do
      trash_paths[#trash_paths + 1] = entry.dst
    end
    table.sort(trash_paths)
    local dst = M.paths.join(dir, M.paths.digest(trash_paths))
    -- Recreate the snapshot directory so a previous copy with the same digest
    -- cannot survive as a stale visible entry alongside the manifest.
    if M.fs.exists(dst) then
      local removed, remove_err = M.fs.rm_tree(dst)
      if not removed then return nil, remove_err end
    end
    local made, make_err = M.fs.mkdirp(dst)
    if not made then return nil, make_err end
    local manifest_entries = {}
    for _, entry in ipairs(entries) do
      manifest_entries[#manifest_entries + 1] = {
        name = M.fs.basename(M.fs.abspath(entry.src)),
        path = entry.dst,
        original = entry.src,
      }
    end
    local written, write_err = store.write_manifest(dst, manifest_entries)
    if not written then return nil, write_err end
    local ok, werr = M.log.write(M.paths.join(dir, 'content'), { dst })
    if not ok then return nil, werr end
    cleanup_unreferenced(preflight.undo_lines, preflight.redo_lines)
    for _, entry in ipairs(entries) do
      M.ui.notify('Yanked ' .. entry.src, vim.log.levels.INFO)
    end
    return true
  end)
end

-- _yank_one(dst, src) -> true[, skipped] | nil, err. Copies one source into the
-- register entry directory, replacing an existing entry of the same name: files
-- via copy_file (which overwrites), directories by removing the stale entry and
-- re-copying the tree so no stale members survive a re-yank. A directory copy is
-- best-effort (copy_tree without require_complete): the sources stay in place
-- so an entry that cannot be reproduced is reported to the caller (`skipped`)
-- instead of failing the yank.
function M._yank_one(dst, src)
  local st = M.fs.stat(src)
  if not st then return nil, 'cannot yank: ' .. tostring(src) end
  local name = M.fs.basename(M.fs.abspath(src))
  if name == nil or name == '' then return nil, 'cannot yank: no basename for ' .. tostring(src) end
  -- A space splits p/up name lists after reload; a tab splits history fields.
  -- Either could make undo target unrelated paths, so reject the name before it
  -- enters the register (yank also validates before creating the digest dir).
  local reason = M.action.entry_name_reason(name)
  if reason ~= nil then
    local msg = 'cannot yank: entry name ' .. reason .. ': ' .. tostring(name)
    M.ui.notify('direct: ' .. msg, vim.log.levels.ERROR)
    return nil, msg
  end
  local entry = M.paths.join(dst, name)
  if st.type == 'file' then
    return M.fs.copy_file(src, entry)
  elseif st.type == 'directory' then
    if M.fs.exists(entry) then
      local ok, err = M.fs.rm_tree(entry)
      if not ok then return nil, err end
    end
    return M.fs.copy_tree(src, entry)
  end
  return nil, 'cannot yank: unsupported entry type for ' .. tostring(src)
end

-- build_paste_plan(dst, name) -> validated paste inputs | nil[, err].
-- Register data is persisted and untrusted, so validate names and serialize the
-- exact action before starting the copy or writing history.
local function build_paste_plan(dst, name)
  local src, content_err = M.content()
  if src == nil then
    if content_err ~= nil then
      M.ui.notify('direct: register unavailable: ' .. tostring(content_err), vim.log.levels.ERROR)
      return nil, content_err
    end
    M.ui.notify('Register is empty', vim.log.levels.WARN)
    return nil
  end

  local entries, entries_err = M.entries(src)
  if not entries then
    M.ui.notify('direct: cannot read register: ' .. tostring(entries_err or src), vim.log.levels.ERROR)
    return nil, 'cannot read register'
  end

  local names, pasteable = {}, {}
  for _, entry in ipairs(entries) do
    local reason = M.action.entry_name_reason(entry.name)
    if reason ~= nil then
      M.ui.notify('direct: skipping register entry (' .. reason .. '): ' .. tostring(entry.name), vim.log.levels.ERROR)
    else
      names[#names + 1] = entry.name
      if resolve_entry(entry) then
        pasteable[#pasteable + 1] = entry.name
      else
        M.ui.notify(
          'direct: skipping register entry that is no longer available: ' .. tostring(entry.name),
          vim.log.levels.WARN
        )
      end
    end
  end
  if #pasteable == 0 then
    -- Do not build a no-op action when filtering leaves nothing: it would claim
    -- a paste succeeded and create a history entry that names no files.
    M.ui.notify('Nothing to paste', vim.log.levels.WARN)
    return nil
  end

  -- `:DirectPasteAs {name}` renames the first pasted entry (the smallest source
  -- name, which is the first pair Paste's sorted `renames` walks).
  local dst_names = vim.deepcopy(pasteable)
  if name ~= nil and name ~= '' then dst_names[1] = name end
  local paste_action = M.action.Paste(src, dst, pasteable, dst_names)
  local _, unsafe = M.action.serialize(paste_action)
  if unsafe ~= nil then
    local message = 'cannot paste: unrepresentable path: ' .. tostring(unsafe)
    M.ui.notify('direct: ' .. message, vim.log.levels.ERROR)
    return nil, message
  end

  return {
    src = src,
    dst = dst,
    entries = entries,
    names = names,
    pasteable = pasteable,
    action = paste_action,
  }
end

-- new_paste_segments(plan) -> per-paste lock and history segment operations.
-- A prompt releases the history lock; the segment is finished before prompting
-- and reacquired only after the user's answer is checked against the register.
local function new_paste_segments(plan)
  local operation, base_undo, records = nil, nil, {}

  local function accept(fresh)
    operation = fresh
    if base_undo == nil then base_undo = vim.deepcopy(fresh.transaction.base_undo) end

    local current_register = M.content()
    local current_names = current_register == plan.src and M.entry_names(plan.src) or nil
    local current_entries = current_register == plan.src and M.entries(plan.src) or nil
    local stable = current_register == plan.src
      and vim.deep_equal(current_names, plan.names)
      and vim.deep_equal(current_entries, plan.entries)
    if stable then
      for _, entry_name in ipairs(plan.pasteable) do
        if not M.resolve(plan.src, entry_name) then
          stable = false
          break
        end
      end
    end
    if not stable then
      M.history.finish_paste(operation)
      operation = nil
      return nil, 'register changed while preparing paste; retry the operation'
    end
    return true
  end

  local function begin()
    if operation and operation.locked then return true end
    local fresh, err = M.history.begin_paste(plan.action)
    if not fresh then return nil, err end
    return accept(fresh)
  end

  local function begin_async(on_ready)
    if operation and operation.locked then
      on_ready(true)
      return true
    end
    return M.history.begin_paste_async(plan.action, function(fresh, err)
      if not fresh then return on_ready(nil, err) end
      local ready, ready_err = accept(fresh)
      on_ready(ready, ready_err)
    end)
  end

  local function finish()
    if not operation or not operation.locked then return true end
    local completed_pairs = operation.transaction.completed or {}
    local segment_record
    if #completed_pairs > 0 then
      local sources, destinations = {}, {}
      for _, pair in ipairs(completed_pairs) do
        sources[#sources + 1] = pair.src
        destinations[#destinations + 1] = pair.dst
      end
      local serialize_err
      segment_record, serialize_err = M.action.serialize(M.action.Paste(plan.src, plan.dst, sources, destinations))
      if not segment_record then return nil, serialize_err end
    end
    local finished, err = M.history.finish_paste(operation)
    operation = nil
    if not finished then return nil, err end
    if segment_record then records[#records + 1] = segment_record end
    return true
  end

  local function coalesce()
    if #records < 2 then return true end
    local sources, destinations = {}, {}
    for _, pair in ipairs(plan.action.renames or {}) do
      sources[#sources + 1] = pair.src
      destinations[#destinations + 1] = pair.dst
    end
    local merged = M.action.Paste(plan.src, plan.dst, sources, destinations)
    local ok, err = M.history.coalesce_paste_segments(base_undo, records, merged)
    if not ok then
      M.ui.notify('direct: pasted entries remain in separate undo steps: ' .. tostring(err), vim.log.levels.WARN)
      return nil, err
    end
    return true
  end

  local function note_pending(pair, source, destination)
    return M.history.note_paste_pending(operation, pair, source, destination)
  end

  local function note_complete(pair)
    if not operation or not operation.locked then return nil, 'paste history operation is not active' end
    return M.history.note_paste_complete(operation, pair)
  end

  local function cancel_pending(pair)
    if not operation or not operation.locked then return nil, 'paste history operation is not active' end
    return M.history.cancel_paste_pending(operation, pair)
  end

  return {
    begin = begin,
    begin_async = begin_async,
    finish = finish,
    coalesce = coalesce,
    note_pending = note_pending,
    note_complete = note_complete,
    cancel_pending = cancel_pending,
    locked = function() return operation ~= nil and operation.locked end,
    count = function() return #records end,
  }
end

-- attach_paste_history_hooks(action, plan, segments) -> action.
-- The Paste executor calls these hooks around prompts and filesystem copies.
local function attach_paste_history_hooks(paste_action, plan, segments)
  paste_action._before_prompt = function() return segments.finish() end
  paste_action._after_prompt = function(pair, _source, answer, resumed)
    pair.dst = answer
    local started, start_err = segments.begin_async(function(ready, ready_err)
      if not ready then return resumed(nil, ready_err) end
      if M.fs.taken(M.paths.join(plan.dst, answer)) then
        local finished, finish_err = segments.finish()
        if not finished then return resumed(nil, finish_err) end
        return resumed('clash')
      end
      resumed(true)
    end)
    if not started then return nil, start_err end
    return 'pending'
  end
  paste_action._before_copy = function(pair, source, destination)
    local ready, ready_err = segments.begin()
    if not ready then return nil, ready_err end
    return segments.note_pending(pair, source, destination)
  end
  paste_action._after_copy = function(pair) return segments.note_complete(pair) end
  paste_action._on_copy_conflict = function(pair) return segments.cancel_pending(pair) end
  return paste_action
end

-- finish_paste(plan, segments, state, ...) -> settles callbacks, history and events.
local function finish_paste(plan, callback, segments, state, ok, result, execution_err)
  if state.completed then return end
  state.completed = true
  local changed, pasted_entry = false, nil
  local paste_action = plan.action
  local final_ok, final_err = xpcall(function()
    local copied = #(paste_action.renames or {})
    changed = copied > 0
    if copied > 0 then
      file_operations.emit_actions({ paste_action })
      pasted_entry = type(result) == 'string' and result or nil
      if pasted_entry == nil then
        local last = paste_action.renames[copied]
        if last then pasted_entry = M.paths.join(plan.dst, last.dst) end
      end
      if segments.locked() then
        local committed, commit_err = segments.finish()
        if not committed then M.ui.report_error('save paste history', commit_err) end
      end
      if ok then
        M.ui.notify(M.action.summarize({ paste_action }), vim.log.levels.INFO)
      else
        M.ui.report_error('finish pasting; completed entries were kept', execution_err)
      end
    elseif not ok then
      M.ui.report_error('paste the entries', execution_err)
    elseif segments.locked() then
      local committed, commit_err = segments.finish()
      if not committed then M.ui.report_error('finish the paste operation', commit_err) end
    end
    if segments.count() > 1 then segments.coalesce() end
  end, debug.traceback)
  if segments.locked() then segments.finish() end
  M.pending.finish()
  if not final_ok then
    M.ui.report_error('finish the paste operation', final_err)
    ok, result, execution_err = false, nil, final_err
  end
  state.result, state.err = result, execution_err
  if type(callback) == 'function' then
    local called, callback_err = pcall(callback, result, execution_err, ok, changed, pasted_entry)
    if not called then M.ui.report_error('refresh after pasting', callback_err) end
    execution_err = execution_err or (not called and callback_err or nil)
  end
  events.emit('DirectPastePost', {
    root = plan.dst,
    actions = changed and { paste_action } or {},
    success = ok and final_ok,
    changed = changed,
    error = execution_err or final_err,
    entry = pasted_entry,
  })
end

-- start_paste(plan, callback) -> scheduled/result | nil, err.
local function start_paste(plan, callback)
  local began, begin_err = M.pending.begin('paste')
  if not began then
    M.ui.notify('direct: cannot paste: ' .. tostring(begin_err), vim.log.levels.WARN)
    return nil, begin_err
  end

  local segments = new_paste_segments(plan)
  local paste_action = attach_paste_history_hooks(plan.action, plan, segments)
  local state = { completed = false }
  local function finish(ok, result, err) finish_paste(plan, callback, segments, state, ok, result, err) end

  local started, start_err = segments.begin_async(function(ready, ready_err)
    if not ready then
      M.ui.notify('direct: cannot paste: ' .. tostring(ready_err), vim.log.levels.ERROR)
      return finish(false, nil, ready_err)
    end
    local called, start_result, execute_err = pcall(M.action.execute_async, paste_action, finish)
    if not called then
      finish(false, nil, start_result)
    elseif start_result == nil then
      finish(false, nil, execute_err or 'could not start paste')
    end
  end)
  if not started then
    M.pending.finish()
    M.ui.notify('direct: cannot paste: ' .. tostring(start_err), vim.log.levels.ERROR)
    return nil, start_err
  end
  if state.completed then return state.result, state.err end
  return true
end

-- start_paste_after_preflight(dst, name, callback) -> scheduled/result | nil, err.
local function start_paste_after_preflight(dst, name, callback)
  local began, token = M.pending.begin('paste')
  if not began then
    M.ui.notify('direct: cannot paste: ' .. tostring(token), vim.log.levels.WARN)
    return nil, token
  end
  local outer_returned, completed = false, false
  local immediate_result, immediate_err
  local started, start_err = M.history.preflight_async({ dst }, function(preflight, preflight_err)
    M.pending.finish(token)
    if not preflight then
      immediate_result, immediate_err = nil, preflight_err
    else
      immediate_result, immediate_err = M.paste(dst, name, callback, { preflighted = true })
    end
    completed = true
    if outer_returned and immediate_result ~= true and type(callback) == 'function' then
      local called, callback_err = pcall(callback, immediate_result, immediate_err, false, false)
      if not called then M.ui.report_error('refresh after pasting', callback_err) end
    end
  end)
  if not started then
    M.pending.finish(token)
    return nil, start_err
  end
  outer_returned = true
  if completed then return immediate_result, immediate_err end
  return true
end

-- paste(dst[, name[, callback]]) -> scheduled/result | nil, err.
-- This service owns filesystem and history effects. The facade owns view refresh.
--
-- `name` is the `:DirectPasteAs {name}` extension: when given, the first pasted
-- entry (the smallest source name, matching Paste's sorted `renames`) is pasted
-- as `name`. `callback(result, err, succeeded, changed, pasted_entry)` runs once
-- the operation settles.
function M.paste(dst, name, callback, internal_options)
  internal_options = internal_options or {}
  if M.pending.refuse('paste') then return nil, 'another direct operation is pending' end
  local valid, path_err = M.paths.validate_path(dst)
  if not valid then
    M.ui.notify('direct: cannot paste: ' .. tostring(path_err), vim.log.levels.ERROR)
    return nil, path_err
  end
  if name ~= nil and name ~= '' then
    local name_err = M.action.entry_name_reason(name)
    if name_err then
      local message = 'cannot paste: entry name ' .. name_err .. ': ' .. tostring(name)
      M.ui.notify('direct: ' .. message, vim.log.levels.ERROR)
      return nil, message
    end
  end
  dst = M.paths.root(dst)
  if not internal_options.preflighted then return start_paste_after_preflight(dst, name, callback) end
  local plan, plan_err = build_paste_plan(dst, name)
  if not plan then return nil, plan_err end
  return start_paste(plan, callback)
end

return M
