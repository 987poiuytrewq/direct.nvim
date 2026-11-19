-- direct.git_restore -- preserves and restores unstaged tracked worktree changes.
local M = {}

local buffer = require('direct.buffer.buffer')
local events = require('direct.events')
local fs = require('direct.fs')
local git_status = require('direct.git')
local paths = require('direct.paths')
local run = require('direct.run')
local trash = require('direct.trash')
local ui = require('direct.ui')

local function worktree_backups(changes)
  local directory, directory_err = paths.ensure_data_dir('trash')
  if not directory then return nil, directory_err end
  local backups = {}
  for _, path in ipairs(changes) do
    local stat = vim.uv.fs_lstat(path)
    if stat then
      local backup_path = trash.first_free(directory, path)
      local copied, copy_err
      if stat.type == 'file' then
        copied, copy_err = fs.copy_file_exclusive(path, backup_path)
      elseif stat.type == 'link' then
        local target, read_err = vim.uv.fs_readlink(path)
        if not target then return nil, 'could not read symlink ' .. path .. ': ' .. tostring(read_err), backups end
        copied, copy_err = vim.uv.fs_symlink(target, backup_path)
      elseif stat.type == 'directory' then
        copied, copy_err = fs.copy_tree_exclusive(path, backup_path, {
          require_complete = true,
          recreate_symlinks = true,
          verify_source = true,
        })
      else
        return nil, 'cannot back up unsupported worktree entry: ' .. path, backups
      end
      if not copied then return nil, 'could not back up ' .. path .. ': ' .. tostring(copy_err), backups end
      backups[#backups + 1] = {
        id = fs.basename(backup_path),
        path = backup_path,
        original = path,
      }
      local metadata, metadata_err = trash.write_metadata(backup_path, path, 'git-restore-backup')
      if not metadata then
        return nil, 'backup exists at ' .. backup_path .. ' but metadata failed: ' .. tostring(metadata_err), backups
      end
    end
  end
  return backups
end

local function backup_list(backups)
  local result = {}
  for _, backup in ipairs(backups or {}) do
    result[#result + 1] = backup.id .. ' (' .. backup.original .. ')'
  end
  return table.concat(result, ', ')
end

function M.restore()
  local listing = buffer.restore()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local target, path_err = listing:get_entry_path(row)
  local record = listing:get_entry_record(row)
  if not target then
    ui.notify('direct: cannot restore Git changes: ' .. tostring(path_err), vim.log.levels.ERROR)
    return nil, path_err
  end

  local is_directory = record and paths.is_directory_name(record.name) or false
  local changes, status_err = git_status.worktree_changes(listing.root, target, is_directory)
  if not changes then
    ui.notify('direct: cannot inspect Git changes: ' .. tostring(status_err), vim.log.levels.ERROR)
    return nil, status_err
  end
  if #changes == 0 then
    ui.notify('direct: no tracked worktree changes to restore at ' .. target, vim.log.levels.INFO)
    return false
  end

  local count_text = #changes == 1 and '1 changed file' or (#changes .. ' changed files')
  local prompt = string.format(
    'Restore the worktree state of %s?\n' .. 'This will discard unstaged changes to %s.',
    target,
    count_text
  )
  if vim.fn.confirm(prompt, '&Restore\n&Cancel', 2) ~= 1 then return nil end

  local confirmed_changes, recheck_err = git_status.worktree_changes(listing.root, target, is_directory)
  if not confirmed_changes then
    ui.notify('direct: cannot recheck Git changes: ' .. tostring(recheck_err), vim.log.levels.ERROR)
    return nil, recheck_err
  end
  if not vim.deep_equal(changes, confirmed_changes) then
    local reason = 'Git worktree changes changed while awaiting confirmation; nothing was restored'
    ui.notify('direct: ' .. reason, vim.log.levels.WARN)
    return nil, reason
  end

  local restore_command, command_err = git_status.worktree_restore_command(listing.root)
  if not restore_command then
    ui.notify('direct: cannot prepare Git restore: ' .. tostring(command_err), vim.log.levels.ERROR)
    return nil, command_err
  end

  local backups, backup_err, partial_backups = worktree_backups(changes)
  if not backups then
    local reason = 'cannot back up Git worktree changes: ' .. tostring(backup_err)
    if partial_backups and #partial_backups > 0 then
      reason = reason .. '; copies already saved in trash: ' .. backup_list(partial_backups)
    end
    ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
    return nil, reason
  end
  if #backups > 0 then
    ui.notify(
      'direct: pre-restore worktree copies saved in trash: '
        .. backup_list(backups)
        .. '; restore them manually if needed',
      vim.log.levels.WARN
    )
  end

  buffer.cancel_git_status()
  local process, run_err = run.current_entry(restore_command, function(result, bufnr, root)
    buffer.refresh_git_status(bufnr, root)
    local success = result.code == 0
    local restore_err
    if not success then
      local stderr = type(result.stderr) == 'string' and result.stderr or ''
      restore_err = stderr ~= '' and stderr or ('Git restore exited with status ' .. tostring(result.code))
    end
    events.emit('DirectGitRestorePost', {
      root = root,
      target = target,
      changes = changes,
      backups = backups,
      success = success,
      error = restore_err,
    })
  end, { quiet_success = true })
  if not process then
    events.emit('DirectGitRestorePost', {
      root = listing.root,
      target = target,
      changes = changes,
      backups = backups,
      success = false,
      error = run_err,
    })
  end
  return process, run_err
end

return M
