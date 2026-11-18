local function assert_true(value, message)
  if not value then error(message or 'assertion failed', 2) end
end

local function list_lines() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end

local function row_number(name)
  for index, line in ipairs(list_lines()) do
    if line == name then return index end
  end
  error('listing row not found: ' .. name .. ' in ' .. vim.inspect(list_lines()), 2)
end

local function wait_for_idle()
  local pending = require('direct.pending')
  assert_true(vim.wait(10000, function() return not pending.is_pending() end, 10), 'Direct operation did not finish')
end

local function save()
  vim.cmd('write')
  wait_for_idle()
  assert_true(not vim.bo[0].modified, 'successful write left the listing modified')
end

local function list_root(api)
  local listed, err = api.list(assert(vim.env.DIRECT_E2E_ROOT))
  assert_true(listed ~= nil, 'could not list workspace: ' .. tostring(err))
end

local function wait_for_path(path, description)
  assert_true(
    vim.wait(30000, function() return vim.uv.fs_stat(path) ~= nil end, 20),
    'timed out waiting for ' .. description
  )
end

local function write_marker(path, contents)
  assert_true(vim.fn.writefile({ contents or 'ready' }, path) == 0, 'could not write marker ' .. path)
end

local function run_save(api)
  list_root(api)

  local alpha = row_number('alpha.txt')
  vim.api.nvim_buf_set_lines(0, alpha - 1, alpha, false, { 'renamed.txt' })
  save()

  local remove = row_number('remove.txt')
  vim.api.nvim_buf_set_lines(0, remove - 1, remove, false, {})
  save()

  local folder = row_number('folder' .. package.config:sub(1, 1))
  local yanked, yank_err = api.yank(folder, folder)
  assert_true(yanked == true, 'could not yank folder: ' .. tostring(yank_err))
  wait_for_idle()

  local pasted, paste_err = api.paste(assert(vim.env.DIRECT_E2E_DESTINATION))
  assert_true(pasted ~= nil, 'could not paste folder: ' .. tostring(paste_err))
  wait_for_idle()
  wait_for_path(vim.fs.joinpath(vim.env.DIRECT_E2E_DESTINATION, 'folder', 'payload.txt'), 'pasted folder')

  -- Exercise the normal write-and-quit path after the three persisted actions.
  vim.cmd('write')
  vim.cmd('qa!')
end

local function run_reverse(api, direction)
  list_root(api)
  for index = 1, 3 do
    local started, err = api[direction]()
    assert_true(started ~= nil, direction .. ' ' .. index .. ' did not start: ' .. tostring(err))
    wait_for_idle()
  end
  vim.cmd('qa!')
end

local function run_symlink_and_special_path(api)
  local listed, err = api.list(assert(vim.env.DIRECT_E2E_LINK))
  assert_true(listed ~= nil, 'could not list directory through symlink: ' .. tostring(err))
  local actual = assert(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)))
  local expected = assert(vim.uv.fs_realpath(vim.env.DIRECT_E2E_SPECIAL))
  assert_true(actual == expected, 'listing through symlink did not resolve to its target')
  assert_true(row_number('note.txt') > 0, 'special-character directory listing is missing its file')
  vim.cmd('qa!')
end

local function run_stale_wait(api)
  local notification_log = assert(vim.env.DIRECT_E2E_NOTIFICATION_LOG)
  local original_notify = vim.notify
  vim.notify = function(message) vim.fn.writefile({ tostring(message) }, notification_log, 'a') end

  list_root(api)
  local shared = row_number('shared.txt')
  vim.api.nvim_buf_set_lines(0, shared - 1, shared, false, { 'stale-shared.txt' })
  write_marker(assert(vim.env.DIRECT_E2E_READY))
  wait_for_path(assert(vim.env.DIRECT_E2E_PROCEED), 'the second process save')
  vim.cmd('write')
  wait_for_idle()
  vim.notify = original_notify
  vim.cmd('qa!')
end

local function run_stale_fresh_save(api)
  list_root(api)
  local shared = row_number('shared.txt')
  vim.api.nvim_buf_set_lines(0, shared - 1, shared, false, { 'fresh-shared.txt' })
  save()
  vim.cmd('qa!')
end

local function main()
  local repo = assert(vim.env.DIRECT_E2E_REPO)
  vim.opt.runtimepath:prepend(repo)
  package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
  vim.cmd('runtime plugin/direct.lua')

  local api = require('direct')
  api.setup({ undo_confirm = false, git = { enabled = false } })

  local mode = assert(vim.env.DIRECT_E2E_MODE)
  if mode == 'save' then return run_save(api) end
  if mode == 'undo' then return run_reverse(api, 'undo') end
  if mode == 'redo' then return run_reverse(api, 'redo') end
  if mode == 'symlink_and_special_path' then return run_symlink_and_special_path(api) end
  if mode == 'stale_wait' then return run_stale_wait(api) end
  if mode == 'stale_fresh_save' then return run_stale_fresh_save(api) end
  error('unknown e2e mode: ' .. mode)
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
  io.stderr:write('E2E_PHASE_FAILED\n' .. tostring(err) .. '\n')
  vim.cmd('cquit 1')
end
