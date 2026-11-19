-- lua/direct/register/store.lua -- persistence and snapshot storage for the
-- yank/paste register.

local M = {}

local fs = require('direct.fs')
local paths = require('direct.paths')
local action = require('direct.action.action')
local log = require('direct.log')

-- content -> the absolute register path recorded in register/content (the
-- yanked entry directory), or nil when no yank has happened.
function M.content()
  local dir = paths.data_dir_path('register')
  local content_path = paths.join(dir, 'content')
  if vim.fn.filereadable(content_path) ~= 1 then return nil end
  local ok, lines = pcall(vim.fn.readfile, content_path)
  if not ok or type(lines) ~= 'table' or #lines == 0 then return nil end
  return lines[1]
end

function M.content_identity()
  local path = paths.join(paths.data_dir_path('register'), 'content')
  return fs.entry_identity(path)
end

-- A delete-backed register keeps no copies. It stores a manifest next to the
-- content directory that maps each yanked basename to its trash payload, so
-- paste and the undo proof copy from trash instead of duplicating the tree.
function M.manifest_path(dir) return dir .. '.manifest' end

function M.read_manifest(dir)
  local path = M.manifest_path(dir)
  if vim.fn.filereadable(path) ~= 1 then return nil, nil, false end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= 'table' or #lines == 0 then return nil, 'register manifest is unreadable', true end
  local decoded, payload = pcall(vim.json.decode, lines[1])
  if
    not decoded
    or type(payload) ~= 'table'
    or payload.format ~= 'direct-register'
    or type(payload.entries) ~= 'table'
  then
    return nil, 'register manifest is malformed', true
  end
  local entries, seen = {}, {}
  for _, value in ipairs(payload.entries) do
    if type(value) ~= 'table' or type(value.name) ~= 'string' or type(value.path) ~= 'string' then
      return nil, 'register manifest is malformed', true
    end
    local reason = action.entry_name_reason(value.name)
    if reason ~= nil or seen[value.name] then return nil, 'register manifest has an invalid entry name', true end
    local path_ok = paths.validate_canonical_path(value.path)
    if not path_ok then return nil, 'register manifest has an invalid path', true end
    local original
    if value.original ~= nil then
      if type(value.original) ~= 'string' or not paths.validate_canonical_path(value.original) then
        return nil, 'register manifest has an invalid original path', true
      end
      original = value.original
    end
    seen[value.name] = true
    entries[#entries + 1] = { name = value.name, path = value.path, original = original }
  end
  table.sort(entries, function(a, b) return a.name < b.name end)
  return entries, nil, true
end

function M.write_manifest(dir, entries)
  local payload_entries = {}
  for _, entry in ipairs(entries) do
    payload_entries[#payload_entries + 1] = {
      name = entry.name,
      path = entry.path,
      original = entry.original,
    }
  end
  local ok, encoded = pcall(vim.json.encode, { format = 'direct-register', entries = payload_entries })
  if not ok then return nil, 'could not encode register manifest' end
  return log.write(M.manifest_path(dir), { encoded })
end

-- entries(dir) -> {{name, path, original}, ...} | nil, err. Manifest-backed
-- registers resolve each name to its trash payload; ordinary yanks list the
-- copied entries in the content directory.
function M.entries(dir)
  if type(dir) ~= 'string' then return nil, 'register path is missing' end
  local manifest, manifest_err, has_manifest = M.read_manifest(dir)
  if has_manifest then
    if not manifest then return nil, manifest_err end
    return manifest
  end
  local names, list_err = fs.list_dir(dir)
  if not names then return nil, list_err end
  local entries = {}
  for _, name in ipairs(names) do
    entries[#entries + 1] = { name = name, path = paths.join(dir, name) }
  end
  table.sort(entries, function(a, b) return a.name < b.name end)
  return entries
end

-- entry_path(dir, name) returns the persisted source path, plus the original
-- source path for a delete-backed entry. nil means the name is not registered.
function M.entry_path(dir, name)
  local manifest, _, has_manifest = M.read_manifest(dir)
  if has_manifest then
    for _, entry in ipairs(manifest or {}) do
      if entry.name == name then return entry.path, entry.original end
    end
    return nil
  end
  return paths.join(dir, name)
end

-- resolve_entry(entry) returns an existing path for a register entry. A
-- restored trash entry falls back to its original path.
function M.resolve_entry(entry)
  local reserved = entry.path and action.trash_reserved(entry.path)
  if entry.path and fs.exists(entry.path) and not reserved then return entry.path end
  if reserved and entry.original and fs.exists(entry.original) then return entry.original end
  return nil
end

-- resolve(dir, name) returns a source that still exists. A restored trash
-- entry falls back to its original path; nil means it can no longer be pasted.
function M.resolve(dir, name)
  local path, original = M.entry_path(dir, name)
  return M.resolve_entry({ path = path, original = original })
end

function M.entry_names(dir)
  local entries, err = M.entries(dir)
  if not entries then return nil, err end
  local names = {}
  for _, entry in ipairs(entries) do
    names[#names + 1] = entry.name
  end
  return names
end

local function register_snapshot_name(name)
  if type(name) ~= 'string' then return false end
  if #name ~= 64 then return false end
  return name:match('^%x+$') ~= nil
end

local cached_paste_signature

local function line_has_paste_reference(line)
  return type(line) == 'string'
    and (
      line:find('"op":"p"', 1, true) ~= nil
      or line:find('"op":"up"', 1, true) ~= nil
      or line:find('\\"op\\":\\"p\\"', 1, true) ~= nil
      or line:find('\\"op\\":\\"up\\"', 1, true) ~= nil
    )
end

local function paste_reference_signature(undo_lines, redo_lines)
  local dir = paths.data_dir_path('register')
  local content = M.content()
  local parts = {
    dir and paths.canonical(dir) or '',
    content and paths.canonical(content) or '',
  }
  for stack_index, lines in ipairs({ undo_lines or {}, redo_lines or {} }) do
    for index = 2, #lines do
      local line = lines[index]
      if line_has_paste_reference(line) then
        parts[#parts + 1] = tostring(stack_index) .. ':' .. tostring(index) .. ':' .. line
      end
    end
  end
  return table.concat(parts, '\0')
end

-- prune_unreferenced(undo_lines, redo_lines) removes copied snapshots that are
-- neither the current register nor named by a paste still on either stack. It
-- skips unchanged paste-reference sets and deserializes only paste-bearing lines.
function M.prune_unreferenced(undo_lines, redo_lines, force)
  local signature = paste_reference_signature(undo_lines, redo_lines)
  if not force and signature == cached_paste_signature then return true, 0 end
  local dir = paths.data_dir_path('register')
  local names, list_err = fs.list_dir(dir)
  if not names then
    if not fs.exists(dir) then
      cached_paste_signature = signature
      return true, 0
    end
    return nil, list_err or 'cannot list register directory'
  end

  local references = {}
  local function add(path)
    if type(path) == 'string' and path ~= '' then references[paths.canonical(path)] = true end
  end
  local function visit(current)
    if type(current) ~= 'table' then return end
    if current.name == 'p' then
      add(current.src)
    elseif current.name == 'up' then
      add(current.dst)
    end
    for _, member in ipairs(current.actions or {}) do
      visit(member)
    end
  end
  for _, lines in ipairs({ undo_lines or {}, redo_lines or {} }) do
    for index = 2, #lines do
      if line_has_paste_reference(lines[index]) then
        local ok, parsed = pcall(action.deserialize, lines[index])
        if ok and parsed then visit(parsed) end
      end
    end
  end

  local current = M.content()
  local keep = {}
  if current then keep[paths.canonical(current)] = true end
  for path in pairs(references) do
    keep[path] = true
  end

  local removed, first_err = 0, nil
  local function remove(path, directory)
    local ok, err
    if directory then
      ok, err = fs.rm_tree(path)
    else
      ok, err = fs.rm_file(path)
    end
    if not ok then
      first_err = first_err or err or ('could not remove ' .. path)
      return false
    end
    removed = removed + 1
    return true
  end

  for _, name in ipairs(names) do
    if register_snapshot_name(name) then
      local path = paths.join(dir, name)
      if not keep[paths.canonical(path)] then
        local stat = vim.uv.fs_lstat(path)
        if stat and stat.type == 'directory' and remove(path, true) then
          local sidecar = M.manifest_path(path)
          if fs.exists(sidecar) then remove(sidecar, false) end
        end
      end
    else
      local digest = name:match('^(%x+)%.manifest$')
      if digest and #digest == 64 then
        local base = paths.join(dir, digest)
        local sidecar = paths.join(dir, name)
        if not keep[paths.canonical(base)] and fs.exists(sidecar) then remove(sidecar, false) end
      end
    end
  end
  if first_err then return nil, first_err end
  cached_paste_signature = signature
  return true, removed
end

local function size_path(path)
  local stat = vim.uv.fs_lstat(path)
  if not stat then return nil, 'cannot inspect register path: ' .. tostring(path) end
  if stat.type ~= 'directory' then return stat.size or 0 end
  local scan, scan_err = vim.uv.fs_scandir(path)
  if not scan then return nil, tostring(scan_err or ('cannot scan ' .. path)) end
  local total = 0
  while true do
    local name = vim.uv.fs_scandir_next(scan)
    if not name then break end
    local child_size, child_err = size_path(paths.join(path, name))
    if not child_size then return nil, child_err end
    total = total + child_size
  end
  return total
end

-- size_bytes() includes snapshots, manifests and the current-content pointer.
function M.size_bytes()
  local dir = paths.data_dir_path('register')
  local called, stat, stat_err, stat_code = pcall(vim.uv.fs_lstat, dir)
  if not called then return nil, tostring(stat) end
  if not stat then
    if stat_code == 'ENOENT' then return 0 end
    return nil, tostring(stat_err or stat_code or 'cannot inspect register directory')
  end
  if stat.type ~= 'directory' then return nil, 'register path is not a directory' end
  local sized, total, size_err = pcall(size_path, dir)
  if not sized then return nil, tostring(total) end
  return total, size_err
end

local async_yank_sequence = 0

function M.allocate_async_snapshot_dir(dir)
  for _ = 1, 100 do
    async_yank_sequence = async_yank_sequence + 1
    local name = string.format('.direct-yank-%s-%d', tostring(vim.uv.os_getpid()), async_yank_sequence)
    local path = paths.join(dir, name)
    local made, err, code = fs.mkdir_exclusive(path, 448)
    if made then return path end
    if code ~= 'EEXIST' then return nil, err end
  end
  return nil, 'could not allocate a private register copy directory'
end

function M.commit_async_snapshot(temp, dir, sorted_sources)
  local digest = paths.digest(sorted_sources)
  local pid = tostring(vim.uv.os_getpid())
  for attempt = 0, 100 do
    local name = digest
    if attempt > 0 then
      async_yank_sequence = async_yank_sequence + 1
      name = paths.digest({
        digest,
        pid,
        tostring(vim.uv.hrtime()),
        tostring(async_yank_sequence),
        tostring(attempt),
      })
    end
    local path = paths.join(dir, name)
    if not fs.exists(M.manifest_path(path)) then
      local moved, err, code = fs.rename_noreplace(temp, path)
      if moved then return path end
      if code ~= 'EEXIST' then return nil, err end
    end
  end
  return nil, 'could not allocate a unique register snapshot directory'
end

function M.discard_async_snapshot(path)
  if not path then return true end
  local ok, err = fs.rm_tree(path)
  if not ok then return nil, err end
  local sidecar = M.manifest_path(path)
  if fs.exists(sidecar) then return fs.rm_file(sidecar) end
  return true
end

return M
