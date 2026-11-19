-- direct.trash.metadata -- trash sidecar metadata and payload path helpers.
local M = {}

local fs = require('direct.fs')
local paths = require('direct.paths')
local log = require('direct.log')

local METADATA_SUFFIX = '.direct-trash.json'

M.SUFFIX = METADATA_SUFFIX

function M.path(trash_path) return trash_path .. METADATA_SUFFIX end

function M.reserved(trash_path)
  local bytes, _, exists = log.read_raw(M.path(trash_path))
  if not exists or not bytes then return false end
  local ok, value = pcall(vim.json.decode, bytes)
  return ok and type(value) == 'table' and value.format == 'direct-trash' and value.reserved == true
end

local function lstat(path)
  local ok, stat = pcall(vim.uv.fs_lstat, path)
  return ok and stat or nil
end

local function metadata(original_path, reserved, purpose)
  local stat = lstat(original_path)
  local value = {
    format = 'direct-trash',
    version = 1,
    original = paths.canonical(paths.root(original_path)),
    deleted_at = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    deleted_at_epoch = os.time(),
    deleted_at_estimated = false,
    kind = stat and stat.type or 'unknown',
    reserved = reserved == true,
  }
  if purpose ~= nil then value.purpose = purpose end
  return value
end

function M.write(trash_path, original_path, purpose)
  local metadata_path = M.path(trash_path)
  local parent, parent_err = fs.mkdirp(fs.dirname(metadata_path))
  if not parent then return nil, parent_err end
  local bytes = vim.json.encode(metadata(original_path, false, purpose)) .. '\n'
  local existing, read_err, exists = log.read_raw(metadata_path)
  if read_err then return nil, read_err end
  if exists then
    local ok, old = pcall(vim.json.decode, existing)
    if
      not ok
      or type(old) ~= 'table'
      or old.format ~= 'direct-trash'
      or old.version ~= 1
      or old.reserved ~= true
      or old.original ~= paths.canonical(paths.root(original_path))
    then
      return nil, 'trash slot metadata already exists'
    end
    return log.write_raw_atomic(metadata_path, bytes)
  end
  return log.write_raw_exclusive(metadata_path, bytes)
end

function M.recover(trash_path, original_path, kind, deleted_at_epoch)
  if not fs.taken(trash_path) then return nil, 'trash entry is no longer present' end
  local original = paths.canonical(paths.root(original_path))
  local valid, valid_err = paths.validate_canonical_path(original)
  if not valid then return nil, 'invalid recovered trash path: ' .. tostring(valid_err) end
  if type(deleted_at_epoch) ~= 'number' or deleted_at_epoch <= 0 then deleted_at_epoch = os.time() end
  if kind ~= 'file' and kind ~= 'directory' and kind ~= 'link' and kind ~= 'unknown' then kind = 'unknown' end
  local value = {
    format = 'direct-trash',
    version = 1,
    original = original,
    deleted_at = os.date('!%Y-%m-%dT%H:%M:%SZ', deleted_at_epoch),
    deleted_at_epoch = deleted_at_epoch,
    deleted_at_estimated = true,
    kind = kind,
    reserved = false,
  }
  return log.write_raw_exclusive(M.path(trash_path), vim.json.encode(value) .. '\n')
end

function M.write_reservation(trash_path, original_path)
  local metadata_path = M.path(trash_path)
  local parent, parent_err = fs.mkdirp(fs.dirname(metadata_path))
  if not parent then return nil, parent_err end
  local bytes = vim.json.encode(metadata(original_path, true)) .. '\n'
  local existing, read_err, exists = log.read_raw(metadata_path)
  if read_err then return nil, read_err end
  if exists then
    local ok, old = pcall(vim.json.decode, existing)
    if
      not ok
      or type(old) ~= 'table'
      or old.format ~= 'direct-trash'
      or old.version ~= 1
      or old.original ~= paths.canonical(paths.root(original_path))
    then
      return nil, 'trash slot metadata is damaged'
    end
    return log.write_raw_atomic(metadata_path, bytes)
  end
  return log.write_raw_exclusive(metadata_path, bytes)
end

function M.clear(trash_path)
  local path = M.path(trash_path)
  if not fs.taken(path) then return true end
  return fs.rm_file(path)
end

function M.first_free(trash_dir, src)
  local base = paths.digest(src)
  local dst = fs.join(trash_dir, base)
  if not fs.taken(dst) and not fs.taken(M.path(dst)) then return dst end
  local n = 1
  while fs.taken(dst .. '-' .. n) or fs.taken(M.path(dst .. '-' .. n)) do
    n = n + 1
  end
  return dst .. '-' .. n
end

return M
