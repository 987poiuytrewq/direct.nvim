local H = require('tests.support.harness')

local function clean_buffers()
  pcall(vim.cmd, '%bwipeout!')
  require('direct.config').clear_mappings()
end

local function listing_with(root, options)
  clean_buffers()
  require('direct.config').setup(options or {})
  return require('direct.buffer.buffer').list(root)
end

local function git(root, ...)
  local args = { 'git', '-C', root }
  for _, arg in ipairs({ ... }) do
    args[#args + 1] = arg
  end
  local result = vim.system(args, { text = true }):wait()
  if result.code ~= 0 then error(result.stderr or 'git failed') end
  return (result.stdout or ''):gsub('[\r\n]+$', '')
end

H.describe('buffer: configurable sort and hidden rules', function()
  H.it('sorts names naturally and optionally interleaves directories and files', function()
    clean_buffers()
    local sandbox = H.sandbox()
    local root = H.mkdir(sandbox.root, 'workspace')
    H.mkdir(root, 'dir10')
    H.mkdir(root, 'dir2')
    H.mkfile(root, 'B.txt', '')
    H.mkfile(root, 'a.txt', '')
    H.mkfile(root, 'file10.txt', '')
    H.mkfile(root, 'file2.txt', '')

    H.assert_eq(
      require('direct.fs').read_dir_lines(root, nil, nil, {
        sort = 'natural',
        sort_directories_first = true,
      }),
      { 'dir2/', 'dir10/', 'a.txt', 'B.txt', 'file2.txt', 'file10.txt' },
      'filesystem sorting supports natural order'
    )
    listing_with(root, { sort = 'natural', collapse_single_entry_directories = false })

    H.assert_buf_eq({ 'dir2/', 'dir10/', 'a.txt', 'B.txt', 'file2.txt', 'file10.txt' })

    listing_with(root, {
      sort = 'natural',
      sort_directories_first = false,
      collapse_single_entry_directories = false,
    })

    H.assert_buf_eq({ 'a.txt', 'B.txt', 'dir2/', 'dir10/', 'file2.txt', 'file10.txt' })
  end)

  H.it('passes entry records to a custom comparator and sorts the visible rows', function()
    clean_buffers()
    local sandbox = H.sandbox()
    local root = H.mkdir(sandbox.root, 'workspace')
    H.mkdir(root, 'dir')
    H.mkfile(root, 'a.txt', '')
    H.mkfile(root, 'z.txt', '')
    local seen_types = {}

    listing_with(root, {
      sort = function(a, b)
        seen_types[a.type] = true
        seen_types[b.type] = true
        return a.name > b.name
      end,
      sort_directories_first = false,
      collapse_single_entry_directories = false,
    })

    H.assert_buf_eq({ 'z.txt', 'dir/', 'a.txt' })
    H.assert_true(seen_types.directory, 'custom comparator receives directory records')
    H.assert_true(seen_types.file, 'custom comparator receives file records')
  end)

  H.it('falls back to a complete deterministic name sort and warns once on comparator error', function()
    clean_buffers()
    local sandbox = H.sandbox()
    local root = H.mkdir(sandbox.root, 'workspace')
    H.mkdir(root, 'b-dir')
    H.mkdir(root, 'a-dir')
    H.mkfile(root, 'z.txt', '')
    H.mkfile(root, 'a.txt', '')
    H.capture_messages()
    local ui = require('direct.ui')
    local notify = ui.notify
    local sort_warnings = 0
    local restore_notify = H.stub(ui, 'notify', function(message, level)
      if tostring(message):find('custom sort failed', 1, true) then sort_warnings = sort_warnings + 1 end
      return notify(message, level)
    end)

    listing_with(root, {
      sort = function() error('injected comparator error') end,
      collapse_single_entry_directories = false,
    })
    restore_notify()

    H.assert_buf_eq({ 'a-dir/', 'b-dir/', 'a.txt', 'z.txt' })
    H.assert_eq(sort_warnings, 1, 'one listing emits one custom-sort warning')
    H.assert_notified('custom sort failed', vim.log.levels.WARN)
    H.assert_notified('using name order', vim.log.levels.WARN)
  end)

  H.it('applies custom hide exceptions while keeping Git-ignore and wildignore filters', function()
    clean_buffers()
    local sandbox = H.sandbox()
    local root = H.mkdir(sandbox.root, 'workspace')
    git(root, 'init', '-q')
    H.mkfile(root, '.gitignore', { 'secret.txt' })
    H.mkfile(root, '.hidden', '')
    H.mkfile(root, '.env', '')
    H.mkdir(root, '__pycache__')
    H.mkfile(root, 'secret.txt', '')
    H.mkfile(root, 'object.o', '')
    H.mkfile(root, 'visible.txt', '')
    local received = {}

    H.with_option('wildignore', '*.o', function()
      listing_with(root, {
        show_hidden = false,
        respect_gitignore = true,
        git = { enabled = false, ignore_timeout_ms = 5000 },
        is_hidden = function(name, path, kind)
          received[name] = { path = path, kind = kind }
          if name == '__pycache__' then return true end
          if name == '.env' or name == 'secret.txt' or name == 'object.o' then return false end
          return nil
        end,
      })

      H.assert_buf_eq({ '.env', 'visible.txt' })
      H.assert_true(received.__pycache__.path:find(root, 1, true) == 1, 'callback receives the absolute path')
      H.assert_eq(received.__pycache__.kind, 'directory', 'callback receives the entry type')
      H.assert_eq(received['.env'].kind, 'file')

      require('direct').toggle_hidden()

      H.assert_buf_eq({ '.git/', '__pycache__/', '.env', '.gitignore', '.hidden', 'visible.txt' })
      H.assert_false(vim.tbl_contains(H.buf_lines(), 'secret.txt'), 'Git-ignore remains an independent filter')
      H.assert_false(vim.tbl_contains(H.buf_lines(), 'object.o'), 'wildignore remains an independent filter')
    end)
  end)

  H.it('does not turn a custom-hidden list-time entry into a delete source', function()
    clean_buffers()
    local sandbox = H.sandbox()
    local root = H.mkdir(sandbox.root, 'workspace')
    H.mkfile(root, 'hidden.log', { 'keep' })
    H.mkfile(root, 'remove.txt', { 'remove' })
    H.mkfile(root, 'stay.txt', { 'stay' })
    local listing = listing_with(root, {
      show_hidden = false,
      respect_gitignore = false,
      is_hidden = function(name) return name == 'hidden.log' end,
    })

    H.assert_buf_eq({ 'remove.txt', 'stay.txt' })
    vim.api.nvim_buf_set_lines(0, 0, 1, false, {})
    local ok, err = listing:sync()

    H.assert_true(ok, tostring(err))
    H.assert_nil(vim.uv.fs_stat(vim.fs.joinpath(root, 'remove.txt')), 'the visible deletion is applied')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(root, 'hidden.log')), { 'keep' }, 'the custom-hidden entry survives')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(root, 'stay.txt')), { 'stay' }, 'the other visible entry survives')
  end)
end)
