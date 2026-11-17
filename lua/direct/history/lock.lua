-- Same-host advisory lock shared by Direct processes using the same data home.
-- The lock file is intentionally persistent: unlinking it could let waiters lock
-- different inodes. The platform adapter owns the native lock implementation,
-- which the OS releases if Neovim exits or crashes.
local M = {}
local platform = require('direct.platform')
M.uv = vim.uv

local depth, token = 0, nil
local held_path
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

local function acquire_file_lock(path)
  local acquired, err, code = platform.acquire_file_lock(path)
  if acquired or code ~= 'EWOULDBLOCK' then return acquired, err end

  local last_err, last_code = err, code
  vim.wait(RETRY_TIMEOUT_MS, function()
    acquired, last_err, last_code = platform.acquire_file_lock(path)
    return acquired ~= nil or last_code ~= 'EWOULDBLOCK'
  end, RETRY_INTERVAL_MS)
  if acquired then return acquired end
  if last_code == 'EWOULDBLOCK' then return nil, busy_message(path) end
  return nil, last_err
end

function M.acquire()
  if depth > 0 then
    depth = depth + 1
    return true
  end
  local path, path_err = lock_path()
  if not path then return nil, path_err end
  local acquired, acquire_err = acquire_file_lock(path)
  if not acquired then return nil, acquire_err end
  token, depth = acquired, 1
  held_path = path
  -- PID data is advisory only. A lock still protects the history if this
  -- metadata cannot be written (for example, on a read-only lock file).
  pcall(write_owner, path, M.uv.os_getpid())
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
