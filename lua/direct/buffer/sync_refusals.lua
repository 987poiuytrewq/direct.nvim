-- Stable codes, user-facing messages, and row diagnostics for refused saves.
local M = {}

local ui = require('direct.ui')

M.namespace = vim.api.nvim_create_namespace('direct.sync-refusals')
M.help_topic = 'direct-refusals'

local definitions = {
  ['E-DIRECT-SYNC-BUSY'] = {
    summary = 'Another Direct operation is still running.',
    remedy = 'Wait for it to finish, then save again.',
    rowless = true,
  },
  ['E-DIRECT-SYNC-FILTER-SNAPSHOT'] = {
    summary = 'The saved visibility settings for this listing are unavailable or changed.',
    remedy = 'Re-list the directory and review the edits before saving again.',
    rowless = true,
  },
  ['E-DIRECT-SYNC-GIT'] = {
    summary = 'Git could not verify the ignore rules for this listing.',
    remedy = 'Re-list after changing ignore rules; otherwise retry when Git is available '
      .. 'or use gi to disable filtering.',
    rowless = true,
  },
  ['E-DIRECT-SYNC-GIT-IGNORED'] = {
    summary = 'This save would change an entry that Git ignores.',
    remedy = 'Re-list the directory or disable Git-ignore filtering before saving.',
  },
  ['E-DIRECT-SYNC-DIRECTORY-READ'] = {
    summary = 'Direct could not safely read the directory contents.',
    remedy = 'Check the directory and permissions, then re-list before saving.',
    rowless = true,
  },
  ['E-DIRECT-SYNC-COLLAPSED-VIEW'] = {
    summary = 'The collapsed-folder view could not be checked safely.',
    remedy = 'Re-list the directory and try the edit again.',
    rowless = true,
  },
  ['E-DIRECT-SYNC-HISTORY'] = {
    summary = 'Direct could not verify the undo history before saving.',
    remedy = 'Resolve the history or lock problem, then try again.',
    rowless = true,
  },
  ['E-DIRECT-SYNC-PLAN-STALE'] = {
    summary = 'The save plan changed while Direct was waiting for a workspace rename response.',
    remedy = 'Review the listing and save again.',
    rowless = true,
  },
  ['E-DIRECT-SYNC-CANCELLED'] = {
    summary = 'The save was cancelled before Direct changed any files.',
    remedy = 'Review the cancellation reason and save again when ready.',
    rowless = true,
  },
  ['E-DIRECT-SYNC-LISTING-CHANGED'] = {
    summary = 'The listing changed while Direct was checking the save.',
    remedy = 'Review the edits and save again.',
    rowless = true,
  },
  ['E-DIRECT-SYNC-UNCLASSIFIED'] = {
    summary = 'Direct stopped at a save safety check it could not classify.',
    remedy = 'Re-list the directory and report this code if the refusal continues.',
    rowless = true,
  },
  ['E-DIRECT-ROW-IDENTITY'] = {
    summary = 'Direct could not identify this listing row safely.',
    remedy = 'Undo the ambiguous row edit and make it again with a normal filename change, '
      .. 'or use :DirectList! to discard all listing edits.',
  },
  ['E-DIRECT-ROW-AMBIGUOUS'] = {
    summary = 'Ambiguous buffer content: Direct cannot tell which entry this row represents.',
    remedy = 'Edit one entry at a time, or use :DirectList! to discard the edits and start again.',
  },
  ['E-DIRECT-ROW-STALE'] = {
    summary = 'This entry changed on disk after it was listed.',
    remedy = 'Restore the entry or use :DirectList! to discard the edits, then try again.',
  },
  ['E-DIRECT-ROW-UNSAFE'] = {
    summary = 'Unsafe entry: this name or path component is not supported.',
    remedy = 'Choose a valid single-component name and save again.',
  },
  ['E-DIRECT-ROW-CONFLICT'] = {
    summary = 'These entries conflict because they target the same path.',
    remedy = 'Choose distinct names or remove the conflicting row.',
  },
  ['E-DIRECT-TREE-IDENTITY'] = {
    summary = 'Direct could not verify the identity of an expanded-folder entry.',
    remedy = 'Restore the original row structure, or use :DirectList! to discard the edits and start again.',
  },
  ['E-DIRECT-TREE-BASELINE'] = {
    summary = 'An expanded-folder row no longer matches the folder listing Direct captured.',
    remedy = 'Restore that row or re-list the directory before editing it again.',
  },
  ['E-DIRECT-TREE-STRUCTURE'] = {
    summary = 'The expanded-folder rows do not form a valid directory tree.',
    remedy = 'Restore the parent and child row order, then save again.',
  },
  ['E-DIRECT-TREE-INDENT'] = {
    summary = 'This child row has invalid indentation.',
    remedy = 'Indent child rows by the configured number of spaces for each folder level.',
  },
  ['E-DIRECT-TREE-EMPTY'] = {
    summary = 'A child row has no entry name.',
    remedy = 'Restore the entry name or remove the empty row.',
  },
  ['E-DIRECT-TREE-PARENT'] = {
    summary = 'This child row has no valid parent directory.',
    remedy = 'Restore its parent folder row and nesting, then save again.',
  },
  ['E-DIRECT-TREE-COLLAPSED'] = {
    summary = 'Child rows under a collapsed directory cannot be edited.',
    remedy = 'Expand the directory before editing its contents.',
  },
  ['E-DIRECT-TREE-DUPLICATE'] = {
    summary = 'This folder would contain duplicate entry names.',
    remedy = 'Give each entry in the folder a unique name.',
  },
  ['E-DIRECT-TREE-AMBIGUOUS'] = {
    summary = 'Direct cannot pair these child rows with their original entries.',
    remedy = 'Restore the marked rows or make the rename and create/delete edits separately.',
  },
  ['E-DIRECT-TREE-TYPE'] = {
    summary = 'An expanded directory cannot be changed into a different entry type.',
    remedy = 'Undo the type change or collapse the directory before changing it.',
  },
  ['E-DIRECT-TREE-DESTINATION'] = {
    summary = 'Direct could not determine the destination folder for this child row.',
    remedy = 'Restore a valid parent directory row and save again.',
  },
  ['E-DIRECT-TREE-LIMITATION'] = {
    summary = 'This folder move cannot be combined safely with edits to its descendants.',
    remedy = 'Move the folder first, then edit its descendants in a separate save.',
  },
  ['E-DIRECT-PATH-PARENT'] = {
    summary = 'The parent path for this entry is not a directory.',
    remedy = 'Choose a valid parent folder and save again.',
  },
  ['E-DIRECT-PATH-OCCUPIED'] = {
    summary = 'The destination already exists.',
    remedy = 'Choose another name or use :DirectList! to discard the edit and start again.',
  },
  ['E-DIRECT-PATH-CONFLICT'] = {
    summary = 'Multiple save actions target the same path.',
    remedy = 'Choose distinct destinations and save again.',
  },
  ['E-DIRECT-DIRECTORY-HIDDEN'] = {
    summary = 'This directory contains a hidden or ignored entry that would be affected.',
    remedy = 'Show or preserve that entry, or change the filters before moving or deleting the directory.',
    rowless = true,
  },
}

local exact_reasons = {
  ['list-time filter snapshot is unavailable; re-list this directory'] = 'E-DIRECT-SYNC-FILTER-SNAPSHOT',
  ['Git ignore query failed'] = 'E-DIRECT-SYNC-GIT',
  ['redone child materialization could not be uniquely restored'] = 'E-DIRECT-TREE-IDENTITY',
  ['child identity marks are invalid or duplicated'] = 'E-DIRECT-TREE-IDENTITY',
  ['child identity marks were lost outside an undo to their materialization baseline'] = 'E-DIRECT-TREE-IDENTITY',
  ['child rows cannot be uniquely associated with their root identity'] = 'E-DIRECT-TREE-IDENTITY',
  ['child materialization baseline is inconsistent'] = 'E-DIRECT-TREE-BASELINE',
  ['child row text differs from its materialization baseline'] = 'E-DIRECT-TREE-BASELINE',
  ['child order no longer follows its owning root row'] = 'E-DIRECT-TREE-STRUCTURE',
  ['child row identity moved from its materialization baseline'] = 'E-DIRECT-TREE-STRUCTURE',
  ['child rows were added, deleted, reordered, or lost identity'] = 'E-DIRECT-TREE-IDENTITY',
  ['child order no longer follows its parent'] = 'E-DIRECT-TREE-STRUCTURE',
  ['unidentified child row is present'] = 'E-DIRECT-TREE-IDENTITY',
  ['child row count differs from its materialization baseline'] = 'E-DIRECT-TREE-BASELINE',
  ['child identity marks could not be restored safely'] = 'E-DIRECT-TREE-IDENTITY',
  ['child identity was replaced outside its original directory row'] = 'E-DIRECT-TREE-IDENTITY',
  ['child identity was replaced at a different tree depth'] = 'E-DIRECT-TREE-STRUCTURE',
  ['child identity was lost while a root row was added'] = 'E-DIRECT-TREE-IDENTITY',
  ['child identity state is unavailable'] = 'E-DIRECT-TREE-IDENTITY',
  ['child identity mark was lost'] = 'E-DIRECT-TREE-IDENTITY',
  ['a child row skips a directory level'] = 'E-DIRECT-TREE-STRUCTURE',
  ['empty child row'] = 'E-DIRECT-TREE-EMPTY',
  ['child row has no parent directory'] = 'E-DIRECT-TREE-PARENT',
  ['child row parent is not a directory'] = 'E-DIRECT-TREE-PARENT',
  ['cannot edit child rows under a collapsed directory'] = 'E-DIRECT-TREE-COLLAPSED',
  ['reordered child identities cannot be safely paired with line replacements'] = 'E-DIRECT-TREE-AMBIGUOUS',
  ['child row identities are ambiguous between rename and create/delete'] = 'E-DIRECT-TREE-AMBIGUOUS',
  ['cannot change the type of an expanded directory'] = 'E-DIRECT-TREE-TYPE',
  ['edit moved directories and their descendants in separate syncs'] = 'E-DIRECT-TREE-LIMITATION',
  ['edit a moved directory and its new children in separate syncs'] = 'E-DIRECT-TREE-LIMITATION',
  ['edit a moved directory and its removed children in separate syncs'] = 'E-DIRECT-TREE-LIMITATION',
  ['root row identities are invalid or duplicated'] = 'E-DIRECT-ROW-IDENTITY',
  ['directory changed on disk since it was listed'] = 'E-DIRECT-ROW-STALE',
  ['root row paths are ambiguous'] = 'E-DIRECT-ROW-AMBIGUOUS',
  ['root row identity is unavailable'] = 'E-DIRECT-ROW-IDENTITY',
  ['root row identity is ambiguous'] = 'E-DIRECT-ROW-AMBIGUOUS',
  ['root names may not begin with whitespace'] = 'E-DIRECT-ROW-UNSAFE',
  ['root row identity is unavailable after text undo or redo'] = 'E-DIRECT-ROW-IDENTITY',
  ['root row identity is unavailable; re-list this directory'] = 'E-DIRECT-ROW-IDENTITY',
  ['invalid path'] = 'E-DIRECT-ROW-UNSAFE',
  ['invalid component'] = 'E-DIRECT-ROW-UNSAFE',
  ['invalid path component'] = 'E-DIRECT-ROW-UNSAFE',
  ['contains a tab'] = 'E-DIRECT-ROW-UNSAFE',
  ['contains NUL'] = 'E-DIRECT-ROW-UNSAFE',
  ['contains a control character'] = 'E-DIRECT-ROW-UNSAFE',
  ['invalid UTF-8'] = 'E-DIRECT-ROW-UNSAFE',
  ['not a basename component'] = 'E-DIRECT-ROW-UNSAFE',
  ['invalid Windows path component'] = 'E-DIRECT-ROW-UNSAFE',
  ['Windows path components may not end in a dot or space'] = 'E-DIRECT-ROW-UNSAFE',
  ['reserved Windows device name'] = 'E-DIRECT-ROW-UNSAFE',
  ['empty'] = 'E-DIRECT-ROW-UNSAFE',
  ['empty path component'] = 'E-DIRECT-ROW-UNSAFE',
  ['path contains a parent traversal component'] = 'E-DIRECT-ROW-UNSAFE',
  ['path is outside the listing root'] = 'E-DIRECT-ROW-UNSAFE',
  ['root row identity is invalid or duplicated'] = 'E-DIRECT-ROW-IDENTITY',
}

local prefix_reasons = {
  { prefix = 'Git-ignore filtering timed out', code = 'E-DIRECT-SYNC-GIT' },
  { prefix = 'Git ignore query failed:', code = 'E-DIRECT-SYNC-GIT' },
  { prefix = 'Git ignore snapshot changed', code = 'E-DIRECT-SYNC-GIT' },
  { prefix = 'an entry changed by this save is Git-ignored:', code = 'E-DIRECT-SYNC-GIT-IGNORED' },
  { prefix = 'directory changed on disk since it was listed:', code = 'E-DIRECT-ROW-STALE' },
  { prefix = 'expanded directory entry changed on disk since it was read:', code = 'E-DIRECT-ROW-STALE' },
  { prefix = 'destination already exists:', code = 'E-DIRECT-PATH-OCCUPIED' },
  { prefix = 'move destination already exists:', code = 'E-DIRECT-PATH-OCCUPIED' },
  { prefix = 'path parent is not a directory:', code = 'E-DIRECT-PATH-PARENT' },
  { prefix = 'conflicting entries target the same path:', code = 'E-DIRECT-PATH-CONFLICT' },
  { prefix = 'multiple subtree actions target the same path:', code = 'E-DIRECT-PATH-CONFLICT' },
  { prefix = 'Unsafe entry', code = 'E-DIRECT-ROW-UNSAFE' },
  { prefix = 'Unsafe action', code = 'E-DIRECT-ROW-UNSAFE' },
  { prefix = 'cannot inspect collapsed parent directory:', code = 'E-DIRECT-SYNC-DIRECTORY-READ' },
  { prefix = 'cannot inspect directory descendants:', code = 'E-DIRECT-SYNC-DIRECTORY-READ' },
  { prefix = 'directory contains hidden entry:', code = 'E-DIRECT-DIRECTORY-HIDDEN' },
  { prefix = 'collapsed paths must keep the same path components', code = 'E-DIRECT-ROW-UNSAFE' },
  { prefix = 'duplicate child entry:', code = 'E-DIRECT-TREE-DUPLICATE' },
  { prefix = 'child row indentation must use groups of ', code = 'E-DIRECT-TREE-INDENT' },
  { prefix = 'child row has no destination directory', code = 'E-DIRECT-TREE-DESTINATION' },
  { prefix = 'could not validate collapsed directory view:', code = 'E-DIRECT-SYNC-COLLAPSED-VIEW' },
  { prefix = 'history preflight failed:', code = 'E-DIRECT-SYNC-HISTORY' },
  { prefix = 'sync plan changed while waiting for LSP willRenameFiles', code = 'E-DIRECT-SYNC-PLAN-STALE' },
  { prefix = 'DirectSyncPre cancelled the save', code = 'E-DIRECT-SYNC-CANCELLED' },
  { prefix = 'listing changed during DirectSyncPre', code = 'E-DIRECT-SYNC-LISTING-CHANGED' },
  { prefix = 'root row identity is unavailable after text undo or redo;', code = 'E-DIRECT-ROW-IDENTITY' },
  { prefix = 'could not read ', code = 'E-DIRECT-SYNC-DIRECTORY-READ' },
  { prefix = 'cannot read', code = 'E-DIRECT-SYNC-DIRECTORY-READ' },
}

local clear_groups = {}

local function clear_diagnostics(bufnr)
  local group = clear_groups[bufnr]
  clear_groups[bufnr] = nil
  if group then pcall(vim.api.nvim_del_augroup_by_id, group) end
  if vim.api.nvim_buf_is_valid(bufnr) then pcall(vim.diagnostic.reset, M.namespace, bufnr) end
end

local function clear_on_next_change(bufnr)
  if clear_groups[bufnr] then return end
  local group = vim.api.nvim_create_augroup('direct.sync-refusal.' .. bufnr, { clear = true })
  clear_groups[bufnr] = group
  local function clear() clear_diagnostics(bufnr) end
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, { group = group, buffer = bufnr, callback = clear })
  vim.api.nvim_create_autocmd('BufWipeout', { group = group, buffer = bufnr, callback = clear })
end

function M.codes()
  local codes = {}
  for code in pairs(definitions) do
    codes[#codes + 1] = code
  end
  table.sort(codes)
  return codes
end

function M.definition(code)
  local definition = definitions[code]
  if not definition then return nil end
  return vim.tbl_extend('force', { code = code, help = M.help_topic }, definition)
end

function M.code_for_reason(reason)
  if exact_reasons[reason] then return exact_reasons[reason] end
  if type(reason) == 'string' then
    for _, rule in ipairs(prefix_reasons) do
      if reason:sub(1, #rule.prefix) == rule.prefix then return rule.code end
    end
  end
  return 'E-DIRECT-SYNC-UNCLASSIFIED'
end

function M.format(code, context)
  context = context or {}
  local definition = assert(definitions[code], 'unknown direct sync refusal code: ' .. tostring(code))
  local parts = { code .. ': ' }
  if not definition.rowless and type(context.line) == 'number' then
    parts[#parts + 1] = 'Line ' .. (context.line + 1) .. ': '
  end
  parts[#parts + 1] = definition.summary
  if type(context.path) == 'string' and context.path ~= '' then
    parts[#parts + 1] = ' Entry: ' .. context.path .. '.'
  end
  if type(context.detail) == 'string' and context.detail ~= '' then parts[#parts + 1] = ' ' .. context.detail end
  if definition.remedy ~= '' then parts[#parts + 1] = ' ' .. definition.remedy end
  return table.concat(parts)
end

function M.report(bufnr, code, context, level)
  context = context or {}
  local definition = assert(definitions[code], 'unknown direct sync refusal code: ' .. tostring(code))
  local message = M.format(code, context)
  local line = not definition.rowless and context.line or nil
  if
    type(line) == 'number'
    and line >= 0
    and line % 1 == 0
    and vim.api.nvim_buf_is_valid(bufnr)
    and line < vim.api.nvim_buf_line_count(bufnr)
  then
    clear_diagnostics(bufnr)
    vim.diagnostic.set(M.namespace, bufnr, {
      {
        lnum = line,
        col = context.col or 0,
        severity = vim.diagnostic.severity.ERROR,
        message = message,
        source = 'direct',
        code = code,
      },
    })
    clear_on_next_change(bufnr)
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(winid) == bufnr then
        pcall(vim.api.nvim_win_set_cursor, winid, { line + 1, context.col or 0 })
        break
      end
    end
  end
  ui.notify(message, level or vim.log.levels.ERROR)
  return message, definition
end

return M
