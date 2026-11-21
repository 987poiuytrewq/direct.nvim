local sync = require('tests.support.sync_helpers').new()
local H = sync.H
local buffer = sync.buffer

local function row_for(lines, name)
  for row, line in ipairs(lines) do
    if line == name then return row end
  end
end

local cases = {
  {
    label = 'name',
    sort = 'name',
    sort_directories_first = true,
    expected = { 'dir10/', 'dir2/', 'a.txt', 'file10.txt', 'file2.txt', 'z.txt' },
  },
  {
    label = 'natural',
    sort = 'natural',
    sort_directories_first = true,
    expected = { 'dir2/', 'dir10/', 'a.txt', 'file2.txt', 'file10.txt', 'z.txt' },
  },
  {
    label = 'custom',
    sort = function(a, b) return a.name > b.name end,
    sort_directories_first = false,
    expected = { 'z.txt', 'file2.txt', 'file10.txt', 'dir2/', 'dir10/', 'a.txt' },
  },
}

H.describe('sync: sort order preserves identity-based rename pairing', function()
  for _, case in ipairs(cases) do
    H.it('saves and undoes a rename with ' .. case.label .. ' sorting', function()
      sync.clean_buffers()
      local config = require('direct.config')
      config.clear_mappings()
      config.setup({
        sort = case.sort,
        sort_directories_first = case.sort_directories_first,
        collapse_single_entry_directories = false,
        respect_gitignore = false,
        git = { enabled = false },
      })
      local sandbox = H.sandbox()
      local root = H.mkdir(sandbox.root, 'workspace')
      H.mkdir(root, 'dir10')
      H.mkdir(root, 'dir2')
      H.mkfile(root, 'a.txt', { 'alpha' })
      H.mkfile(root, 'file2.txt', { 'two' })
      H.mkfile(root, 'file10.txt', { 'ten' })
      H.mkfile(root, 'z.txt', { 'zulu' })

      local listing = buffer.list(root)
      local lines = H.buf_lines()
      H.assert_eq(lines, case.expected, case.label .. ' mode controls presentation order')
      local source_row = row_for(lines, 'file10.txt')
      H.assert_not_nil(source_row, 'rename source is visible in the selected sort mode')
      vim.api.nvim_buf_set_text(0, source_row - 1, 0, source_row - 1, #'file10.txt', { 'renamed.txt' })

      local synced, sync_err = listing:sync()

      H.assert_true(synced, case.label .. ' rename sync succeeds: ' .. tostring(sync_err))
      H.assert_nil(vim.uv.fs_stat(vim.fs.joinpath(root, 'file10.txt')), 'only the identified source is renamed')
      H.assert_eq(vim.fn.readfile(vim.fs.joinpath(root, 'renamed.txt')), { 'ten' }, 'source contents follow its row')
      H.assert_eq(vim.fn.readfile(vim.fs.joinpath(root, 'file2.txt')), { 'two' }, 'neighboring row is unchanged')
      H.assert_eq(vim.fn.readfile(vim.fs.joinpath(root, 'a.txt')), { 'alpha' }, 'another row is unchanged')

      H.assert_true(require('direct').undo() ~= nil, 'rename undo starts')
      H.assert_true(
        vim.wait(
          5000,
          function()
            return vim.uv.fs_stat(vim.fs.joinpath(root, 'file10.txt')) ~= nil
              and vim.uv.fs_stat(vim.fs.joinpath(root, 'renamed.txt')) == nil
          end
        ),
        case.label .. ' sort undo restores the original path'
      )
      H.assert_eq(vim.fn.readfile(vim.fs.joinpath(root, 'file10.txt')), { 'ten' })
      H.assert_true(vim.wait(5000, function() return not require('direct.pending').is_pending() end))
    end)
  end
end)
