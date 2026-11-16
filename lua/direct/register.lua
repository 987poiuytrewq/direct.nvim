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

-- content -> the absolute register path recorded in register/content (the
-- yanked entry directory), or nil when no yank has happened, or nil, err when
-- the register data dir cannot be resolved.
function M.content()
  local dir = M.paths.data_dir_path('register')
  local content_path = M.paths.join(dir, 'content')
  if vim.fn.filereadable(content_path) ~= 1 then return nil end
  local ok, lines = pcall(vim.fn.readfile, content_path)
  if not ok or type(lines) ~= 'table' or #lines == 0 then return nil end
  return lines[1]
end

local function content_identity()
  local path = M.paths.join(M.paths.data_dir_path('register'), 'content')
  return M.fs.entry_identity(path)
end

-- A delete-backed register keeps no copies. It stores a manifest next to the
-- content directory that maps each yanked basename to its trash payload, so
-- paste and the undo proof copy from trash instead of duplicating the tree.
local function manifest_path(dir) return dir .. '.manifest' end

local function read_manifest(dir)
  local path = manifest_path(dir)
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
    local reason = M.action.entry_name_reason(value.name)
    if reason ~= nil or seen[value.name] then return nil, 'register manifest has an invalid entry name', true end
    local path_ok = M.paths.validate_canonical_path(value.path)
    if not path_ok then return nil, 'register manifest has an invalid path', true end
    local original
    if value.original ~= nil then
      if type(value.original) ~= 'string' or not M.paths.validate_canonical_path(value.original) then
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

local function write_manifest(dir, entries)
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
  return M.log.write(manifest_path(dir), { encoded })
end

-- entries(dir) -> {{name, path, original}, ...} | nil, err. Manifest-backed
-- registers resolve each name to its trash payload; ordinary yanks list the
-- copied entries in the content directory.
function M.entries(dir)
  if type(dir) ~= 'string' then return nil, 'register path is missing' end
  local manifest, manifest_err, has_manifest = read_manifest(dir)
  if has_manifest then
    if not manifest then return nil, manifest_err end
    return manifest
  end
  local names, list_err = M.fs.list_dir(dir)
  if not names then return nil, list_err end
  local entries = {}
  for _, name in ipairs(names) do
    entries[#entries + 1] = { name = name, path = M.paths.join(dir, name) }
  end
  table.sort(entries, function(a, b) return a.name < b.name end)
  return entries
end

-- entry_path(dir, name) returns the persisted source path, plus the original
-- source path for a delete-backed entry. nil means the name is not registered.
function M.entry_path(dir, name)
  local manifest, _, has_manifest = read_manifest(dir)
  if has_manifest then
    for _, entry in ipairs(manifest or {}) do
      if entry.name == name then return entry.path, entry.original end
    end
    return nil
  end
  return M.paths.join(dir, name)
end

-- resolve_entry(entry) returns an existing path for a register entry. A
-- restored trash entry falls back to its original path.
local function resolve_entry(entry)
  local reserved = entry.path and M.action.trash_reserved(entry.path)
  if entry.path and M.fs.exists(entry.path) and not reserved then return entry.path end
  if reserved and entry.original and M.fs.exists(entry.original) then return entry.original end
  return nil
end

-- resolve(dir, name) returns a source that still exists. A restored trash
-- entry falls back to its original path; nil means it can no longer be pasted.
function M.resolve(dir, name)
  local path, original = M.entry_path(dir, name)
  return resolve_entry({ path = path, original = original })
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

-- prune_unreferenced(undo_lines, redo_lines) removes copied snapshots that are
-- neither the current register nor named by a paste still on either stack.
function M.prune_unreferenced(undo_lines, redo_lines)
  local dir = M.paths.data_dir_path('register')
  local names, list_err = M.fs.list_dir(dir)
  if not names then
    if not M.fs.exists(dir) then return true, 0 end
    return nil, list_err or 'cannot list register directory'
  end

  local references = {}
  local function add(path)
    if type(path) == 'string' and path ~= '' then references[M.paths.canonical(path)] = true end
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
      local ok, parsed = pcall(M.action.deserialize, lines[index])
      if ok and parsed then visit(parsed) end
    end
  end

  local current = M.content()
  local keep = {}
  if current then keep[M.paths.canonical(current)] = true end
  for path in pairs(references) do
    keep[path] = true
  end

  local removed, first_err = 0, nil
  local function remove(path, directory)
    local ok, err
    if directory then
      ok, err = M.fs.rm_tree(path)
    else
      ok, err = M.fs.rm_file(path)
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
      local path = M.paths.join(dir, name)
      if not keep[M.paths.canonical(path)] then
        local stat = vim.uv.fs_lstat(path)
        if stat and stat.type == 'directory' and remove(path, true) then
          local sidecar = manifest_path(path)
          if M.fs.exists(sidecar) then remove(sidecar, false) end
        end
      end
    else
      local digest = name:match('^(%x+)%.manifest$')
      if digest and #digest == 64 then
        local base = M.paths.join(dir, digest)
        local sidecar = M.paths.join(dir, name)
        if not keep[M.paths.canonical(base)] and M.fs.exists(sidecar) then remove(sidecar, false) end
      end
    end
  end
  if first_err then return nil, first_err end
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
    local child_size, child_err = size_path(M.paths.join(path, name))
    if not child_size then return nil, child_err end
    total = total + child_size
  end
  return total
end

-- size_bytes() includes snapshots, manifests and the current-content pointer.
function M.size_bytes()
  local dir = M.paths.data_dir_path('register')
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

local function cleanup_unreferenced(undo_lines, redo_lines)
  local called, cleaned, clean_err = pcall(M.prune_unreferenced, undo_lines, redo_lines)
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
    if M.fs.exists(manifest_path(dst)) then
      local ok, merr = M.fs.rm_file(manifest_path(dst))
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

local async_yank_sequence = 0
local function allocate_async_snapshot_dir(dir)
  for _ = 1, 100 do
    async_yank_sequence = async_yank_sequence + 1
    local name = string.format('.direct-yank-%s-%d', tostring(vim.uv.os_getpid()), async_yank_sequence)
    local path = M.paths.join(dir, name)
    local made, err, code = M.fs.mkdir_exclusive(path, 448)
    if made then return path end
    if code ~= 'EEXIST' then return nil, err end
  end
  return nil, 'could not allocate a private register copy directory'
end

local function commit_async_snapshot(temp, dir, sorted_sources)
  local digest = M.paths.digest(sorted_sources)
  local pid = tostring(vim.uv.os_getpid())
  for attempt = 0, 100 do
    local name = digest
    if attempt > 0 then
      async_yank_sequence = async_yank_sequence + 1
      name = M.paths.digest({
        digest,
        pid,
        tostring(vim.uv.hrtime()),
        tostring(async_yank_sequence),
        tostring(attempt),
      })
    end
    local path = M.paths.join(dir, name)
    if not M.fs.exists(manifest_path(path)) then
      local moved, err, code = M.fs.rename_noreplace(temp, path)
      if moved then return path end
      if code ~= 'EEXIST' then return nil, err end
    end
  end
  return nil, 'could not allocate a unique register snapshot directory'
end

local function discard_async_snapshot(path)
  if not path then return true end
  local ok, err = M.fs.rm_tree(path)
  if not ok then return nil, err end
  local sidecar = manifest_path(path)
  if M.fs.exists(sidecar) then return M.fs.rm_file(sidecar) end
  return true
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

  local function acquire_lock()
    if lock_held then return true end
    local acquired, err = M.history.lock.acquire()
    if not acquired then return nil, err end
    lock_held = true
    return true
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
      local removed, remove_err = discard_async_snapshot(dst)
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

  local acquired, acquire_err = acquire_lock()
  if not acquired then return fail_start(acquire_err) end
  local initial_state, initial_preflight_err = M.history.preflight(sources)
  if not initial_state then return fail_start(initial_preflight_err) end
  previous_content = M.content()
  previous_identity = content_identity()

  local dir, dir_err = M.paths.ensure_data_dir('register')
  if not dir then return fail_start(dir_err) end
  local sorted = vim.deepcopy(sources)
  table.sort(sorted)
  dst, dir_err = allocate_async_snapshot_dir(dir)
  if not dst then return fail_start(dir_err) end
  local released, release_err = release_lock()
  if not released then return fail_start(release_err) end

  local function switch_register()
    local locked, lock_err = acquire_lock()
    if not locked then return nil, lock_err end
    local state, preflight_err = M.history.preflight(sources)
    if not state then return nil, preflight_err end
    local current_content = M.content()
    local current_identity = content_identity()
    if current_content ~= previous_content or not vim.deep_equal(current_identity, previous_identity) then
      return nil, 'register changed while yank was copying; the newer register was kept'
    end
    local snapshot, rename_err = commit_async_snapshot(dst, dir, sorted)
    if not snapshot then return nil, rename_err end
    dst = snapshot
    local written, write_err = M.log.write(M.paths.join(dir, 'content'), { dst })
    if not written then return nil, write_err end
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
    return true
  end

  local index = 1
  local function next_source()
    if index > #sources then
      local switched, switch_err = switch_register()
      if not switched then return settle(false, switch_err) end
      return settle(true)
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
    local written, write_err = write_manifest(dst, manifest_entries)
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

-- paste(dst[, name[, callback]]) -> scheduled/result | nil, err.
-- This service owns filesystem and history effects. The facade owns view refresh.
--
-- `name` is the `:DirectPasteAs {name}` extension: when given, the
-- first pasted entry (the smallest source name, matching Paste's sorted
-- `renames`) is pasted as `name` instead. `callback(result, err, succeeded, changed)`
-- runs once the asynchronous operation settles.
function M.paste(dst, name, callback)
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
  local preflight, preflight_err = M.history.preflight({ dst })
  if not preflight then return nil, preflight_err end
  local src, cerr = M.content()
  if src == nil then
    if cerr ~= nil then
      M.ui.notify('direct: register unavailable: ' .. tostring(cerr), vim.log.levels.ERROR)
      return nil, cerr
    end
    M.ui.notify('Register is empty', vim.log.levels.WARN)
    return nil
  end
  local entries, entries_err = M.entries(src)
  if not entries then
    M.ui.notify('direct: cannot read register: ' .. tostring(entries_err or src), vim.log.levels.ERROR)
    return nil, 'cannot read register'
  end
  -- The persisted register is untrusted. Validate each entry as one basename
  -- component before building the JSONL record or copying it. A delete-backed
  -- entry whose trash payload was restored or removed is reported and skipped.
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
  if name ~= nil and name ~= '' then
    local name_reason = M.action.entry_name_reason(name)
    if name_reason ~= nil then
      local msg = 'cannot paste: entry name ' .. name_reason .. ': ' .. tostring(name)
      M.ui.notify('direct: ' .. msg, vim.log.levels.ERROR)
      return nil, msg
    end
    dst_names[1] = name
  end
  local paste_action = M.action.Paste(src, dst, pasteable, dst_names)
  -- Validate the exact record before copying; a malformed path must not create
  -- a destination that cannot be undone.
  local _, unsafe = M.action.serialize(paste_action)
  if unsafe ~= nil then
    local msg = 'cannot paste: unrepresentable path: ' .. tostring(unsafe)
    M.ui.notify('direct: ' .. msg, vim.log.levels.ERROR)
    return nil, msg
  end
  local began, begin_err = M.pending.begin('paste')
  if not began then
    M.ui.notify('direct: cannot paste: ' .. tostring(begin_err), vim.log.levels.WARN)
    return nil, begin_err
  end
  local operation
  local paste_base_undo
  local paste_segment_records = {}
  local function begin_paste_segment()
    if operation and operation.locked then return true end
    local fresh, paste_begin_err = M.history.begin_paste(paste_action)
    if not fresh then return nil, paste_begin_err end
    operation = fresh
    if paste_base_undo == nil then paste_base_undo = vim.deepcopy(fresh.transaction.base_undo) end

    local current_register = M.content()
    local current_names = current_register == src and M.entry_names(src) or nil
    local current_entries = current_register == src and M.entries(src) or nil
    local stable = current_register == src
      and vim.deep_equal(current_names, names)
      and vim.deep_equal(current_entries, entries)
    if stable then
      for _, entry_name in ipairs(pasteable) do
        if not M.resolve(src, entry_name) then
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

  local function finish_paste_segment()
    if not operation or not operation.locked then return true end
    local completed_pairs = operation.transaction.completed or {}
    local segment_record
    if #completed_pairs > 0 then
      local sources, destinations = {}, {}
      for _, pair in ipairs(completed_pairs) do
        sources[#sources + 1] = pair.src
        destinations[#destinations + 1] = pair.dst
      end
      local action = M.action.Paste(src, dst, sources, destinations)
      local serialize_err
      segment_record, serialize_err = M.action.serialize(action)
      if not segment_record then return nil, serialize_err end
    end
    local finished, finish_err = M.history.finish_paste(operation)
    operation = nil
    if not finished then return nil, finish_err end
    if segment_record then paste_segment_records[#paste_segment_records + 1] = segment_record end
    return true
  end

  local function coalesce_paste_segments()
    if #paste_segment_records < 2 then return true end
    local sources, destinations = {}, {}
    for _, pair in ipairs(paste_action.renames or {}) do
      sources[#sources + 1] = pair.src
      destinations[#destinations + 1] = pair.dst
    end
    local merged = M.action.Paste(src, dst, sources, destinations)
    local coalesced, err = M.history.coalesce_paste_segments(paste_base_undo, paste_segment_records, merged)
    if not coalesced then
      M.ui.notify('direct: pasted entries remain in separate undo steps: ' .. tostring(err), vim.log.levels.WARN)
      return nil, err
    end
    return true
  end

  local segment_started, segment_lock_err = begin_paste_segment()
  if not segment_started then
    M.pending.finish()
    M.ui.notify('direct: cannot paste: ' .. tostring(segment_lock_err), vim.log.levels.ERROR)
    return nil, segment_lock_err
  end
  paste_action._before_prompt = function()
    local ready, ready_err = begin_paste_segment()
    if not ready then return nil, ready_err end
    return finish_paste_segment()
  end
  paste_action._after_prompt = function(pair, _source, answer)
    pair.dst = answer
    local ready, ready_err = begin_paste_segment()
    if not ready then return nil, ready_err end
    if M.fs.taken(M.paths.join(dst, answer)) then
      local finished, finish_err = finish_paste_segment()
      if not finished then return nil, finish_err end
      return 'clash'
    end
    return true
  end
  paste_action._before_copy = function(pair, source, destination)
    local ready, ready_err = begin_paste_segment()
    if not ready then return nil, ready_err end
    return M.history.note_paste_pending(operation, pair, source, destination)
  end
  paste_action._after_copy = function(pair)
    if not operation or not operation.locked then return nil, 'paste history operation is not active' end
    return M.history.note_paste_complete(operation, pair)
  end
  paste_action._on_copy_conflict = function(pair)
    if not operation or not operation.locked then return nil, 'paste history operation is not active' end
    return M.history.cancel_paste_pending(operation, pair)
  end
  local completed, immediate_result, immediate_err = false, nil, nil
  local function finish(ok, result, execution_err)
    if completed then return end
    completed = true
    local changed = false
    local pasted_entry
    local final_ok, final_err = xpcall(function()
      local copied = #(paste_action.renames or {})
      changed = copied > 0
      if copied > 0 then
        file_operations.emit_actions({ paste_action })
        pasted_entry = type(result) == 'string' and result or nil
        if pasted_entry == nil then
          local last = paste_action.renames[copied]
          if last then pasted_entry = M.paths.join(dst, last.dst) end
        end
        if operation and operation.locked then
          local committed, commit_err = finish_paste_segment()
          if not committed then M.ui.report_error('save paste history', commit_err) end
        end
        if ok then
          M.ui.notify(M.action.summarize({ paste_action }), vim.log.levels.INFO)
        else
          M.ui.report_error('finish pasting; completed entries were kept', execution_err)
        end
      elseif not ok then
        M.ui.report_error('paste the entries', execution_err)
      else
        if operation and operation.locked then
          local committed, commit_err = finish_paste_segment()
          if not committed then M.ui.report_error('finish the paste operation', commit_err) end
        end
      end
      if #paste_segment_records > 1 then coalesce_paste_segments() end
    end, debug.traceback)
    if operation and operation.locked then finish_paste_segment() end
    M.pending.finish()
    if not final_ok then
      M.ui.report_error('finish the paste operation', final_err)
      ok, result, execution_err = false, nil, final_err
    end
    immediate_result = result
    immediate_err = execution_err
    if type(callback) == 'function' then
      local called, callback_err = pcall(callback, result, execution_err, ok, changed, pasted_entry)
      if not called then M.ui.report_error('refresh after pasting', callback_err) end
      execution_err = execution_err or (not called and callback_err or nil)
    end
    events.emit('DirectPastePost', {
      root = dst,
      actions = changed and { paste_action } or {},
      success = ok and final_ok,
      changed = changed,
      error = execution_err or final_err,
      entry = pasted_entry,
    })
  end
  local called, start_result, start_err = pcall(M.action.execute_async, paste_action, finish)
  if not called then
    finish(false, nil, start_result)
  elseif start_result == nil then
    finish(false, nil, start_err or 'could not start paste')
  end
  if completed then return immediate_result, immediate_err end
  return true
end

return M
