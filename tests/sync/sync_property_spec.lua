-- Deterministic generated edit sequences checked against an independent tree model.
-- Seeds 1 and 2 pin the swap/move undo regressions; seed 20 pins a grouped-move
-- apply failure involving a six-name permutation, companion move, and delete.
local H = require('tests.support.harness')
local sync_helpers = require('tests.support.sync_helpers').new()

local SEED_COUNT = 200
local GENERATED_FAMILIES = {
  'permutation',
  'cross-folder move',
  'delete',
  'create',
  'paste',
}
local REGRESSION_CASES = {
  [1] = {
    name = 'minimized swap + cross-folder move',
    minimized = true,
    root_count = 2,
    permutation_count = 2,
    shift = 1,
    left_count = 1,
    right_count = 1,
    move_index = 1,
    family = 'minimized',
    include_move = true,
  },
  [2] = {
    name = 'five-name permutation + cross-folder move',
    root_count = 6,
    permutation_count = 5,
    shift = 3,
    left_count = 2,
    right_count = 4,
    move_index = 2,
    family = 'separate-delete-create',
    include_move = true,
    include_paste = true,
  },
  [20] = {
    name = 'permutation + cross-folder move + delete',
    root_count = 6,
    permutation_count = 6,
    shift = 1,
    left_count = 3,
    right_count = 1,
    move_index = 3,
    family = 'delete-composite',
    include_move = true,
    delete_in_sync = true,
    delete_index = 6,
    minimized_sync_failure = true,
  },
}

local function generator(seed)
  local state = seed
  return function(maximum)
    state = (state * 48271) % 2147483647
    return (state % maximum) + 1
  end
end

local function make_case(seed)
  local random = generator(seed)
  local regression = REGRESSION_CASES[seed]
  local minimized = regression ~= nil and regression.minimized == true
  local family = regression and regression.family or GENERATED_FAMILIES[((seed - 3) % #GENERATED_FAMILIES) + 1]
  local root_count = regression and regression.root_count or (family == 'permutation' and 2 or (1 + random(2)))
  local names, root_files = {}, {}
  for index = 1, root_count do
    local name = string.format('root-%02d.txt', index)
    names[index] = name
    root_files[name] = {
      string.format('seed=%d root=%d', seed, index),
      string.format('payload=%d', random(1000000)),
    }
  end

  local permutation_count = regression and regression.permutation_count or (family == 'permutation' and 2 or 0)
  local shift = regression and regression.shift or (permutation_count > 0 and random(permutation_count - 1) or 0)
  local left_count = regression and regression.left_count or 1
  local right_count = regression and regression.right_count or 1
  local left_files, right_files = {}, {}
  for index = 1, left_count do
    local name = string.format('left-%d.txt', index)
    local contents = {
      string.format('seed=%d left=%d', seed, index),
      string.format('payload=%d', random(1000000)),
    }
    left_files[name] = contents
  end
  for index = 1, right_count do
    local name = string.format('right-%d.txt', index)
    local contents = {
      string.format('seed=%d right=%d', seed, index),
      string.format('payload=%d', random(1000000)),
    }
    right_files[name] = contents
  end

  return {
    seed = seed,
    minimized = minimized,
    regression_name = regression and regression.name or nil,
    family = family,
    include_move = regression and regression.include_move == true or family == 'cross-folder move',
    delete_in_sync = regression and regression.delete_in_sync == true or family == 'delete',
    create_in_sync = family == 'create',
    include_paste = regression and regression.include_paste == true or family == 'paste',
    minimized_sync_failure = regression and regression.minimized_sync_failure == true,
    root_names = names,
    root_files = root_files,
    permutation_count = permutation_count,
    shift = shift,
    left_files = left_files,
    right_files = right_files,
    move_name = 'left-' .. (regression and regression.move_index or random(left_count)) .. '.txt',
    delete_name = names[regression and regression.delete_index or random(root_count)],
    create_name = string.format('created-%d.txt', seed),
    paste_name = string.format('pasted-%d.txt', seed),
    paste_contents = {
      string.format('seed=%d pasted', seed),
      string.format('payload=%d', random(1000000)),
    },
  }
end

local function copy_files(files)
  local copy = {}
  for path, contents in pairs(files) do
    copy[path] = vim.deepcopy(contents)
  end
  return copy
end

local function expected_after_sync(case, initial)
  local files = copy_files(initial)
  if case.permutation_count > 0 then
    local old_root_files = {}
    for index = 1, case.permutation_count do
      local source = case.root_names[index]
      old_root_files[index] = files[source]
    end
    for index = 1, case.permutation_count do
      files[case.root_names[index]] = nil
    end
    for index = 1, case.permutation_count do
      local target = case.root_names[((index - 1 + case.shift) % case.permutation_count) + 1]
      files[target] = old_root_files[index]
    end
  end

  if case.include_move then
    local moved_path = 'left/' .. case.move_name
    files['right/' .. case.move_name] = files[moved_path]
    files[moved_path] = nil
  end
  if case.delete_in_sync then files[case.delete_name] = nil end
  if case.create_in_sync then files[case.create_name] = {} end
  return files
end

local function delete_model_entry(files, name)
  local result = copy_files(files)
  result[name] = nil
  return result
end

local function create_model_entry(files, name)
  local result = copy_files(files)
  result[name] = {}
  return result
end

local function row_index(lines, wanted)
  for index, line in ipairs(lines) do
    if line == wanted then return index end
  end
  return nil
end

local function assert_tree(root, files, directories, label)
  local expected_paths = {}
  for _, directory in ipairs(directories) do
    expected_paths[#expected_paths + 1] = directory .. '/'
  end
  for path in pairs(files) do
    expected_paths[#expected_paths + 1] = path
  end
  table.sort(expected_paths)
  H.assert_eq(H.fs_snapshot(root), expected_paths, label .. ': paths and entry kinds')
  for path, contents in pairs(files) do
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(root, path)), contents, label .. ': contents at ' .. path)
  end
end

local function history_records(lines)
  local records = {}
  local format = require('direct.history.format')
  for _, line in ipairs(lines) do
    if line ~= format.HEADER then records[#records + 1] = line end
  end
  return records
end

local function assert_history_round_trips(lines, label, first_record)
  local action = require('direct.action.action')
  local format = require('direct.history.format')
  local records = history_records(lines)
  H.assert_true(#records > 0, label .. ': generated history contains action records')
  for index = first_record or 1, #records do
    local line = records[index]
    local parsed, parse_err = action.deserialize(line)
    H.assert_not_nil(parsed, label .. ': history record ' .. index .. ' parses: ' .. tostring(parse_err))
    local encoded, encode_err = action.serialize(parsed)
    H.assert_eq(encoded, line, label .. ': history record ' .. index .. ' round-trips: ' .. tostring(encode_err))
  end
  local classified = format.classify(table.concat(lines, '\n') .. '\n', true)
  H.assert_eq(classified.state, 'current', label .. ': generated history is a valid current format')
end

local function install_initial_tree(root, case)
  H.mkdir(root, 'left')
  H.mkdir(root, 'right')
  for name, contents in pairs(case.root_files) do
    H.mkfile(root, name, contents)
  end
  for name, contents in pairs(case.left_files) do
    H.mkfile(root, 'left/' .. name, contents)
  end
  for name, contents in pairs(case.right_files) do
    H.mkfile(root, 'right/' .. name, contents)
  end
end

local function expand_directories(listing)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local left_row = row_index(lines, 'left/')
  H.assert_not_nil(left_row, 'generated tree lists left/')
  H.assert_true(listing:expand(left_row), 'generated tree expands left/')

  lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local right_row = row_index(lines, 'right/')
  H.assert_not_nil(right_row, 'generated tree lists right/')
  H.assert_true(listing:expand(right_row), 'generated tree expands right/')
end

local function apply_generated_permutation_and_move(case)
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Rotate a bounded subset of root names in place. The identity marks stay
  -- with their rows, so the model can independently track each file's bytes.
  if case.permutation_count > 0 then
    for index = 1, case.permutation_count do
      local source = case.root_names[index]
      local target = case.root_names[((index - 1 + case.shift) % case.permutation_count) + 1]
      local row = row_index(lines, source)
      H.assert_not_nil(row, 'generated permutation source is visible: ' .. source)
      vim.api.nvim_buf_set_text(bufnr, row - 1, 0, row - 1, #source, { target })
    end
  end

  if case.include_move then
    -- Move a child row from left/ to right/ using the listing's tree ordering.
    -- The name is unique across both folders in this generator.
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local source_row = row_index(lines, '  ' .. case.move_name)
    local right_row = row_index(lines, 'right/')
    H.assert_not_nil(source_row, 'generated move source is visible')
    H.assert_not_nil(right_row, 'generated move target folder is visible')
    local target_last_row = right_row
    for index = right_row + 1, #lines do
      if lines[index]:sub(1, 2) ~= '  ' then break end
      target_last_row = index
    end
    H.assert_true(source_row < target_last_row, 'generated cross-folder move has a later destination')
    vim.cmd(string.format('%dmove %d', source_row, target_last_row))
  end

  if case.delete_in_sync then
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local delete_row = row_index(lines, case.delete_name)
    H.assert_not_nil(delete_row, 'generated delete source is visible: ' .. case.delete_name)
    vim.api.nvim_buf_set_lines(bufnr, delete_row - 1, delete_row, false, {})
  elseif case.create_in_sync then
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { case.create_name })
  end
end

local function delete_generated_entry(case)
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local row = row_index(lines, case.delete_name)
  H.assert_not_nil(row, 'generated delete source is visible: ' .. case.delete_name)
  vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, {})
end

local function create_generated_entry(case)
  vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), -1, -1, false, { case.create_name })
end

local function run_seed(seed)
  local case = make_case(seed)
  local sandbox = H.sandbox()
  local root = H.mkdir(sandbox.root, 'generated-' .. seed)
  local directories = { 'left', 'right' }
  install_initial_tree(root, case)
  local initial = copy_files(case.root_files)
  for name, contents in pairs(case.left_files) do
    initial['left/' .. name] = vim.deepcopy(contents)
  end
  for name, contents in pairs(case.right_files) do
    initial['right/' .. name] = vim.deepcopy(contents)
  end
  local expected_sync = expected_after_sync(case, initial)
  local operations
  if case.minimized then
    operations = 'swap=root-01.txt<->root-02.txt; move=left/' .. case.move_name .. ' -> right/' .. case.move_name
  elseif case.minimized_sync_failure then
    operations = string.format(
      'rotate 6 root names by 1; move=left/%s -> right/%s; delete=%s',
      case.move_name,
      case.move_name,
      case.delete_name
    )
  elseif case.family == 'separate-delete-create' then
    operations = string.format(
      'permute=%d shift=%d; move=left/%s -> right/%s; delete=%s; create=%s; paste=%s',
      case.permutation_count,
      case.shift,
      case.move_name,
      case.move_name,
      case.delete_name,
      case.create_name,
      case.paste_name
    )
  elseif case.family == 'permutation' then
    operations = string.format('permute=%d shift=%d', case.permutation_count, case.shift)
  elseif case.family == 'cross-folder move' then
    operations = 'move=left/' .. case.move_name .. ' -> right/' .. case.move_name
  elseif case.family == 'delete' then
    operations = 'delete=' .. case.delete_name
  elseif case.family == 'create' then
    operations = 'create=' .. case.create_name
  elseif case.family == 'paste' then
    operations = 'paste=' .. case.paste_name .. ' into right/'
  else
    operations = case.family
  end
  local regression = case.regression_name and (' regression=' .. case.regression_name) or ''
  local label = string.format('seed=%d%s [%s]', seed, regression, operations)

  assert_tree(root, initial, directories, label .. ' initial')
  local history = require('direct.history.history')
  local register = require('direct.register')
  local history_before_count = #history_records(sync_helpers.history_lines('undo.log'))
  local sync_steps = {}
  local listing

  if case.family ~= 'paste' then
    local buffer = require('direct.buffer.buffer')
    listing = buffer.list(root)
    expand_directories(listing)
    apply_generated_permutation_and_move(case)

    local synced, sync_err = listing:sync()
    H.assert_true(synced == true, label .. ': sync succeeds: ' .. tostring(sync_err))
    H.wait_for_direct()
    assert_tree(root, expected_sync, directories, label .. ' after sync')
    sync_steps[#sync_steps + 1] = { name = 'sync', files = expected_sync }
  end

  if case.minimized or case.minimized_sync_failure then
    assert_history_round_trips(sync_helpers.history_lines('undo.log'), label, history_before_count + 1)
    H.assert_not_nil(history.undo(), label .. ': undo the generated sync')
    H.wait_for_direct()
    assert_tree(root, initial, directories, label .. ' after undo generated sync')
    H.assert_not_nil(history.redo(), label .. ': redo the generated sync')
    H.wait_for_direct()
    assert_tree(root, expected_sync, directories, label .. ' after redo generated sync')
    return
  end

  local expected_after_edits = expected_sync
  if case.family == 'separate-delete-create' then
    local expected_delete = delete_model_entry(expected_sync, case.delete_name)
    expected_after_edits = create_model_entry(expected_delete, case.create_name)

    delete_generated_entry(case)
    local deleted, delete_err = listing:sync()
    H.assert_true(deleted == true, label .. ': delete sync succeeds: ' .. tostring(delete_err))
    H.wait_for_direct()
    assert_tree(root, expected_delete, directories, label .. ' after delete')
    sync_steps[#sync_steps + 1] = { name = 'delete sync', files = expected_delete }

    create_generated_entry(case)
    local created, create_err = listing:sync()
    H.assert_true(created == true, label .. ': create sync succeeds: ' .. tostring(create_err))
    H.wait_for_direct()
    assert_tree(root, expected_after_edits, directories, label .. ' after create')
    sync_steps[#sync_steps + 1] = { name = 'create sync', files = expected_after_edits }
  end

  local expected_final = copy_files(expected_after_edits)
  if case.include_paste then
    local source = H.mkfile(sandbox.root, case.paste_name, case.paste_contents)
    H.assert_true(register.yank({ source }) == true, label .. ': paste source is yanked')
    local pasted, paste_err = register.paste(vim.fs.joinpath(root, 'right') .. '/')
    H.assert_not_nil(pasted, label .. ': paste succeeds: ' .. tostring(paste_err))
    H.wait_for_direct()
    expected_final['right/' .. case.paste_name] = vim.deepcopy(case.paste_contents)
    sync_steps[#sync_steps + 1] = { name = 'paste', files = expected_final }
  end
  assert_tree(root, expected_final, directories, label .. ' after generated operation')

  local history_lines = sync_helpers.history_lines('undo.log')
  local new_records = history_records(history_lines)
  H.assert_true(
    #new_records >= history_before_count + #sync_steps,
    label .. ': each generated operation adds a history record'
  )
  assert_history_round_trips(history_lines, label, history_before_count + 1)

  for index = #sync_steps, 1, -1 do
    H.assert_not_nil(history.undo(), label .. ': undo ' .. sync_steps[index].name)
    H.wait_for_direct()
    local expected = index == 1 and initial or sync_steps[index - 1].files
    assert_tree(root, expected, directories, label .. ': after undo ' .. sync_steps[index].name)
  end

  for _, step in ipairs(sync_steps) do
    H.assert_not_nil(history.redo(), label .. ': redo ' .. step.name)
    H.wait_for_direct()
    assert_tree(root, step.files, directories, label .. ': after redo ' .. step.name)
  end
end

H.describe('sync: generated edit model', function()
  H.it('matches a seeded filesystem model through sync, undo, redo, paste, and history round trips', function()
    local original_notify = vim.notify
    local started_at = vim.uv.hrtime()
    local attempted = 0
    vim.notify = function() end
    local ok, err = xpcall(function()
      local known_regression_failures = {}
      for seed = 1, SEED_COUNT do
        attempted = seed
        sync_helpers.clean_buffers()
        local seed_ok, seed_err = xpcall(function() run_seed(seed) end, debug.traceback)
        if not seed_ok then
          local failure = string.format('generated edit sequence failed: seed=%d\n%s', seed, tostring(seed_err))
          if REGRESSION_CASES[seed] then
            known_regression_failures[#known_regression_failures + 1] = failure
            if seed == 20 then
              error(
                'known generated regression seeds failed:\n\n' .. table.concat(known_regression_failures, '\n\n'),
                0
              )
            end
          else
            error(failure, 0)
          end
        end
      end
      if #known_regression_failures > 0 then
        error('known generated regression seeds failed:\n\n' .. table.concat(known_regression_failures, '\n\n'), 0)
      end
    end, debug.traceback)
    vim.notify = original_notify
    local elapsed = (vim.uv.hrtime() - started_at) / 1000000000
    local runtime_budget = vim.env.DIRECT_COVERAGE == '1' and 150 or 90
    io.write(
      string.format(
        '\n[runtime] sync_property_spec: %.2fs (%d/%d seeds, budget %.0fs)\n',
        elapsed,
        attempted,
        SEED_COUNT,
        runtime_budget
      )
    )
    if not ok then error(err, 0) end
    H.assert_true(
      elapsed < runtime_budget,
      string.format('property spec exceeded %ds runtime budget: %.2fs', runtime_budget, elapsed)
    )
  end)
end)
