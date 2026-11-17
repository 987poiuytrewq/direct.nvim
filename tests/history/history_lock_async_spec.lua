-- Nonblocking retries for a history lock held by another Neovim process.
local H = require('tests.support.harness')
local lock = require('direct.history.lock')
local history = require('direct.history.history')
local action = require('direct.action.action')
local register = require('direct.register')
local pending = require('direct.pending')

local function start_holder(sb, duration_ms)
  local marker = vim.fs.joinpath(sb.root, 'lock-held')
  local script = H.mkfile(sb.root, 'hold_lock.lua', {
    'local root = assert(vim.env.DIRECT_FRESH_ROOT)',
    "package.path = root .. '/lua/?.lua;' .. package.path",
    "local lock = require('direct.history.lock')",
    'local ok, err = lock.acquire()',
    'if not ok then error(tostring(err)) end',
    'vim.fn.writefile({"held"}, ' .. string.format('%q', marker) .. ')',
    'vim.wait(' .. tostring(duration_ms) .. ', function() return false end, 20)',
    'lock.release()',
  })
  local process = vim.system({ vim.v.progpath, '--headless', '-l', script }, {
    env = {
      XDG_DATA_HOME = sb.data_home,
      DIRECT_FRESH_ROOT = vim.fn.getcwd(),
    },
    text = true,
  })
  H.assert_true(
    vim.wait(3000, function() return vim.uv.fs_stat(marker) ~= nil end),
    'the other Neovim process acquired the history lock'
  )
  return process
end

H.describe('async history lock', function()
  H.it('claims pending before a scheduled history operation can re-enter a sync wait', function()
    local sb = H.sandbox()
    local process = start_holder(sb, 350)
    local live_lock = require('direct.history.lock')
    local live_history = require('direct.history.history')
    local live_pending = require('direct.pending')
    local messages = H.capture_messages()
    local scheduled_callback, attempted, pending_during_wait, second_result = false, false, false, nil
    local real_wait = vim.wait
    local restore = H.stub(vim, 'wait', function(timeout, predicate, interval)
      if not scheduled_callback then
        vim.schedule(function()
          scheduled_callback = true
          attempted = true
          pending_during_wait = live_pending.is_pending()
          second_result = live_history.undo_async()
        end)
        H.assert_true(
          real_wait(100, function() return scheduled_callback end, 1),
          'the scheduled key callback runs while vim.wait is pumping the loop'
        )
      end
      return real_wait(timeout, predicate, interval)
    end)

    local acquired, acquire_err = live_lock.acquire()
    restore()
    if acquired then live_lock.release() end
    H.assert_true(acquired == true, tostring(acquire_err))
    H.assert_true(scheduled_callback, 'the scheduled key operation ran during vim.wait')
    H.assert_true(attempted and pending_during_wait, 'the key operation observed pending before vim.wait re-entered')
    H.assert_nil(second_result, 'the re-entrant history operation is refused')
    messages:assert('cannot undo while history lock is pending')
    H.assert_false(live_pending.is_pending(), 'the synchronous wait clears its temporary guard')
    local result = process:wait(3000)
    H.assert_eq(result.code, 0, tostring(result.stderr))
  end)

  H.it('clears pending and sync-wait state when vim.wait is interrupted', function()
    local sb = H.sandbox()
    local process = start_holder(sb, 1000)
    local live_lock = require('direct.history.lock')
    local live_pending = require('direct.pending')
    local wait_called = false
    local restore = H.stub(vim, 'wait', function()
      wait_called = true
      error('injected wait interruption')
    end)
    local ok, wait_err = pcall(live_lock.acquire)
    restore()

    H.assert_false(ok, 'the injected wait exception propagates')
    H.assert_true(
      tostring(wait_err):find('injected wait interruption', 1, true) ~= nil,
      'the original wait error is preserved'
    )
    H.assert_true(wait_called, 'the contested acquire entered the interrupted wait')
    H.assert_false(live_pending.is_pending(), 'the temporary pending token is cleared')
    local result = process:wait(3000)
    H.assert_eq(result.code, 0, tostring(result.stderr))
    local acquired, acquire_err = live_lock.acquire()
    H.assert_true(acquired == true, tostring(acquire_err))
    H.assert_false(live_pending.is_pending(), 'sync-wait state was also reset')
    H.assert_true(live_lock.release(), 'the lock remains usable after interruption')
  end)

  H.it('keeps the event loop responsive and acquires when the holder releases', function()
    local sb = H.sandbox()
    local target = vim.fs.joinpath(sb.root, 'target.txt')
    local create = action.Touch(target)
    H.assert_true(history.apply(create, function() return create['do']() end), 'seed an undoable action')
    local process = start_holder(sb, 350)
    local messages = H.capture_messages()
    local callback_done, callback_result, callback_err = false, nil, nil
    local timer_fired = false
    H.assert_true(history.pending == pending, 'history and the test share one pending guard')
    local started_at = vim.uv.hrtime()
    local started, start_err = history.undo_async(function(result, err)
      callback_done = true
      callback_result, callback_err = result, err
    end)
    H.assert_true(started == true, tostring(start_err))
    H.assert_true((vim.uv.hrtime() - started_at) / 1000000 < 100, 'a contended async acquire returns without waiting')
    H.assert_false(callback_done, 'completion waits for the other process')

    vim.defer_fn(function() timer_fired = true end, 20)
    H.assert_true(pending.is_pending(), 'the async operation claims the pending guard before waiting')
    H.assert_nil(history.undo_async(), 'a second key-driven operation is refused')
    -- A release with no acquired lock must not mutate the in-flight request.
    H.assert_true(lock.release(), 'release is harmless while acquisition is pending')
    H.assert_true(
      vim.wait(2000, function() return callback_done end, 5),
      'async undo completes after the other process releases'
    )
    H.assert_true(timer_fired, 'an editor timer fires during the lock retry')
    H.assert_not_nil(callback_result, tostring(callback_err))
    H.assert_false(pending.is_pending(), 'the async operation releases its pending guard')
    H.assert_nil(vim.uv.fs_stat(target), 'the original async operation succeeds')
    messages:assert('cannot undo while undo is pending')

    local result = process:wait(3000)
    H.assert_eq(result.code, 0, tostring(result.stderr))
  end)

  H.it('retries an async paste lock without blocking the command', function()
    local sb = H.sandbox()
    local source = H.mkfile(sb.root, 'source.txt', { 'paste me' })
    H.assert_true(register.yank({ source }), 'seed the register')
    local destination = H.mkdir(sb.root, 'destination')
    local process = start_holder(sb, 350)
    local timer_fired = false
    vim.defer_fn(function() timer_fired = true end, 20)
    local started_at = vim.uv.hrtime()
    local started, start_err = register.paste(destination)
    H.assert_true(started == true, tostring(start_err))
    H.assert_true((vim.uv.hrtime() - started_at) / 1000000 < 100, 'paste returns without waiting for the other process')
    H.assert_true(pending.is_pending(), 'paste remains guarded while waiting')
    H.assert_true(
      vim.wait(2000, function() return not pending.is_pending() end, 5),
      'paste completes after the lock holder releases'
    )
    H.assert_true(timer_fired, 'an editor timer fires during the async paste wait')
    H.assert_eq(vim.fn.readfile(destination .. '/source.txt'), { 'paste me' }, 'paste succeeds inside the retry window')
    local result = process:wait(3000)
    H.assert_eq(result.code, 0, tostring(result.stderr))
  end)

  H.it('times out with the existing busy message and leaves no held state', function()
    local sb = H.sandbox()
    local process = start_holder(sb, 2400)
    local callback_done, callback_result, callback_err = false, nil, nil
    local started, start_err = lock.acquire_async(function(ok, err)
      callback_done = true
      callback_result, callback_err = ok, err
    end)
    H.assert_true(started == true, tostring(start_err))
    H.assert_true(
      vim.wait(2600, function() return callback_done end, 5),
      'async acquire completes at the retry deadline'
    )
    H.assert_nil(callback_result, 'the busy lock is not acquired')
    H.assert_true(
      callback_err:find('another Neovim instance is using direct.vim history', 1, true) ~= nil,
      'the existing busy-lock message is preserved'
    )
    H.assert_true(callback_err:find('PID', 1, true) ~= nil, 'the holder PID remains in the message')
    H.assert_true(lock.release(), 'a timed-out waiter has no lock state to release')

    local result = process:wait(3000)
    H.assert_eq(result.code, 0, tostring(result.stderr))
    local acquired, acquire_err = lock.acquire()
    H.assert_true(acquired == true, tostring(acquire_err))
    H.assert_true(lock.release(), 'the lock is usable after a timeout')
  end)
end)
