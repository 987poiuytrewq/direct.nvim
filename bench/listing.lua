-- Run with: nvim --headless -l bench/listing.lua
-- Optional: DIRECT_LISTING_SAMPLES=1 for a quicker CI run.

local source = debug.getinfo(1, 'S').source:gsub('^@', '')
local repo_root = vim.fn.fnamemodify(source, ':p:h:h')
local os_tmp = vim.uv.os_tmpdir() or vim.env.TMPDIR or '.'
local created_root = vim.uv.fs_mkdtemp(vim.fs.joinpath(os_tmp, 'direct-listing-bench-XXXXXX'))
if not created_root then error('could not create benchmark fixture directory') end
local temp_root = vim.uv.fs_realpath(created_root) or created_root

local function mkdir(path)
  local ok, err = vim.uv.fs_mkdir(path, 493)
  if not ok and err ~= 'EEXIST' then error('mkdir ' .. path .. ': ' .. tostring(err)) end
end

local function write_file(path, contents)
  local fd, open_err = vim.uv.fs_open(path, 'w', 420)
  if not fd then error('open ' .. path .. ': ' .. tostring(open_err)) end
  local ok, write_err = vim.uv.fs_write(fd, contents or '', 0)
  local close_ok, close_err = vim.uv.fs_close(fd)
  if not ok then error('write ' .. path .. ': ' .. tostring(write_err)) end
  if not close_ok then error('close ' .. path .. ': ' .. tostring(close_err)) end
end

local function run(command, cwd)
  local result = vim.system(command, { cwd = cwd, text = true }):wait()
  if result.code ~= 0 then
    error(table.concat(command, ' ') .. ' failed: ' .. (result.stderr or result.stdout or ''))
  end
  return result.stdout or ''
end

local function elapsed_ms(fn)
  local start = vim.uv.hrtime()
  local result, detail = fn()
  return (vim.uv.hrtime() - start) / 1e6, result, detail
end

local function median(values)
  local sorted = vim.deepcopy(values)
  table.sort(sorted)
  return sorted[math.floor((#sorted + 1) / 2)]
end

local function format_ms(value) return string.format('%.2f', value) end

local function pack(...) return { n = select('#', ...), ... } end

local function profile_call(label, fn)
  if vim.env.DIRECT_LISTING_PROFILE ~= '1' then return fn() end
  local targets = {
    { object = vim.uv, name = 'fs_stat' },
    { object = vim.uv, name = 'fs_lstat' },
    { object = vim.uv, name = 'fs_scandir' },
    { object = vim.uv, name = 'fs_scandir_next' },
    { object = vim.api, name = 'nvim_buf_set_extmark' },
    { object = vim.api, name = 'nvim_buf_set_lines' },
    { object = vim.api, name = 'nvim_buf_get_extmarks' },
  }
  local totals = {}
  local original_system = vim.system
  local system_total = { count = 0, wait_ms = 0 }
  vim.system = function(...)
    system_total.count = system_total.count + 1
    local process = original_system(...)
    if process and type(process.wait) == 'function' then
      local original_wait = process.wait
      process.wait = function(self, ...)
        local start = vim.uv.hrtime()
        local result = pack(original_wait(self, ...))
        system_total.wait_ms = system_total.wait_ms + (vim.uv.hrtime() - start) / 1e6
        return unpack(result, 1, result.n)
      end
    end
    return process
  end
  for _, target in ipairs(targets) do
    local original = target.object[target.name]
    local row = { count = 0, ms = 0 }
    totals[target.name] = row
    target.original = original
    target.object[target.name] = function(...)
      row.count = row.count + 1
      local start = vim.uv.hrtime()
      local result = pack(original(...))
      row.ms = row.ms + (vim.uv.hrtime() - start) / 1e6
      return unpack(result, 1, result.n)
    end
  end
  local ok, result, detail = xpcall(fn, debug.traceback)
  for _, target in ipairs(targets) do
    target.object[target.name] = target.original
  end
  vim.system = original_system
  if not ok then error(result) end
  local parts = {}
  for _, target in ipairs(targets) do
    local row = totals[target.name]
    if row.count > 0 then
      parts[#parts + 1] = string.format('%s=%d calls/%s ms', target.name, row.count, format_ms(row.ms))
    end
  end
  if system_total.count > 0 then
    parts[#parts + 1] =
      string.format('vim.system=%d calls/%s ms wait', system_total.count, format_ms(system_total.wait_ms))
  end
  io.write(string.format('PROFILE %s: %s\n', label, table.concat(parts, ', ')))
  return result, detail
end

local function create_flat(root, count, with_git)
  mkdir(root)
  if with_git then write_file(vim.fs.joinpath(root, '.gitignore'), 'ignored-*\n') end

  local expand_dir = vim.fs.joinpath(root, 'expandable')
  mkdir(expand_dir)
  write_file(vim.fs.joinpath(expand_dir, 'child.txt'))

  for index = 1, count do
    local name
    if index == 1 then
      name = 'rename-source.txt'
    elseif with_git and index % 10 == 0 then
      name = string.format('ignored-%05d.txt', index)
    else
      name = string.format('file-%05d.txt', index)
    end
    write_file(vim.fs.joinpath(root, name))
  end
  if with_git then run({ 'git', 'init', '--quiet' }, root) end
end

local function create_deep(root, with_git)
  mkdir(root)
  if with_git then write_file(vim.fs.joinpath(root, '.gitignore'), 'ignored-*\n') end

  local function grow(parent, depth, prefix)
    if depth == 0 then
      for index = 1, 4 do
        local name = with_git and index == 4 and ('ignored-' .. prefix .. '.txt')
          or ('leaf-' .. prefix .. '-' .. index .. '.txt')
        write_file(vim.fs.joinpath(parent, name))
      end
      return
    end
    for index = 1, 3 do
      local name = string.format('%s-d%d-%d', prefix, depth, index)
      local child = vim.fs.joinpath(parent, name)
      mkdir(child)
      grow(child, depth - 1, name)
    end
  end

  grow(root, 4, 'tree')
  write_file(vim.fs.joinpath(root, 'rename-source.txt'))
  if with_git then run({ 'git', 'init', '--quiet' }, root) end
end

local function setup_runtime()
  vim.opt.runtimepath:prepend(repo_root)
  package.path = table.concat({
    repo_root .. '/?.lua',
    repo_root .. '/?/init.lua',
    repo_root .. '/lua/?.lua',
    repo_root .. '/lua/?/init.lua',
    package.path,
  }, ';')
  local data_home = vim.fs.joinpath(temp_root, 'data')
  mkdir(data_home)
  vim.env.XDG_DATA_HOME = data_home
  vim.cmd('runtime! plugin/direct.lua')
  require('direct.ui').notify = function() end
end

local function configure(respect_gitignore)
  require('direct.config').setup({
    respect_gitignore = respect_gitignore,
    collapse_single_entry_directories = false,
    show_folder_icons = false,
    show_file_icons = false,
    show_filetype_icons = false,
    git = { enabled = false },
    trash_retention = false,
  })
end

local function measure_case(label, root, respect_gitignore)
  configure(respect_gitignore)
  local listing
  local first_ms, first_result = elapsed_ms(function()
    return profile_call(label .. ' first-list', function()
      listing = require('direct.buffer.buffer').list(root, { reuse = false, open_in = 'new' })
      return listing
    end)
  end)
  if not first_result then error('first list failed for ' .. label) end

  local relist_ms, relisted = elapsed_ms(function()
    return profile_call(label .. ' re-list', function() return listing:list() end)
  end)
  if not relisted then error('re-list failed for ' .. label) end

  local buffer = require('direct.buffer.buffer')
  local expand_ms, expanded, expand_err = elapsed_ms(function()
    return profile_call(label .. ' zR', function() return require('direct.folding').expand_all(buffer) end)
  end)
  if not expanded then error('zR expansion failed for ' .. label .. ': ' .. tostring(expand_err)) end
  local expanded_rows = vim.api.nvim_buf_line_count(0)

  -- Measure a one-row rename save from a freshly listed, unexpanded buffer.
  vim.cmd('bwipeout!')
  listing = buffer.list(root, { reuse = false, open_in = 'new' })
  if not listing then error('save setup list failed for ' .. label) end
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local rename_row
  for index, line in ipairs(lines) do
    if line == 'rename-source.txt' then
      rename_row = index
      break
    end
  end
  if not rename_row then error('rename source not visible for ' .. label) end
  vim.api.nvim_buf_set_text(bufnr, rename_row - 1, 0, rename_row - 1, #lines[rename_row], {
    'rename-target.txt',
  })
  local save_ms, saved, save_err = elapsed_ms(function() return listing:sync() end)
  if not saved then error('rename save failed for ' .. label .. ': ' .. tostring(save_err)) end
  if not vim.uv.fs_lstat(vim.fs.joinpath(root, 'rename-target.txt')) then
    error('rename target missing after save for ' .. label)
  end

  vim.cmd('bwipeout!')
  return {
    label = label,
    first_list_ms = first_ms,
    relist_ms = relist_ms,
    expand_all_ms = expand_ms,
    rename_save_ms = save_ms,
    expanded_rows = expanded_rows,
  }
end

local function os_description()
  local uname = vim.uv.os_uname()
  return table.concat({ uname.sysname, uname.release, uname.machine }, ' ')
end

local function cpu_description()
  local ok, cpus = pcall(vim.uv.cpu_info)
  if ok and cpus and cpus[1] and cpus[1].model then return cpus[1].model end
  return 'unknown CPU'
end

local function main()
  setup_runtime()
  local version = vim.version()
  local nvim_version = string.format('%d.%d.%d', version.major, version.minor, version.patch)
  local git_version = run({ 'git', '--version' }):gsub('%s+$', '')
  local sample_count = tonumber(vim.env.DIRECT_LISTING_SAMPLES) or 3
  local sizes = { 1000, 10000, 50000 }
  local result_rows = {}
  local sample_data = {}

  io.write(
    string.format(
      'Environment: %s; CPU %s; Neovim %s; %s; samples=%d; Git status/icons disabled; respect_gitignore toggled\n',
      os_description(),
      cpu_description(),
      nvim_version,
      git_version,
      sample_count
    )
  )

  for _, kind in ipairs({ 'flat', 'deep' }) do
    for _, git_enabled in ipairs({ false, true }) do
      local repeats = sample_count
      for sample = 1, repeats do
        for _, count in ipairs(kind == 'flat' and sizes or { 0 }) do
          local label = kind == 'flat'
              and string.format('%s-%dk-gitignore-%s-s%d', kind, count / 1000, git_enabled and 'on' or 'off', sample)
            or string.format('%s-gitignore-%s-s%d', kind, git_enabled and 'on' or 'off', sample)
          local fixture = vim.fs.joinpath(temp_root, label)
          if kind == 'flat' then
            create_flat(fixture, count, git_enabled)
          else
            create_deep(fixture, git_enabled)
          end
          local row = measure_case(label, fixture, git_enabled)
          row.kind = kind
          row.count = count
          row.gitignore = git_enabled
          row.sample = sample
          result_rows[#result_rows + 1] = row
        end
      end
    end
  end

  io.write('\nRaw samples (milliseconds):\n')
  io.write('case | first list | re-list | zR full expansion | one-rename save | expanded rows\n')
  for _, row in ipairs(result_rows) do
    io.write(
      string.format(
        '%s | %s | %s | %s | %s | %d\n',
        row.label,
        format_ms(row.first_list_ms),
        format_ms(row.relist_ms),
        format_ms(row.expand_all_ms),
        format_ms(row.rename_save_ms),
        row.expanded_rows
      )
    )
    local key = table.concat({ row.kind, tostring(row.count), tostring(row.gitignore) }, ':')
    sample_data[key] = sample_data[key] or { first = {}, relist = {}, expand = {}, save = {} }
    local values = sample_data[key]
    values.first[#values.first + 1] = row.first_list_ms
    values.relist[#values.relist + 1] = row.relist_ms
    values.expand[#values.expand + 1] = row.expand_all_ms
    values.save[#values.save + 1] = row.rename_save_ms
  end

  io.write('\nMedians (milliseconds):\n')
  io.write('fixture | Git-ignore | first list | re-list | zR full expansion | one-rename save\n')
  for _, kind in ipairs({ 'flat', 'deep' }) do
    for _, count in ipairs(kind == 'flat' and sizes or { 0 }) do
      for _, git_enabled in ipairs({ false, true }) do
        local key = table.concat({ kind, tostring(count), tostring(git_enabled) }, ':')
        local values = sample_data[key]
        io.write(
          string.format(
            '%s%s | %s | %s | %s | %s | %s\n',
            kind,
            kind == 'flat' and ('-' .. count) or '',
            git_enabled and 'on' or 'off',
            format_ms(median(values.first)),
            format_ms(median(values.relist)),
            format_ms(median(values.expand)),
            format_ms(median(values.save))
          )
        )
      end
    end
  end

  local budget = tonumber(vim.env.DIRECT_LISTING_BUDGET_MS) or 300
  local gitignore_budget = tonumber(vim.env.DIRECT_LISTING_GITIGNORE_BUDGET_MS) or 750
  local no_git = sample_data['flat:10000:false']
  local measured = median(no_git.first)
  local gitignore_measured = median(sample_data['flat:10000:true'].first)
  io.write(
    string.format(
      '\nLISTING_BUDGET_IGNORE_OFF=%s; measured flat-10000 first-list median=%s; budget=%s\n',
      measured <= budget and 'within' or 'exceeded',
      format_ms(measured),
      format_ms(budget)
    )
  )
  io.write(
    string.format(
      'LISTING_BUDGET_IGNORE_ON=%s; measured flat-10000 first-list median=%s; budget=%s\n',
      gitignore_measured <= gitignore_budget and 'within' or 'exceeded',
      format_ms(gitignore_measured),
      format_ms(gitignore_budget)
    )
  )
end

local ok, err = xpcall(main, debug.traceback)
pcall(vim.fs.rm, temp_root, { recursive = true, force = true })
if not ok then
  io.stderr:write(tostring(err) .. '\n')
  os.exit(1)
end
