local sync = require('tests.support.sync_helpers').new()
local H = sync.H
local history_lines = sync.history_lines
local clean_buffers = sync.clean_buffers

local function row_of(lines, name)
  for row, line in ipairs(lines) do
    if line == name then return row end
  end
end

local function buffer_lines(bufnr) return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) end

local function close_current_float()
  local winid = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(winid).relative ~= '' then vim.api.nvim_win_close(winid, true) end
end

local function run_preview(root, listing_win)
  vim.api.nvim_set_current_win(listing_win)
  local old_cwd = vim.fn.getcwd()
  vim.cmd('lcd ' .. vim.fn.fnameescape(root))
  local called, preview = xpcall(function()
    vim.cmd('DirectPlan')
    return table.concat(buffer_lines(vim.api.nvim_get_current_buf()), '\n')
  end, debug.traceback)
  close_current_float()
  vim.api.nvim_set_current_win(listing_win)
  vim.cmd('lcd ' .. vim.fn.fnameescape(old_cwd))
  if not called then error(preview, 0) end
  return preview
end

H.describe(':DirectPlan preview', function()
  H.it('shows mixed actions without changing the listing, disk, or history', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'a' })
    H.mkfile(ws, 'remove.txt', { 'remove' })
    H.mkfile(ws, 'z-anchor.txt', { 'anchor' })
    require('direct').list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    local listing_win = vim.api.nvim_get_current_win()

    local lines = buffer_lines(bufnr)
    local alpha_row = row_of(lines, 'a.txt')
    local remove_row = row_of(lines, 'remove.txt')
    vim.api.nvim_buf_set_text(bufnr, alpha_row - 1, 0, alpha_row - 1, #'a.txt', { 'renamed.txt' })
    vim.api.nvim_buf_set_lines(bufnr, remove_row - 1, remove_row, false, {})
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { 'created.txt' })

    local before_lines = buffer_lines(bufnr)
    local before_modified = vim.bo[bufnr].modified
    local before_cursor = vim.api.nvim_win_get_cursor(listing_win)
    local before_files = H.fs_snapshot(ws)
    local before_undo = history_lines('undo.log')
    local before_redo = history_lines('redo.log')
    local pre_calls = 0
    local events_group = vim.api.nvim_create_augroup('direct_plan_preview_spec', { clear = true })
    vim.api.nvim_create_autocmd('User', {
      group = events_group,
      pattern = 'DirectSyncPre',
      callback = function() pre_calls = pre_calls + 1 end,
    })

    local preview = run_preview(ws, listing_win)
    H.assert_true(preview:find('Moved a.txt to renamed.txt', 1, true) ~= nil, preview)
    H.assert_true(preview:find('Removed remove.txt', 1, true) ~= nil, preview)
    H.assert_true(preview:find('Created created.txt', 1, true) ~= nil, preview)
    H.assert_true(preview:find('Preview only; no filesystem or history changes have been made.', 1, true) ~= nil)
    H.assert_eq(buffer_lines(bufnr), before_lines, 'the Direct listing text is unchanged')
    H.assert_eq(vim.bo[bufnr].modified, before_modified, 'the modified flag is unchanged')
    H.assert_eq(vim.api.nvim_win_get_cursor(listing_win), before_cursor, 'the listing cursor is unchanged')
    H.assert_eq(H.fs_snapshot(ws), before_files, 'the filesystem is unchanged')
    H.assert_eq(history_lines('undo.log'), before_undo, 'undo history is unchanged')
    H.assert_eq(history_lines('redo.log'), before_redo, 'redo history is unchanged')
    H.assert_eq(pre_calls, 0, 'preview does not emit the save event')

    vim.api.nvim_del_augroup_by_id(events_group)
    H.with_cwd(ws, function() vim.cmd('write') end)
    H.assert_fs_eq(ws, { 'created.txt', 'renamed.txt', 'z-anchor.txt' }, ':write still applies the pending edit')
  end)

  H.it('shows the refusal instead of changing the listing or disk', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'safe.txt', { 'safe' })
    require('direct').list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '../outside' })
    local before_lines = buffer_lines(bufnr)
    local before_modified = vim.bo[bufnr].modified
    local before_files = H.fs_snapshot(ws)
    local before_undo = history_lines('undo.log')
    local before_redo = history_lines('redo.log')

    local preview = run_preview(ws, vim.api.nvim_get_current_win())
    H.assert_true(preview:find('E-DIRECT-ROW-UNSAFE', 1, true) ~= nil, preview)
    H.assert_true(preview:find('Line 1:', 1, true) ~= nil, 'the refusal preserves row provenance')
    H.assert_eq(buffer_lines(bufnr), before_lines, 'the listing text is unchanged')
    H.assert_eq(vim.bo[bufnr].modified, before_modified, 'the modified flag is unchanged')
    H.assert_eq(H.fs_snapshot(ws), before_files, 'the filesystem is unchanged')
    H.assert_eq(history_lines('undo.log'), before_undo, 'undo history is unchanged')
    H.assert_eq(history_lines('redo.log'), before_redo, 'redo history is unchanged')
    H.assert_eq(
      #vim.diagnostic.get(bufnr, { namespace = require('direct.buffer.sync_refusals').namespace }),
      0,
      'preview does not set a row diagnostic'
    )
  end)

  H.it('keeps plan unbound by default and accepts an explicit mapping', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'entry.txt', { 'entry' })
    require('direct.config').setup({ map_default_keys = true })
    require('direct').list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    local has_default = false
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, 'n')) do
      if type(mapping.rhs) == 'string' and mapping.rhs:find('DirectPlan', 1, true) then has_default = true end
    end
    H.assert_false(has_default, 'DirectPlan has no default physical key')

    require('direct.config').setup({ map_default_keys = true, mappings = { plan = 'gP' } })
    local has_custom = false
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, 'n')) do
      if mapping.lhs == 'gP' and type(mapping.rhs) == 'string' and mapping.rhs:find('DirectPlan', 1, true) then
        has_custom = true
      end
    end
    H.assert_true(has_custom, 'the plan action can be bound through mappings')
  end)
end)
