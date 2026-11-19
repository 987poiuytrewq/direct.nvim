-- Regression coverage for a grouped root permutation combined with other edits.
local sync = require('tests.support.sync_helpers').new()
local H = sync.H
local buffer = sync.buffer
local fs = sync.fs
local paths = sync.paths
local history = sync.history
local register = sync.register
local clean_buffers = sync.clean_buffers
local history_lines = sync.history_lines

local root_contents = {
  { 'seed=20 root=1', 'payload=965421' },
  { 'seed=20 root=2', 'payload=632234' },
  { 'seed=20 root=3', 'payload=93957' },
  { 'seed=20 root=4', 'payload=190742' },
  { 'seed=20 root=5', 'payload=191528' },
  { 'seed=20 root=6', 'payload=662720' },
}
local left_contents = {
  { 'seed=20 left=1', 'payload=206751' },
  { 'seed=20 left=2', 'payload=944572' },
  { 'seed=20 left=3', 'payload=315586' },
}
local right_contents = { 'seed=20 right=1', 'payload=845563' }

local function edit_row(bufnr, row, replacement)
  local old = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
  if old ~= replacement then vim.api.nvim_buf_set_text(bufnr, row - 1, 0, row - 1, #old, { replacement }) end
end

local function find_line(lines, target)
  for index, line in ipairs(lines) do
    if line == target then return index end
  end
end

local function fixture()
  clean_buffers()
  local sb = H.sandbox()
  local ws = H.mkdir(sb.root, 'ws')
  local left = H.mkdir(ws, 'left')
  local right = H.mkdir(ws, 'right')
  for index = 1, 3 do
    H.mkfile(left, 'left-' .. index .. '.txt', left_contents[index])
  end
  H.mkfile(right, 'right-1.txt', right_contents)
  for index = 1, 6 do
    H.mkfile(ws, string.format('root-%02d.txt', index), root_contents[index])
  end
  return sb, ws, left, right
end

local function prepare(listing)
  listing:expand(1)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local right_row = find_line(lines, 'right/')
  H.assert_not_nil(right_row, 'right/ root row is present')
  H.assert_eq(right_row, 5, 'right/ is the fifth row after expanding left/')
  listing:expand(right_row)
  local bufnr = vim.api.nvim_get_current_buf()
  local before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  H.assert_eq(before, {
    'left/',
    '  left-1.txt',
    '  left-2.txt',
    '  left-3.txt',
    'right/',
    '  right-1.txt',
    'root-01.txt',
    'root-02.txt',
    'root-03.txt',
    'root-04.txt',
    'root-05.txt',
    'root-06.txt',
  }, 'both directories and six root files appear in the generated listing order')
  return bufnr
end

local function move_child_to_right(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local source_row = find_line(lines, '  left-3.txt')
  local right_row = find_line(lines, 'right/')
  H.assert_not_nil(source_row, 'left/left-3.txt is expanded')
  H.assert_not_nil(right_row, 'right/ is expanded')
  local target_last_row = right_row
  for index = right_row + 1, #lines do
    if lines[index]:sub(1, 2) ~= '  ' then break end
    target_last_row = index
  end
  H.assert_eq({ source_row, right_row, target_last_row }, { 4, 5, 6 }, 'the child move uses the expected tree rows')
  vim.cmd('4move 6')
end

local function rotate_six_and_delete_last(bufnr)
  -- Rotate all six root names by one before deleting the resulting root-06 row.
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for index = 1, 6 do
    local row = find_line(lines, string.format('root-%02d.txt', index))
    local next_name = string.format('root-%02d.txt', (index % 6) + 1)
    edit_row(bufnr, row, next_name)
  end

  -- Move left/left-3.txt under right/ without changing its displayed name.
  move_child_to_right(bufnr)

  lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local deleted_row = find_line(lines, 'root-06.txt')
  H.assert_not_nil(deleted_row, 'root-06.txt remains the independent deletion')
  H.assert_eq(deleted_row, 11, 'the resulting root-06 row is deleted')
  vim.api.nvim_buf_set_lines(bufnr, deleted_row - 1, deleted_row, false, {})
end

local function rotate_six_and_delete_last_without_child_move(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for index = 1, 6 do
    local row = find_line(lines, string.format('root-%02d.txt', index))
    local next_name = string.format('root-%02d.txt', (index % 6) + 1)
    edit_row(bufnr, row, next_name)
  end
  lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local deleted_row = find_line(lines, 'root-06.txt')
  H.assert_eq(deleted_row, 11, 'root-06 is the row removed after permutation')
  vim.api.nvim_buf_set_lines(bufnr, deleted_row - 1, deleted_row, false, {})
end

local function move_child_and_delete_last(bufnr)
  move_child_to_right(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local deleted_row = find_line(lines, 'root-06.txt')
  H.assert_not_nil(deleted_row)
  vim.api.nvim_buf_set_lines(bufnr, deleted_row - 1, deleted_row, false, {})
end

H.describe('sync: grouped move with deletion', function()
  H.it('applies a six-name root rotation, child move, and deletion without losing payloads', function()
    local _, ws, left, right = fixture()
    local listing = buffer.list(ws)
    local bufnr = prepare(listing)
    rotate_six_and_delete_last(bufnr)

    local ok, reason = listing:sync()

    local actual = H.fs_snapshot(ws)
    local transaction_path = paths.join(paths.data_dir('history'), 'transaction.json')
    local journal = vim.fn.filereadable(transaction_path) == 1 and table.concat(vim.fn.readfile(transaction_path), '\n')
      or '<none>'
    H.assert_true(
      ok == true,
      'combined sync succeeds: ' .. tostring(reason) .. '; fs=' .. vim.inspect(actual) .. '; journal=' .. journal
    )
    H.assert_eq(actual, {
      'left/',
      'left/left-1.txt',
      'left/left-2.txt',
      'right/',
      'right/left-3.txt',
      'right/right-1.txt',
      'root-01.txt',
      'root-02.txt',
      'root-03.txt',
      'root-04.txt',
      'root-05.txt',
    }, 'the child move, root rotation, and deletion all apply')
    for index = 1, 5 do
      local destination = string.format('%s/root-%02d.txt', ws, index)
      local source_index = index == 1 and 6 or index - 1
      H.assert_eq(
        vim.fn.readfile(destination),
        root_contents[source_index],
        'rotation preserves root payload ' .. index
      )
    end
    H.assert_eq(
      vim.fn.readfile(right .. '/left-3.txt'),
      left_contents[3],
      'the child payload reaches its cross-folder destination'
    )
    H.assert_false(fs.taken(ws .. '/.direct-tmp-1'), 'no grouped-move temp remains')
    local deleted = register.entries(register.content())
    H.assert_eq(#deleted, 1, 'the removed root entry is stored in trash')
    H.assert_eq(
      vim.fn.readfile(deleted[1].path),
      root_contents[5],
      'the deleted file remains recoverable from its trash payload'
    )
    H.assert_eq(history_lines('undo.log')[1], sync.HEADER, 'history remains parseable')
    H.assert_false(fs.taken(transaction_path), 'the completed sync clears its transaction journal')

    H.assert_not_nil(history.undo(), 'one undo reverses the complete mixed sync')
    H.assert_eq(H.fs_snapshot(ws), {
      'left/',
      'left/left-1.txt',
      'left/left-2.txt',
      'left/left-3.txt',
      'right/',
      'right/right-1.txt',
      'root-01.txt',
      'root-02.txt',
      'root-03.txt',
      'root-04.txt',
      'root-05.txt',
      'root-06.txt',
    }, 'undo restores the exact pre-sync paths')
    H.assert_eq(vim.fn.readfile(left .. '/left-3.txt'), left_contents[3])
    H.assert_eq(
      vim.fn.readfile(ws .. '/root-06.txt'),
      root_contents[6],
      'undo restores the deleted entry without overwriting another payload'
    )

    H.assert_not_nil(history.redo(), 'redo reapplies the complete mixed sync')
    H.assert_eq(H.fs_snapshot(ws), actual, 'redo restores the post-sync paths')
    H.assert_eq(vim.fn.readfile(right .. '/left-3.txt'), left_contents[3])
  end)

  H.it('recovers a persisted grouped move after a late rename interruption', function()
    local _, ws = fixture()
    local listing = buffer.list(ws)
    local bufnr = prepare(listing)
    rotate_six_and_delete_last(bufnr)
    local temp4, root05 = ws .. '/.direct-tmp-4', ws .. '/root-05.txt'
    local real_rename = fs.rename
    local injected = false
    local restore = H.stub(fs, 'rename', function(src, dst)
      if src == temp4 and dst == root05 then
        injected = true
        return nil, 'EIO: injected grouped move interruption'
      end
      return real_rename(src, dst)
    end)

    local ok, reason = listing:sync()
    restore()

    H.assert_nil(ok, 'the injected late move failure is reported')
    H.assert_true(tostring(reason):find('EIO', 1, true) ~= nil, tostring(reason))
    H.assert_true(injected, 'the failure occurred at the final root-05 placement')
    local transaction_path = paths.join(paths.data_dir('history'), 'transaction.json')
    H.assert_true(fs.taken(transaction_path), 'the pending grouped-move journal is preserved')
    local transaction = vim.json.decode(table.concat(vim.fn.readfile(transaction_path), '\n'))
    H.assert_eq(transaction.format, 'direct-operation-journal', 'the journal format is intact')
    H.assert_eq(transaction.version, 1, 'the journal version is intact')
    H.assert_eq(transaction.kind, 'apply', 'the journal describes the interrupted sync action')
    H.assert_eq(transaction.direction, 'apply', 'the journal direction is intact')
    H.assert_eq(transaction.staging_count, 4, 'four root sources were staged')
    H.assert_eq(#transaction.steps, 9, 'the full grouped move plan remains journaled')
    H.assert_eq(transaction.next_step, 9, 'the journal resumes at the failed final move')
    local expected_steps = {
      { ws .. '/root-01.txt', ws .. '/.direct-tmp-1' },
      { ws .. '/root-02.txt', ws .. '/.direct-tmp-2' },
      { ws .. '/root-03.txt', ws .. '/.direct-tmp-3' },
      { ws .. '/root-04.txt', temp4 },
      { ws .. '/root-06.txt', ws .. '/root-01.txt' },
      { ws .. '/.direct-tmp-1', ws .. '/root-02.txt' },
      { ws .. '/.direct-tmp-2', ws .. '/root-03.txt' },
      { ws .. '/.direct-tmp-3', ws .. '/root-04.txt' },
      { temp4, root05 },
    }
    for index, pair in ipairs(expected_steps) do
      H.assert_eq(transaction.steps[index].src, pair[1], 'journal step ' .. index .. ' source is exact')
      H.assert_eq(transaction.steps[index].dst, pair[2], 'journal step ' .. index .. ' destination is exact')
    end

    H.assert_eq(
      vim.fn.readfile(temp4),
      root_contents[4],
      'the failed move keeps its original payload at the staging path'
    )
    H.assert_false(fs.taken(root05), 'the failed rename did not create or overwrite its destination')
    H.assert_eq(
      vim.fn.readfile(ws .. '/right/left-3.txt'),
      left_contents[3],
      'the completed cross-folder move retains its payload'
    )
    for destination = 2, 4 do
      H.assert_eq(
        vim.fn.readfile(ws .. string.format('/root-%02d.txt', destination)),
        root_contents[destination - 1],
        'completed step preserves payload at root-' .. destination
      )
    end
    local deleted = register.entries(register.content())
    H.assert_eq(#deleted, 1, 'the independent deletion remains represented in trash')
    H.assert_eq(
      vim.fn.readfile(deleted[1].path),
      root_contents[5],
      'the deleted destination occupant remains recoverable'
    )
    H.assert_eq(vim.fn.readfile(ws .. '/root-01.txt'), root_contents[6], 'the first completed move remains intact')

    H.assert_not_nil(history.preflight(), 'recovery resumes the durable grouped plan')
    H.assert_false(fs.taken(transaction_path), 'successful recovery clears the journal')
    H.assert_eq(H.fs_snapshot(ws), {
      'left/',
      'left/left-1.txt',
      'left/left-2.txt',
      'right/',
      'right/left-3.txt',
      'right/right-1.txt',
      'root-01.txt',
      'root-02.txt',
      'root-03.txt',
      'root-04.txt',
      'root-05.txt',
    }, 'recovery completes the rotation without losing the child move or delete')
    for index = 1, 5 do
      local source_index = index == 1 and 6 or index - 1
      H.assert_eq(
        vim.fn.readfile(ws .. string.format('/root-%02d.txt', index)),
        root_contents[source_index],
        'recovery preserves root payload ' .. index
      )
    end
    H.assert_eq(
      vim.fn.readfile(deleted[1].path),
      root_contents[5],
      'recovery leaves the deleted payload unchanged in trash'
    )
    H.assert_nil(vim.uv.fs_lstat(temp4), 'recovery consumes the staged entry')
    H.assert_not_nil(history.preflight(), 'a second preflight is idempotent after recovery')
  end)

  H.it('control: root rotation and deletion work without the child move', function()
    local _, ws = fixture()
    local listing = buffer.list(ws)
    local bufnr = prepare(listing)
    rotate_six_and_delete_last_without_child_move(bufnr)

    local ok, reason = listing:sync()

    H.assert_true(ok == true, tostring(reason))
    H.assert_true(fs.taken(ws .. '/root-01.txt'), 'the permutation completed')
    H.assert_false(fs.taken(ws .. '/root-06.txt'), 'the deletion completed')
  end)

  H.it('control: child move and deletion work without the root permutation', function()
    local _, ws, _, right = fixture()
    local listing = buffer.list(ws)
    local bufnr = prepare(listing)
    move_child_and_delete_last(bufnr)

    local ok, reason = listing:sync()

    H.assert_true(ok == true, tostring(reason))
    H.assert_eq(vim.fn.readfile(right .. '/left-3.txt'), left_contents[3])
    H.assert_false(fs.taken(ws .. '/root-06.txt'), 'the deletion completed')
  end)
end)
