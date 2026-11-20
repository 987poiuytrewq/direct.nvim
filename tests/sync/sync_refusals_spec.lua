local sync = require('tests.support.sync_helpers').new()
local H = sync.H
local buffer = sync.buffer
local history = sync.history
local clean_buffers = sync.clean_buffers
local refusals = require('direct.buffer.sync_refusals')

-- One fixture per distinct planner/tree reason plus representative dynamic
-- prefixes. Update this inventory alongside any new refusal site.
local reason_cases = {
  { 'list-time filter snapshot is unavailable; re-list this directory', 'E-DIRECT-SYNC-FILTER-SNAPSHOT' },
  { 'Git ignore query failed: EIO', 'E-DIRECT-SYNC-GIT' },
  { 'Git-ignore filtering timed out after 40 ms', 'E-DIRECT-SYNC-GIT' },
  { 'Git ignore snapshot changed after listing', 'E-DIRECT-SYNC-GIT' },
  { 'an entry changed by this save is Git-ignored: /work/ignored', 'E-DIRECT-SYNC-GIT-IGNORED' },
  { 'redone child materialization could not be uniquely restored', 'E-DIRECT-TREE-IDENTITY' },
  { 'child identity marks are invalid or duplicated', 'E-DIRECT-TREE-IDENTITY' },
  { 'child identity marks were lost outside an undo to their materialization baseline', 'E-DIRECT-TREE-IDENTITY' },
  { 'child rows cannot be uniquely associated with their root identity', 'E-DIRECT-TREE-IDENTITY' },
  { 'child materialization baseline is inconsistent', 'E-DIRECT-TREE-BASELINE' },
  { 'child row text differs from its materialization baseline', 'E-DIRECT-TREE-BASELINE' },
  { 'child order no longer follows its owning root row', 'E-DIRECT-TREE-STRUCTURE' },
  { 'child row identity moved from its materialization baseline', 'E-DIRECT-TREE-STRUCTURE' },
  { 'child rows were added, deleted, reordered, or lost identity', 'E-DIRECT-TREE-IDENTITY' },
  { 'child order no longer follows its parent', 'E-DIRECT-TREE-STRUCTURE' },
  { 'unidentified child row is present', 'E-DIRECT-TREE-IDENTITY' },
  { 'child row count differs from its materialization baseline', 'E-DIRECT-TREE-BASELINE' },
  { 'child identity marks could not be restored safely', 'E-DIRECT-TREE-IDENTITY' },
  { 'child identity was replaced outside its original directory row', 'E-DIRECT-TREE-IDENTITY' },
  { 'child identity was replaced at a different tree depth', 'E-DIRECT-TREE-STRUCTURE' },
  { 'child identity was lost while a root row was added', 'E-DIRECT-TREE-IDENTITY' },
  { 'child identity state is unavailable', 'E-DIRECT-TREE-IDENTITY' },
  { 'child identity mark was lost', 'E-DIRECT-TREE-IDENTITY' },
  { 'a child row skips a directory level', 'E-DIRECT-TREE-STRUCTURE' },
  { 'empty child row', 'E-DIRECT-TREE-EMPTY' },
  { 'child row has no parent directory', 'E-DIRECT-TREE-PARENT' },
  { 'child row parent is not a directory', 'E-DIRECT-TREE-PARENT' },
  { 'cannot edit child rows under a collapsed directory', 'E-DIRECT-TREE-COLLAPSED' },
  { 'reordered child identities cannot be safely paired with line replacements', 'E-DIRECT-TREE-AMBIGUOUS' },
  { 'child row identities are ambiguous between rename and create/delete', 'E-DIRECT-TREE-AMBIGUOUS' },
  { 'cannot change the type of an expanded directory', 'E-DIRECT-TREE-TYPE' },
  { 'edit moved directories and their descendants in separate syncs', 'E-DIRECT-TREE-LIMITATION' },
  { 'edit a moved directory and its new children in separate syncs', 'E-DIRECT-TREE-LIMITATION' },
  { 'edit a moved directory and its removed children in separate syncs', 'E-DIRECT-TREE-LIMITATION' },
  { 'child row indentation must use groups of 2 spaces', 'E-DIRECT-TREE-INDENT' },
  { 'duplicate child entry: same.txt', 'E-DIRECT-TREE-DUPLICATE' },
  { 'child row has no destination directory', 'E-DIRECT-TREE-DESTINATION' },
  { 'expanded directory entry changed on disk since it was read: /work/child', 'E-DIRECT-ROW-STALE' },
  { 'path parent is not a directory: /work/file', 'E-DIRECT-PATH-PARENT' },
  { 'destination already exists: /work/target', 'E-DIRECT-PATH-OCCUPIED' },
  { 'move destination already exists: /work/target', 'E-DIRECT-PATH-OCCUPIED' },
  { 'root row identities are invalid or duplicated', 'E-DIRECT-ROW-IDENTITY' },
  { 'directory changed on disk since it was listed', 'E-DIRECT-ROW-STALE' },
  { 'directory changed on disk since it was listed: /work/source', 'E-DIRECT-ROW-STALE' },
  { 'root row paths are ambiguous', 'E-DIRECT-ROW-AMBIGUOUS' },
  { 'root row identity is unavailable', 'E-DIRECT-ROW-IDENTITY' },
  { 'root row identity is unavailable; re-list this directory', 'E-DIRECT-ROW-IDENTITY' },
  { 'root row identity is unavailable after text undo or redo', 'E-DIRECT-ROW-IDENTITY' },
  { 'root row identity is unavailable after text undo or redo; restore the marked row', 'E-DIRECT-ROW-IDENTITY' },
  { 'root row identity is ambiguous', 'E-DIRECT-ROW-AMBIGUOUS' },
  { 'root names may not begin with whitespace', 'E-DIRECT-ROW-UNSAFE' },
  { 'invalid path', 'E-DIRECT-ROW-UNSAFE' },
  { 'invalid component', 'E-DIRECT-ROW-UNSAFE' },
  { 'invalid path component', 'E-DIRECT-ROW-UNSAFE' },
  { 'contains a tab', 'E-DIRECT-ROW-UNSAFE' },
  { 'contains NUL', 'E-DIRECT-ROW-UNSAFE' },
  { 'contains a control character', 'E-DIRECT-ROW-UNSAFE' },
  { 'invalid UTF-8', 'E-DIRECT-ROW-UNSAFE' },
  { 'not a basename component', 'E-DIRECT-ROW-UNSAFE' },
  { 'empty', 'E-DIRECT-ROW-UNSAFE' },
  { 'empty path component', 'E-DIRECT-ROW-UNSAFE' },
  { 'path contains a parent traversal component', 'E-DIRECT-ROW-UNSAFE' },
  { 'path is outside the listing root', 'E-DIRECT-ROW-UNSAFE' },
  { 'invalid Windows path component', 'E-DIRECT-ROW-UNSAFE' },
  { 'Windows path components may not end in a dot or space', 'E-DIRECT-ROW-UNSAFE' },
  { 'reserved Windows device name', 'E-DIRECT-ROW-UNSAFE' },
  { 'collapsed paths must keep the same path components', 'E-DIRECT-ROW-UNSAFE' },
  { 'collapsed paths must keep the same path components and entry type', 'E-DIRECT-ROW-UNSAFE' },
  { 'conflicting entries target the same path: /work/a', 'E-DIRECT-PATH-CONFLICT' },
  { 'multiple subtree actions target the same path: /work/a', 'E-DIRECT-PATH-CONFLICT' },
  { 'Unsafe entry (contains a tab)', 'E-DIRECT-ROW-UNSAFE' },
  { 'Unsafe action (contains a tab)', 'E-DIRECT-ROW-UNSAFE' },
  { 'cannot inspect collapsed parent directory: /work/parent: EACCES', 'E-DIRECT-SYNC-DIRECTORY-READ' },
  { 'cannot inspect directory descendants: EACCES', 'E-DIRECT-SYNC-DIRECTORY-READ' },
  { 'directory contains hidden entry: /work/hidden', 'E-DIRECT-DIRECTORY-HIDDEN' },
  { 'could not validate collapsed directory view: changed', 'E-DIRECT-SYNC-COLLAPSED-VIEW' },
  { 'history preflight failed: busy', 'E-DIRECT-SYNC-HISTORY' },
  {
    'sync plan changed while waiting for LSP willRenameFiles; review and save again',
    'E-DIRECT-SYNC-PLAN-STALE',
  },
  { 'DirectSyncPre cancelled the save', 'E-DIRECT-SYNC-CANCELLED' },
  { 'listing changed during DirectSyncPre; review and save again', 'E-DIRECT-SYNC-LISTING-CHANGED' },
  { 'could not read /work: EACCES', 'E-DIRECT-SYNC-DIRECTORY-READ' },
  { 'cannot read /work: EACCES', 'E-DIRECT-SYNC-DIRECTORY-READ' },
}

H.describe('sync refusal diagnostics', function()
  H.it('defines a stable message and direct-refusals help target for every code', function()
    local expected_summaries = {
      ['E-DIRECT-SYNC-BUSY'] = 'Another Direct operation is still running.',
      ['E-DIRECT-SYNC-FILTER-SNAPSHOT'] = 'The saved visibility settings for this listing are unavailable or changed.',
      ['E-DIRECT-SYNC-GIT'] = 'Git could not verify the ignore rules for this listing.',
      ['E-DIRECT-SYNC-GIT-IGNORED'] = 'This save would change an entry that Git ignores.',
      ['E-DIRECT-SYNC-DIRECTORY-READ'] = 'Direct could not safely read the directory contents.',
      ['E-DIRECT-SYNC-COLLAPSED-VIEW'] = 'The collapsed-folder view could not be checked safely.',
      ['E-DIRECT-SYNC-HISTORY'] = 'Direct could not verify the undo history before saving.',
      ['E-DIRECT-SYNC-PLAN-STALE'] = 'The save plan changed while Direct was waiting for a workspace rename response.',
      ['E-DIRECT-SYNC-CANCELLED'] = 'The save was cancelled before Direct changed any files.',
      ['E-DIRECT-SYNC-LISTING-CHANGED'] = 'The listing changed while Direct was checking the save.',
      ['E-DIRECT-SYNC-UNCLASSIFIED'] = 'Direct stopped at a save safety check it could not classify.',
      ['E-DIRECT-ROW-IDENTITY'] = 'Direct could not identify this listing row safely.',
      ['E-DIRECT-ROW-AMBIGUOUS'] = 'Ambiguous buffer content: Direct cannot tell which entry this row represents.',
      ['E-DIRECT-ROW-STALE'] = 'This entry changed on disk after it was listed.',
      ['E-DIRECT-ROW-UNSAFE'] = 'Unsafe entry: this name or path component is not supported.',
      ['E-DIRECT-ROW-CONFLICT'] = 'These entries conflict because they target the same path.',
      ['E-DIRECT-TREE-IDENTITY'] = 'Direct could not verify the identity of an expanded-folder entry.',
      ['E-DIRECT-TREE-BASELINE'] = 'An expanded-folder row no longer matches the folder listing Direct captured.',
      ['E-DIRECT-TREE-STRUCTURE'] = 'The expanded-folder rows do not form a valid directory tree.',
      ['E-DIRECT-TREE-INDENT'] = 'This child row has invalid indentation.',
      ['E-DIRECT-TREE-EMPTY'] = 'A child row has no entry name.',
      ['E-DIRECT-TREE-PARENT'] = 'This child row has no valid parent directory.',
      ['E-DIRECT-TREE-COLLAPSED'] = 'Child rows under a collapsed directory cannot be edited.',
      ['E-DIRECT-TREE-DUPLICATE'] = 'This folder would contain duplicate entry names.',
      ['E-DIRECT-TREE-AMBIGUOUS'] = 'Direct cannot pair these child rows with their original entries.',
      ['E-DIRECT-TREE-TYPE'] = 'An expanded directory cannot be changed into a different entry type.',
      ['E-DIRECT-TREE-DESTINATION'] = 'Direct could not determine the destination folder for this child row.',
      ['E-DIRECT-TREE-LIMITATION'] = 'This folder move cannot be combined safely with edits to its descendants.',
      ['E-DIRECT-PATH-PARENT'] = 'The parent path for this entry is not a directory.',
      ['E-DIRECT-PATH-OCCUPIED'] = 'The destination already exists.',
      ['E-DIRECT-PATH-CONFLICT'] = 'Multiple save actions target the same path.',
      ['E-DIRECT-DIRECTORY-HIDDEN'] = 'This directory contains a hidden or ignored entry that would be affected.',
    }
    local codes = refusals.codes()
    H.assert_true(#codes > 0, 'refusal registry is populated')
    H.assert_eq(#codes, vim.tbl_count(expected_summaries), 'every registered code has a pinned message')

    for _, code in ipairs(codes) do
      local definition = refusals.definition(code)
      H.assert_eq(definition.code, code, 'definition keeps its stable code')
      H.assert_eq(definition.summary, expected_summaries[code], code .. ' keeps its user-facing message')
      H.assert_true(type(definition.remedy) == 'string' and definition.remedy ~= '', code .. ' has a remedy')
      H.assert_eq(definition.help, 'direct-refusals', code .. ' maps to the refusal help topic')
      H.assert_true(refusals.format(code):find(code, 1, true) ~= nil, code .. ' appears in the formatted message')
    end

    for _, case in ipairs(reason_cases) do
      local code = refusals.code_for_reason(case[1])
      H.assert_eq(code, case[2], 'current refusal reason maps to ' .. case[2] .. ': ' .. case[1])
      H.assert_true(code ~= 'E-DIRECT-SYNC-UNCLASSIFIED', case[1] .. ' must not use the fallback code')
      H.assert_eq(refusals.definition(code).help, 'direct-refusals', code .. ' has a help mapping')
    end
    H.assert_eq(refusals.code_for_reason('history preflight failed: busy'), 'E-DIRECT-SYNC-HISTORY')
    H.assert_eq(refusals.code_for_reason('unrecognized future refusal'), 'E-DIRECT-SYNC-UNCLASSIFIED')
  end)

  H.it('moves to and diagnoses the offending row, then clears on the next text change', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'a' })
    local listing = buffer.list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '../escape' })

    H.capture_messages()
    local ok, message = listing:sync()
    H.assert_nil(ok, 'unsafe name is refused')
    H.assert_true(message:find('E-DIRECT-ROW-UNSAFE', 1, true) ~= nil, 'message begins with the stable refusal code')
    H.assert_true(message:find('Line 1:', 1, true) ~= nil, 'message names the offending row')

    local diagnostics = vim.diagnostic.get(bufnr, { namespace = refusals.namespace })
    H.assert_eq(#diagnostics, 1, 'one direct refusal diagnostic is attached')
    H.assert_eq(diagnostics[1].lnum, 0, 'diagnostic uses zero-based row coordinates')
    H.assert_eq(diagnostics[1].code, 'E-DIRECT-ROW-UNSAFE')
    H.assert_eq(vim.api.nvim_win_get_cursor(0), { 1, 0 }, 'cursor moves to the offending row')
    local other_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(other_buf, 0, -1, false, { 'unrelated' })
    H.assert_eq(#vim.diagnostic.get(other_buf, { namespace = refusals.namespace }), 0, 'diagnostics are buffer-local')
    H.assert_fs_eq(ws, { 'a.txt' }, 'refusal does not change the filesystem')

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'safe.txt' })
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    H.assert_true(
      #vim.diagnostic.get(bufnr, { namespace = refusals.namespace }) == 0,
      'diagnostic clears after the next text change'
    )
    for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = 'TextChanged', buffer = bufnr })) do
      H.assert_true(
        autocmd.group_name ~= 'direct.sync-refusal.' .. bufnr,
        'the per-buffer clear autocmd is removed after firing'
      )
    end
  end)

  H.it('keeps global refusals rowless and does not move the cursor', function()
    clean_buffers()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'one', 'two' })
    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    H.capture_messages()

    local message = refusals.report(bufnr, 'E-DIRECT-SYNC-BUSY', nil, vim.log.levels.WARN)

    H.assert_true(message:find('E-DIRECT-SYNC-BUSY', 1, true) ~= nil)
    H.assert_true(message:find('Line ', 1, true) == nil, 'global refusal does not invent a row')
    H.assert_eq(#vim.diagnostic.get(bufnr, { namespace = refusals.namespace }), 0, 'no row diagnostic is created')
    H.assert_eq(vim.api.nvim_win_get_cursor(0), { 2, 0 }, 'global refusal leaves the cursor in place')
    H.assert_eq(refusals.definition('E-DIRECT-SYNC-BUSY').help, 'direct-refusals')
  end)

  H.it('tests diagnostic behavior for every registered refusal code', function()
    clean_buffers()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'first', 'offending', 'last' })
    local bufnr = vim.api.nvim_get_current_buf()

    for _, code in ipairs(refusals.codes()) do
      local definition = refusals.definition(code)
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      local message = refusals.report(bufnr, code, { line = 1, path = '/work/entry' }, vim.log.levels.WARN)
      H.assert_true(message:find(code, 1, true) ~= nil, code .. ' stays in the user message')
      local diagnostics = vim.diagnostic.get(bufnr, { namespace = refusals.namespace })
      if definition.rowless then
        H.assert_true(message:find('Line ', 1, true) == nil, code .. ' cannot identify a row')
        H.assert_eq(#diagnostics, 0, code .. ' produces no row diagnostic')
        H.assert_eq(vim.api.nvim_win_get_cursor(0), { 3, 0 }, code .. ' leaves the cursor in place')
      else
        H.assert_true(message:find('Line 2:', 1, true) ~= nil, code .. ' identifies its row')
        H.assert_eq(#diagnostics, 1, code .. ' creates one row diagnostic')
        H.assert_eq(diagnostics[1].lnum, 1, code .. ' uses the row offset')
        H.assert_eq(diagnostics[1].code, code, code .. ' appears in diagnostic metadata')
        H.assert_eq(vim.api.nvim_win_get_cursor(0), { 2, 0 }, code .. ' moves the cursor to its row')
        vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
        H.assert_eq(
          #vim.diagnostic.get(bufnr, { namespace = refusals.namespace }),
          0,
          code .. ' diagnostic clears on the next change'
        )
      end
    end
  end)

  H.it('codes a history-lock refusal without calling it a partial action failure', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'a' })
    local listing = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'a.txt', 'new.txt' })
    local restore = H.stub(history.lock, 'acquire', function() return nil, 'test lock contention' end)
    H.capture_messages()

    local ok, message = listing:sync()

    restore()
    H.assert_nil(ok, 'the save is refused before actions')
    H.assert_true(message:find('E-DIRECT-SYNC-HISTORY', 1, true) ~= nil, 'history refusal has a stable code')
    H.assert_eq(#vim.diagnostic.get(0, { namespace = refusals.namespace }), 0, 'global lock refusal has no row')
    H.assert_fs_eq(ws, { 'a.txt' }, 'lock refusal leaves the directory unchanged')
    H.assert_notified('E-DIRECT-SYNC-HISTORY', vim.log.levels.ERROR)
  end)
end)
