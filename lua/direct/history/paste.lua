-- Durable async Paste history journal lifecycle.
-- History supplies only the coordinator functions that must remain owned by
-- history.lua; storage, action, path, transaction, and lock modules are direct.

local M = {}

local log_mod = require('direct.log')
local action_mod = require('direct.action.action')
local paths = require('direct.paths')
local lock = require('direct.history.lock')
local transaction_codec = require('direct.history.transaction')
local TRANSACTION_FORMAT = transaction_codec.FORMAT
local TRANSACTION_VERSION = transaction_codec.VERSION

do
  function M.write_paste_journal(operation)
    local called, ok, err = pcall(
      function()
        return log_mod.write_raw_atomic(operation.transaction_path, vim.json.encode(operation.transaction) .. '\n')
      end
    )
    if not called then return nil, tostring(ok) end
    if not ok then return nil, err end
    return true
  end

  local function release_paste_lock(operation)
    if not operation.locked then return true end
    operation.locked = false
    return lock.release()
  end

  local function begin_paste_after_acquire(action, record, acquired, acquire_err, coordinator)
    if not acquired then
      coordinator.notify_unavailable(acquire_err)
      return nil, acquire_err
    end
    local called, state, preflight_err = xpcall(
      function() return coordinator.preflight_locked(coordinator.action_paths(action)) end,
      debug.traceback
    )
    if not called or not state then
      lock.release()
      return nil, called and preflight_err or state
    end
    local transaction = {
      format = TRANSACTION_FORMAT,
      version = TRANSACTION_VERSION,
      kind = 'paste',
      direction = 'apply',
      action = record,
      source_action = vim.NIL,
      base_undo = coordinator.copy_lines(state.undo_lines),
      base_redo = coordinator.copy_lines(state.redo_lines),
      completed = {},
      pending = vim.NIL,
    }
    local operation = {
      transaction = transaction,
      transaction_path = state.transaction_path,
      undo_path = state.undo_path,
      redo_path = state.redo_path,
      locked = true,
    }
    local written, write_err = M.write_paste_journal(operation)
    if not written then
      release_paste_lock(operation)
      coordinator.notify_unavailable(write_err)
      return nil, write_err
    end
    return operation
  end

  -- begin_paste holds the same-host history lock until finish_paste. The initial
  -- journal is durable before the async executor can create its first destination.
  function M.begin_paste(action, coordinator)
    if type(action) ~= 'table' or action.name ~= 'p' then
      return nil, 'history.begin_paste: a Paste action is required'
    end
    local record, serialize_err = action_mod.serialize(action)
    if not record then return nil, serialize_err end
    local acquired, acquire_err = lock.acquire()
    return begin_paste_after_acquire(action, record, acquired, acquire_err, coordinator)
  end

  function M.begin_paste_async(action, callback, coordinator)
    if type(action) ~= 'table' or action.name ~= 'p' then
      return nil, 'history.begin_paste_async: a Paste action is required'
    end
    if type(callback) ~= 'function' then return nil, 'history.begin_paste_async: a completion callback is required' end
    local record, serialize_err = action_mod.serialize(action)
    if not record then return nil, serialize_err end
    return lock.acquire_async(function(acquired, acquire_err)
      local operation, begin_err = begin_paste_after_acquire(action, record, acquired, acquire_err, coordinator)
      callback(operation, begin_err)
    end)
  end

  function M.note_paste_pending(operation, pair, source, destination)
    if
      type(operation) ~= 'table'
      or not operation.locked
      or type(pair) ~= 'table'
      or type(source) ~= 'string'
      or type(destination) ~= 'string'
    then
      return nil, 'invalid pending paste update'
    end
    if action_mod.entry_name_reason(pair.src) or action_mod.entry_name_reason(pair.dst) then
      return nil, 'invalid paste entry name'
    end
    local source_identity, source_stat = action_mod.fs.entry_identity(source)
    if not source_stat or not source_identity or not source_identity.inode then
      return nil, 'cannot identify paste source: ' .. source
    end
    local previous = operation.transaction.pending
    if previous ~= vim.NIL then return nil, 'another paste entry is already pending' end
    operation.transaction.pending = {
      src = pair.src,
      dst = pair.dst,
      source = paths.canonical(source),
      destination = paths.canonical(destination),
      source_identity = source_identity,
    }
    local written, write_err = M.write_paste_journal(operation)
    if not written then
      operation.transaction.pending = previous
      return nil, write_err
    end
    return true
  end

  function M.note_paste_complete(operation, pair)
    if type(operation) ~= 'table' or not operation.locked or type(pair) ~= 'table' then
      return nil, 'invalid completed paste update'
    end
    local transaction = operation.transaction
    local pending = transaction.pending
    if type(pending) ~= 'table' or pending.src ~= pair.src or pending.dst ~= pair.dst then
      return nil, 'completed paste entry does not match its durable intent'
    end
    transaction.completed[#transaction.completed + 1] = { src = pair.src, dst = pair.dst }
    transaction.pending = vim.NIL
    local written, write_err = M.write_paste_journal(operation)
    if not written then
      table.remove(transaction.completed)
      transaction.pending = pending
      return nil, write_err
    end
    return true
  end

  function M.cancel_paste_pending(operation, pair)
    if type(operation) ~= 'table' or not operation.locked then return nil, 'paste history operation is not active' end
    local transaction = operation.transaction
    local pending = transaction.pending
    if type(pending) ~= 'table' or pending.src ~= pair.src or pending.dst ~= pair.dst then
      return nil, 'paste conflict does not match the pending destination'
    end
    transaction.pending = vim.NIL
    local written, write_err = M.write_paste_journal(operation)
    if not written then
      transaction.pending = pending
      return nil, write_err
    end
    return true
  end

  function M.finish_paste(operation, coordinator)
    if type(operation) ~= 'table' or not operation.locked then return nil, 'paste history operation is not active' end
    local called, result, result_err = xpcall(function()
      local completed, settle_err = coordinator.recovery.settle_paste_pending(operation.transaction)
      if not completed then return nil, settle_err end
      if #completed == 0 then return coordinator.clear_transaction(operation.transaction_path) end
      local undo, redo, stack_err = coordinator.recovery.paste_stack_snapshot(operation.transaction, completed)
      if not undo then return nil, stack_err end
      return coordinator.commit_stacks(operation.undo_path, operation.redo_path, operation.transaction_path, undo, redo)
    end, debug.traceback)
    if not called then
      result, result_err = nil, result
    end
    local released, release_err = release_paste_lock(operation)
    if result and not released then return nil, release_err end
    if not result then return nil, result_err end
    return true
  end

  return M
end
