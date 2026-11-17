-- Same-host advisory lock shared by Direct processes using the same data home.
-- The lock file is intentionally persistent: unlinking it could let waiters lock
-- different inodes. The platform adapter owns the native lock implementation,
-- which the OS releases if Neovim exits or crashes.
local M = {}
local platform = require('direct.platform')
M.uv = vim.uv

local depth, token = 0, nil
local held_path
local acquiring = false
local sync_waiting = false
local RETRY_TIMEOUT_MS = 2000
local RETRY_INTERVAL_MS = 50

local function owner_path(path) return path .. '.owner' end

local function lock_path()
  local paths = require('direct.paths')
  local fs = require('direct.fs')
  local constants = require('direct.constants')
  local direct_dir = paths.join(paths.data_home(), constants.DATA_DIRECTORY)
  local ok, err = fs.mkdirp(direct_dir)
  if not ok then return nil, err end
  return paths.join(direct_dir, '.direct-history.lock')
end

local function write_owner(path, pid)
  -- Windows' byte-range lock also blocks reads of the lock file, so keep the
  -- advisory PID in a separate same-directory file instead of touching it.
  local fd, err = M.uv.fs_open(owner_path(path), 'w', 384)
  if not fd then return nil, err end
  local bytes = pid and (tostring(pid) .. '\n') or ''
  if bytes ~= '' then
    local written, write_err = M.uv.fs_write(fd, bytes, 0)
    if not written then
      M.uv.fs_close(fd)
      return nil, write_err
    end
  end
  local closed, close_err = M.uv.fs_close(fd)
  if not closed then return nil, close_err end
  return true
end

local function read_owner(path)
  local fd = M.uv.fs_open(owner_path(path), 'r', 0)
  if not fd then return nil end
  local bytes = M.uv.fs_read(fd, 128, 0)
  M.uv.fs_close(fd)
  return type(bytes) == 'string' and bytes:match('^%s*(%d+)') or nil
end

local function busy_message(path)
  local pid = read_owner(path)
  return 'another Neovim instance is using direct.vim history'
    .. (pid and (' (PID ' .. pid .. ')') or '')
    .. '; retry the operation'
end

local function remember_lock(path, acquired)
  token, depth = acquired, 1
  held_path = path
  -- PID data is advisory only. A lock still protects the history if this
  -- metadata cannot be written (for example, on a read-only lock file).
  pcall(write_owner, path, M.uv.os_getpid())
end

local function try_acquire(path)
  if depth > 0 then
    depth = depth + 1
    return true
  end
  local acquired, err, code = platform.acquire_file_lock(path)
  if acquired then
    remember_lock(path, acquired)
    return true
  end
  return nil, err, code
end

local function pending_module() return require('direct.pending') end

function M.acquire()
  if depth > 0 then
    depth = depth + 1
    return true
  end
  if acquiring or sync_waiting then return nil, 'history lock acquisition is pending' end

  local path, path_err = lock_path()
  if not path then return nil, path_err end
  local acquired, acquire_err, code = try_acquire(path)
  if acquired or code ~= 'EWOULDBLOCK' then return acquired, acquire_err end

  -- A synchronous retry pumps the editor event loop. Reserve the Direct
  -- pending guard before entering it so a second key-driven operation cannot
  -- start in the middle of this wait.
  local pending = pending_module()
  if pending.is_pending() then return nil, 'another direct operation is pending' end
  local began, wait_token = pending.begin('history lock')
  if not began then return nil, wait_token end
  local last_err, last_code = acquire_err, code
  sync_waiting = true
  vim.wait(RETRY_TIMEOUT_MS, function()
    acquired, last_err, last_code = try_acquire(path)
    return acquired ~= nil or last_code ~= 'EWOULDBLOCK'
  end, RETRY_INTERVAL_MS)
  sync_waiting = false
  pending.finish(wait_token)
  if acquired then return acquired end
  if last_code == 'EWOULDBLOCK' then return nil, busy_message(path) end
  return nil, last_err
end

-- Retry a contended lock without blocking Neovim's main thread. The lock
-- bookkeeping is updated only after the native lock is actually acquired.
function M.acquire_async(callback)
  if type(callback) ~= 'function' then return nil, 'history.lock.acquire_async: a callback is required' end
  if depth > 0 then
    depth = depth + 1
    callback(true)
    return true
  end
  if acquiring or sync_waiting then
    vim.schedule(function() callback(nil, 'history lock acquisition is pending') end)
    return true
  end

  local path, path_err = lock_path()
  if not path then
    callback(nil, path_err)
    return true
  end
  local acquired, acquire_err, code = try_acquire(path)
  if acquired or code ~= 'EWOULDBLOCK' then
    callback(acquired, acquire_err)
    return true
  end

  acquiring = true
  local timer = M.uv.new_timer()
  local deadline = M.uv.hrtime() + RETRY_TIMEOUT_MS * 1000000
  local done = false
  local function finish(result, err)
    if done then return end
    done = true
    acquiring = false
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    vim.schedule(function() callback(result, err) end)
  end
  timer:start(RETRY_INTERVAL_MS, RETRY_INTERVAL_MS, function()
    local locked, last_err, last_code = platform.acquire_file_lock(path)
    if locked then
      remember_lock(path, locked)
      finish(true)
    elseif last_code ~= 'EWOULDBLOCK' then
      finish(nil, last_err)
    elseif M.uv.hrtime() >= deadline then
      finish(nil, busy_message(path))
    end
  end)
  return true
end

function M.release()
  if depth == 0 then return true end
  depth = depth - 1
  if depth > 0 then return true end
  local held, path = token, held_path
  token = nil
  held_path = nil
  if path then pcall(write_owner, path, nil) end
  return platform.release_file_lock(held)
end

return M
