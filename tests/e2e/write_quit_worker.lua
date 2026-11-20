-- Real-process regression coverage for Direct write/quit behavior.

local function assert_true(value, message)
  if not value then error(message or 'assertion failed', 2) end
end

local function write_marker(path, contents)
  assert_true(vim.fn.writefile({ contents or 'ready' }, path) == 0, 'could not write marker ' .. path)
end

local function wait_for_path(path, description)
  assert_true(
    vim.wait(10000, function() return vim.uv.fs_stat(path) ~= nil end, 10),
    'timed out waiting for ' .. description
  )
end

local function wait_for_idle()
  local pending = require('direct.pending')
  assert_true(vim.wait(15000, function() return not pending.is_pending() end, 10), 'Direct operation did not finish')
end

local function row_number(name)
  for index, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if line == name then return index end
  end
  error('listing row not found: ' .. name .. ' in ' .. vim.inspect(vim.api.nvim_buf_get_lines(0, 0, -1, false)), 2)
end

local function list_root(api, root)
  local listed, err = api.list(root)
  assert_true(listed ~= nil, 'could not list workspace: ' .. tostring(err))
end

local function edit_rename(api, root, source, destination)
  list_root(api, root)
  local row = row_number(source)
  vim.api.nvim_buf_set_lines(0, row - 1, row, false, { destination })
  return vim.api.nvim_get_current_buf()
end

local function install_slow_move_stub()
  local destination = vim.env.DIRECT_E2E_SLOW_DST
  if not destination or destination == '' then return end

  local source = assert(vim.env.DIRECT_E2E_SLOW_SRC)
  local fs = require('direct.fs')
  local rename_noreplace = fs.rename_noreplace
  local copyfile = fs.uv.fs_copyfile
  local delay = tonumber(vim.env.DIRECT_E2E_SLOW_MS) or 1500
  local started = false
  fs.rename_noreplace = function(src, dst, identity)
    if vim.fs.normalize(src) == vim.fs.normalize(source) and vim.fs.normalize(dst) == vim.fs.normalize(destination) then
      return nil, 'EXDEV: simulated second filesystem', 'EXDEV'
    end
    return rename_noreplace(src, dst, identity)
  end
  fs.uv.fs_copyfile = function(src, dst, flags, callback)
    if not started and vim.fs.normalize(src) == vim.fs.normalize(source) then
      started = true
      local pending = require('direct.pending')
      local registered = vim.env.DIRECT_E2E_MODE == 'bw_pending' and pending.is_pending() or pending.has_saves()
      assert_true(registered, 'slow filesystem action was not registered as pending')
      write_marker(assert(vim.env.DIRECT_E2E_STARTED))
      if vim.env.DIRECT_E2E_MODE == 'qa_ctrl_c' then
        vim.defer_fn(function() vim.api.nvim_input(string.char(3)) end, 150)
      end
      vim.defer_fn(function() copyfile(src, dst, flags, callback) end, delay)
      return true
    end
    return copyfile(src, dst, flags, callback)
  end
end

local function capture_notifications()
  local log_path = vim.env.DIRECT_E2E_NOTIFICATION_LOG
  if not log_path or log_path == '' then return end
  local notify = vim.notify
  vim.notify = function(message, level, options)
    vim.fn.writefile({ tostring(level or '') .. '\t' .. tostring(message) }, log_path, 'a')
    return notify(message, level, options)
  end
end

local function run_write(api)
  edit_rename(api, assert(vim.env.DIRECT_E2E_ROOT), 'before.txt', 'after.txt')
  vim.cmd('write')
  assert_true(not vim.bo.modified, ':write returned while the Direct listing was still modified')
  write_marker(assert(vim.env.DIRECT_E2E_RETURNED))
  vim.cmd('qa!')
end

local function run_write_quit(api, command)
  edit_rename(api, assert(vim.env.DIRECT_E2E_ROOT), 'before.txt', 'after.txt')
  vim.cmd(command)
end

local function run_ctrl_c(api)
  edit_rename(api, assert(vim.env.DIRECT_E2E_ROOT), 'before.txt', 'after.txt')
  local returned = assert(vim.env.DIRECT_E2E_RETURNED)
  -- Feed Ctrl-C while :write is inside its wait. The delayed filesystem task is
  -- independent and must still complete after the command stops waiting.
  vim.defer_fn(function() vim.api.nvim_input(string.char(3)) end, 150)
  local ok, err = pcall(vim.cmd, 'write')
  write_marker(returned, ok and 'write completed normally' or tostring(err))
  wait_for_path(assert(vim.env.DIRECT_E2E_EXPECTED_DST), 'the background save after Ctrl-C')
  wait_for_idle()
  vim.cmd('qa!')
end

local function run_write_all(api)
  local root_a = assert(vim.env.DIRECT_E2E_ROOT_A)
  local root_b = assert(vim.env.DIRECT_E2E_ROOT_B)
  edit_rename(api, root_a, 'one-before.txt', 'one-after.txt')
  vim.cmd('new')
  edit_rename(api, root_b, 'two-before.txt', 'two-after.txt')
  vim.cmd('wall')
  assert_true(not vim.bo.modified, ':wa left the current Direct listing modified')
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == 'direct' then
      assert_true(not vim.bo[bufnr].modified, ':wa left a Direct listing modified')
    end
  end
  vim.cmd('qa!')
end

local function run_qa_pending(api)
  edit_rename(api, assert(vim.env.DIRECT_E2E_ROOT), 'before.txt', 'after.txt')
  -- Stop :write waiting, then issue :qa while the save remains active. This
  -- exercises ExitPre without a platform-specific remote-control socket.
  vim.defer_fn(function() vim.api.nvim_input(string.char(3)) end, 150)
  pcall(vim.cmd, 'write')
  assert_true(require('direct.pending').has_saves(), 'the save stopped instead of continuing after Ctrl-C')
  vim.bo.modified = false
  vim.cmd('qa')
end

local function run_qa_ctrl_c(api)
  edit_rename(api, assert(vim.env.DIRECT_E2E_ROOT), 'before.txt', 'after.txt')
  pcall(vim.cmd, 'write')
  assert_true(require('direct.pending').has_saves(), 'the save stopped instead of continuing after Ctrl-C')
  vim.bo.modified = false
  vim.defer_fn(function() vim.api.nvim_input(string.char(3)) end, 150)
  vim.cmd('qa')
end

local function run_bw_pending(api)
  edit_rename(api, assert(vim.env.DIRECT_E2E_ROOT), 'before.txt', 'after.txt')
  local bufnr = vim.api.nvim_get_current_buf()
  local started, err = api.sync(function() end)
  assert_true(started ~= nil, 'could not start async save: ' .. tostring(err))
  wait_for_path(assert(vim.env.DIRECT_E2E_STARTED), 'the slow move to start')
  vim.cmd('bw!')
  assert_true(not vim.api.nvim_buf_is_valid(bufnr), ':bw! did not wipe the listing buffer')
  write_marker(assert(vim.env.DIRECT_E2E_WIPED))
  wait_for_idle()
  assert_true(vim.uv.fs_stat(assert(vim.env.DIRECT_E2E_EXPECTED_DST)) ~= nil, 'save did not continue after :bw!')
  write_marker(assert(vim.env.DIRECT_E2E_FINISHED))
  vim.cmd('qa!')
end

local function run_undo(api)
  list_root(api, assert(vim.env.DIRECT_E2E_ROOT))
  local started, err = api.undo()
  assert_true(started ~= nil, 'could not start undo: ' .. tostring(err))
  wait_for_idle()
  vim.cmd('qa!')
end

local function main()
  local repo = assert(vim.env.DIRECT_E2E_REPO)
  vim.opt.runtimepath:prepend(repo)
  package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
  vim.cmd('runtime plugin/direct.lua')
  capture_notifications()
  install_slow_move_stub()

  local api = require('direct')
  api.setup({ undo_confirm = false, git = { enabled = false } })
  local mode = assert(vim.env.DIRECT_E2E_MODE)
  if mode == 'write' then return run_write(api) end
  if mode == 'wq' then return run_write_quit(api, 'wq') end
  if mode == 'x' then return run_write_quit(api, 'x') end
  if mode == 'ctrl_c' then return run_ctrl_c(api) end
  if mode == 'write_all' then return run_write_all(api) end
  if mode == 'qa_pending' then return run_qa_pending(api) end
  if mode == 'qa_ctrl_c' then return run_qa_ctrl_c(api) end
  if mode == 'bw_pending' then return run_bw_pending(api) end
  if mode == 'undo' then return run_undo(api) end
  error('unknown A49 E2E mode: ' .. mode)
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
  io.stderr:write('A49_E2E_PHASE_FAILED\n' .. tostring(err) .. '\n')
  vim.cmd('cquit 1')
end
