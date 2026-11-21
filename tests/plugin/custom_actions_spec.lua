-- tests/plugin/custom_actions_spec.lua -- custom Lua actions and row APIs.

local H = require('tests.support.harness')

local function clean_buffers() pcall(vim.cmd, '%bwipeout!') end

local function line_number(text)
  for row, line in ipairs(H.buf_lines()) do
    if line == text then return row end
  end
end

local function git(root, ...)
  local args = { 'git', '-C', root, ... }
  local result = vim.system(args, { text = true }):wait()
  H.assert_eq(result.code, 0, 'git ' .. table.concat({ ... }, ' ') .. ' succeeds')
  return result.stdout or ''
end

local function wait_for_git()
  H.assert_true(
    vim.wait(5000, function()
      local state = require('direct.buffer.buffer')._state_for_test(vim.api.nvim_get_current_buf())
      return state and not state.git_status_pending
    end),
    'Git status completes before inspecting deleted rows'
  )
end

local function assert_entry_path(entry, path, message)
  H.assert_not_nil(entry, message)
  if entry then H.assert_true(require('direct.fs').same_path(entry.path, path), message .. ' path') end
end

local function custom_mapping(bufnr, lhs)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, 'n')) do
    if mapping.desc == 'direct: custom action: ' .. lhs then return mapping end
  end
end

H.describe('custom actions and entry APIs', function()
  H.it('returns defensive entry records for files, directories, and collapsed chains', function()
    clean_buffers()
    local config = require('direct.config')
    config.setup({ map_default_keys = false, collapse_single_entry_directories = true })
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local dir = H.mkdir(ws, 'dir')
    H.mkfile(dir, 'one.txt', '')
    H.mkfile(dir, 'two.txt', '')
    local chain = H.mkdir(ws, 'chain')
    H.mkdir(chain, 'branch')
    H.mkfile(ws, 'chain/branch/leaf.txt', '')
    H.mkfile(ws, 'file.txt', '')

    local direct = require('direct')
    H.assert_nil(direct.current_entry(), 'no row is returned outside a Direct listing')
    H.assert_nil(direct.selected_entries(), 'no selection is returned outside a Direct listing')

    local listing = direct.list(ws)
    H.assert_eq(H.buf_lines(), { 'chain/branch/', 'dir/', 'file.txt' })
    local row = assert(line_number('file.txt'))
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    local file = direct.current_entry()
    H.assert_eq(file.name, 'file.txt', 'file name is normalized')
    H.assert_eq(file.type, 'file', 'file kind is exposed')
    H.assert_eq(file.root, listing.root, 'entry carries the listing root')
    H.assert_false(file.deleted, 'live file is not deleted')
    assert_entry_path(file, ws .. '/file.txt', 'file entry')

    row = assert(line_number('dir/'))
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    local directory = direct.current_entry()
    H.assert_eq(directory.name, 'dir', 'directory marker is omitted from the name')
    H.assert_eq(directory.type, 'directory', 'directory kind is exposed')
    assert_entry_path(directory, dir, 'directory entry')

    row = assert(line_number('chain/branch/'))
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    local collapsed = direct.current_entry()
    H.assert_eq(collapsed.name, 'chain/branch', 'collapsed chain name remains the displayed chain')
    H.assert_eq(collapsed.type, 'directory', 'collapsed chain is a directory')
    assert_entry_path(collapsed, ws .. '/chain/branch', 'collapsed chain entry')

    collapsed.name = 'mutated'
    H.assert_eq(direct.current_entry().name, 'chain/branch', 'public entry is detached from row state')

    row = assert(line_number('file.txt'))
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    vim.api.nvim_buf_set_lines(0, row - 1, row, false, { 'unsaved.txt' })
    H.assert_nil(direct.current_entry(), 'unsaved row names do not expose a stale action target')
  end)

  H.it('returns selected entry records for the active visual line range only', function()
    clean_buffers()
    local direct = require('direct')
    require('direct.config').setup({ map_default_keys = false, collapse_single_entry_directories = false })
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', '')
    H.mkfile(ws, 'b.txt', '')
    H.mkfile(ws, 'c.txt', '')
    local listing = direct.list(ws)

    H.assert_nil(direct.selected_entries(), 'no selection is returned in Normal mode')
    vim.cmd('normal! ggVj')
    local mode = vim.api.nvim_get_mode().mode
    H.assert_true(mode == 'V' or mode == 'v', 'test has an active visual selection')
    local entries = direct.selected_entries()
    H.assert_eq(#entries, 2, 'selected line range returns both entries')
    H.assert_eq({ entries[1].name, entries[2].name }, { 'a.txt', 'b.txt' }, 'selection follows display order')
    H.assert_eq(entries[1].root, listing.root, 'selected entries carry the listing root')
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)
    H.assert_nil(direct.selected_entries(), 'selection API returns nil after leaving Visual mode')
  end)

  H.it('installs a custom buffer mapping and passes file, directory, collapsed, and deleted rows', function()
    clean_buffers()
    local received = {}
    local callback = function(entry) received[#received + 1] = entry end
    local config = require('direct.config')
    config.setup({
      map_default_keys = false,
      collapse_single_entry_directories = true,
      git = { enabled = true, show_deleted = true },
      mappings = { ['<leader>e'] = callback },
    })
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local dir = H.mkdir(ws, 'dir')
    H.mkfile(dir, 'one.txt', '')
    H.mkfile(dir, 'two.txt', '')
    local chain = H.mkdir(ws, 'chain')
    H.mkdir(chain, 'branch')
    H.mkfile(ws, 'chain/branch/leaf.txt', '')
    local file = H.mkfile(ws, 'file.txt', '')
    local deleted = H.mkfile(ws, 'gone.txt', '')
    git(ws, 'init', '-q')
    git(ws, 'config', 'user.name', 'Direct Test')
    git(ws, 'config', 'user.email', 'direct-test@example.invalid')
    git(ws, 'add', '--all')
    git(ws, 'commit', '-q', '-m', 'base')
    H.assert_true(vim.uv.fs_unlink(deleted), 'tracked file is removed')

    local direct = require('direct')
    local listing = direct.list(ws)
    wait_for_git()
    local bufnr = vim.api.nvim_get_current_buf()
    local mapping = custom_mapping(bufnr, '<leader>e')
    H.assert_not_nil(mapping, 'custom callback is installed buffer-locally')
    H.assert_true(type(mapping and mapping.callback) == 'function', 'custom mapping uses a Lua callback')

    local cases = {
      { line = 'file.txt', path = file, name = 'file.txt', kind = 'file', deleted = false },
      { line = 'dir/', path = dir, name = 'dir', kind = 'directory', deleted = false },
      {
        line = 'chain/branch/',
        path = ws .. '/chain/branch',
        name = 'chain/branch',
        kind = 'directory',
        deleted = false,
      },
      { line = 'gone.txt', path = deleted, name = 'gone.txt', kind = 'file', deleted = true },
    }
    for _, case in ipairs(cases) do
      local row = assert(line_number(case.line))
      vim.api.nvim_win_set_cursor(0, { row, 0 })
      mapping.callback()
    end
    H.assert_eq(#received, #cases, 'custom action is called once for each valid row')
    for index, case in ipairs(cases) do
      local entry = received[index]
      H.assert_eq(entry.name, case.name, 'callback receives row name for ' .. case.line)
      H.assert_eq(entry.type, case.kind, 'callback receives row type for ' .. case.line)
      H.assert_eq(entry.root, listing.root, 'callback receives listing root for ' .. case.line)
      H.assert_eq(entry.deleted, case.deleted, 'callback receives deleted state for ' .. case.line)
      assert_entry_path(entry, case.path, 'callback entry for ' .. case.line)
    end

    config.setup({ map_default_keys = false })
    H.assert_eq(vim.fn.maparg('<leader>e', 'n'), '', 'reconfiguration clears the old custom callback')
    H.assert_true(config.clear_mappings(), 'clear_mappings succeeds')
  end)

  H.it('reports custom callback errors without raising from the mapping', function()
    clean_buffers()
    local config = require('direct.config')
    config.setup({
      map_default_keys = false,
      mappings = {
        ['<leader>x'] = function() error('injected custom action failure') end,
      },
    })
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'file.txt', '')
    require('direct').list(ws)
    local mapping = custom_mapping(vim.api.nvim_get_current_buf(), '<leader>x')
    H.assert_not_nil(mapping, 'erroring custom callback is installed')
    H.capture_messages()
    local ok, err = pcall(mapping.callback)
    H.assert_true(ok, tostring(err))
    H.assert_notified('custom key action <leader>x', vim.log.levels.WARN)
    H.assert_notified('injected custom action failure', vim.log.levels.WARN)
  end)
end)
