-- Exercise history recovery across real Neovim process exits. Each checkpoint
-- gets its own throwaway workspace and data directory.
local H = require('tests.support.harness')

local function read_bytes(path)
  local file = io.open(path, 'rb')
  if not file then return nil end
  local bytes = file:read('*a')
  file:close()
  return bytes
end

local function snapshot_tree(root)
  local snapshot = {}
  local function visit(directory, relative)
    local entries = {}
    for name, kind in vim.fs.dir(directory) do
      entries[#entries + 1] = { name = name, kind = kind }
    end
    table.sort(entries, function(a, b) return a.name < b.name end)
    for _, entry in ipairs(entries) do
      local path = vim.fs.joinpath(directory, entry.name)
      local child = relative == '' and entry.name or (relative .. '/' .. entry.name)
      if entry.kind == 'directory' then
        snapshot[child .. '/'] = true
        visit(path, child)
      else
        snapshot[child] = read_bytes(path)
      end
    end
  end
  visit(root, '')
  return snapshot
end

local function history_paths(sb)
  local directory = vim.fs.joinpath(sb.data_home, 'direct', 'history')
  return {
    undo = vim.fs.joinpath(directory, 'undo.log'),
    redo = vim.fs.joinpath(directory, 'redo.log'),
    transaction = vim.fs.joinpath(directory, 'transaction.json'),
  }
end

local function history_snapshot(sb)
  local paths = history_paths(sb)
  return {
    undo = vim.fn.readfile(paths.undo),
    redo = vim.fn.readfile(paths.redo),
    transaction = read_bytes(paths.transaction),
  }
end

local function fixture_snapshot(fixture)
  local result = {
    workspace = snapshot_tree(fixture.workspace),
    history = history_snapshot(fixture.sb),
  }
  if fixture.source then result.source = snapshot_tree(fixture.source) end
  return result
end

local function serialized(action)
  local record, err = require('direct.action.action').serialize(action)
  H.assert_not_nil(record, tostring(err))
  return record
end

local function fresh_fixture(kind)
  local sb = H.sandbox()
  local config = require('direct.config')
  local action = require('direct.action.action')
  local history = require('direct.history.history')
  local fs = require('direct.fs')
  config.setup({ trash_retention = false, undo_confirm = false })

  local workspace = H.mkdir(sb.root, 'workspace')
  H.mkfile(workspace, 'protected.txt', { 'DO-NOT-OVERWRITE' })
  local fixture = { sb = sb, workspace = workspace, kind = kind }
  H.assert_not_nil(history.preflight(), kind .. ': initialize clean history')

  if kind == 'save' then
    fixture.action = action.Touch(workspace .. '/saved.txt')
  elseif kind == 'grouped swap' then
    H.mkfile(workspace, 'a.txt', { 'CONTENT-A' })
    H.mkfile(workspace, 'b.txt', { 'CONTENT-B' })
    fixture.action = action.Group({
      action.Move(workspace .. '/a.txt', workspace .. '/b.txt'),
      action.Move(workspace .. '/b.txt', workspace .. '/a.txt'),
    })
  elseif kind == 'paste' then
    local source = H.mkdir(sb.root, 'source')
    local source_file = H.mkfile(source, 'copy.txt', { 'COPY-THIS-CONTENT' })
    fixture.source = source
    fixture.destination_file = workspace .. '/copy.txt'
    fixture.source_file = source_file
    local register = require('direct.register')
    H.assert_true(register.yank({ source_file }) == true, 'paste: prepare register contents')
    fixture.register_dir = register.content()
    fixture.action = action.Paste(fixture.register_dir, workspace, { 'copy.txt' }, { 'copy.txt' })
  elseif kind == 'undo' or kind == 'redo' then
    H.mkfile(workspace, 'draft.txt', { 'PRESERVE-ME' })
    fixture.action = action.Move(workspace .. '/draft.txt', workspace .. '/saved.txt')
    H.assert_not_nil(
      history.apply(fixture.action, function() return fixture.action['do']() end),
      kind .. ': prepare committed move'
    )
    if kind == 'redo' then H.assert_not_nil(history.undo(), 'redo: prepare an undoable move') end
  elseif kind == 'replay' then
    H.mkfile(workspace, 'draft.txt', { 'PRESERVE-ME' })
    fixture.action = action.Move(workspace .. '/draft.txt', workspace .. '/saved.txt')
    H.assert_not_nil(
      history.apply(fixture.action, function() return fixture.action['do']() end),
      'replay: prepare the forward move'
    )
    H.assert_not_nil(history.undo(), 'replay: prepare an undone move')

    local paths = require('direct.paths')
    local source_path = workspace .. '/draft.txt'
    local destination_path = workspace .. '/saved.txt'
    local source_identity = assert(fs.entry_identity(source_path))
    local reversal = action.Move(source_path, destination_path)
    local record = serialized(reversal)
    H.assert_not_nil(reversal['do'](), 'replay: land the filesystem operation before stack commit')
    local transaction = require('direct.history.transaction')
    local journal = vim.json.encode({
      format = transaction.FORMAT,
      version = transaction.VERSION,
      kind = 'reverse',
      direction = 'redo',
      undo = { transaction.HEADER, serialized(fixture.action) },
      redo = { transaction.HEADER },
      action = record,
      source = paths.record_path(source_path),
      destination = paths.record_path(destination_path),
      source_identity = source_identity,
      destination_identity = vim.NIL,
    }) .. '\n'
    H.assert_true(
      require('direct.log').write_raw_atomic(history_paths(sb).transaction, journal) == true,
      'replay: persist the landed operation before its paired stack commit'
    )
  else
    H.fail('unknown crash-recovery fixture: ' .. tostring(kind))
  end

  fixture.before = fixture_snapshot(fixture)
  fixture.after = vim.deepcopy(fixture.before)
  fixture.expected = {}

  if kind == 'save' then
    fixture.after.workspace['saved.txt'] = ''
    fixture.expected.undo = { require('direct.history.format').HEADER, serialized(fixture.action) }
    fixture.expected.redo = { require('direct.history.format').HEADER }
  elseif kind == 'grouped swap' then
    fixture.after.workspace['a.txt'] = fixture.before.workspace['b.txt']
    fixture.after.workspace['b.txt'] = fixture.before.workspace['a.txt']
    fixture.expected.undo = { require('direct.history.format').HEADER, serialized(fixture.action) }
    fixture.expected.redo = { require('direct.history.format').HEADER }
  elseif kind == 'paste' then
    fixture.after.workspace['copy.txt'] = 'COPY-THIS-CONTENT\n'
    fixture.expected.source = vim.deepcopy(fixture.before.source)
    fixture.expected.undo = { require('direct.history.format').HEADER, serialized(fixture.action) }
    fixture.expected.redo = { require('direct.history.format').HEADER }
  elseif kind == 'undo' then
    fixture.after.workspace['draft.txt'] = fixture.before.workspace['saved.txt']
    fixture.after.workspace['saved.txt'] = nil
    fixture.expected.undo = { require('direct.history.format').HEADER }
    fixture.expected.redo = {
      require('direct.history.format').HEADER,
      serialized(action.Move(fixture.workspace .. '/saved.txt', fixture.workspace .. '/draft.txt')),
    }
  elseif kind == 'redo' then
    fixture.after.workspace['saved.txt'] = fixture.before.workspace['draft.txt']
    fixture.after.workspace['draft.txt'] = nil
    fixture.expected.undo = {
      require('direct.history.format').HEADER,
      serialized(fixture.action),
    }
    fixture.expected.redo = { require('direct.history.format').HEADER }
  elseif kind == 'replay' then
    fixture.expected.undo = {
      require('direct.history.format').HEADER,
      serialized(fixture.action),
    }
    fixture.expected.redo = { require('direct.history.format').HEADER }
  end
  fixture.after.history = {
    undo = fixture.expected.undo,
    redo = fixture.expected.redo,
    transaction = nil,
  }
  return fixture
end

local OPERATION_SCRIPT = [[
local root = assert(vim.env.DIRECT_TEST_ROOT)
package.path = root .. '/lua/?.lua;' .. root .. '/?.lua;' .. package.path

local history = require('direct.history.history')
local action = require('direct.action.action')
local kind = assert(vim.env.DIRECT_TEST_SCENARIO)
local workspace = assert(vim.env.DIRECT_TEST_WORKSPACE)

local function must(result, err)
  if result == nil or result == false then error(tostring(err or 'operation failed'), 0) end
end

if kind == 'save' then
  vim.opt.runtimepath:prepend(root)
  vim.cmd('runtime! plugin/direct.lua')
  require('direct').list(workspace)
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  lines[#lines + 1] = 'saved.txt'
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.cmd('write')
  local pending = require('direct.pending')
  if not vim.wait(15000, function()
      return not pending.is_pending() and not history.pending.is_pending()
    end, 10)
  then
    error('Direct listing :write did not settle before timeout', 0)
  end
elseif kind == 'grouped swap' then
  local swap = action.Group({
    action.Move(workspace .. '/a.txt', workspace .. '/b.txt'),
    action.Move(workspace .. '/b.txt', workspace .. '/a.txt'),
  })
  must(history.apply(swap, function() error('the persisted grouped plan must execute') end))
elseif kind == 'paste' then
  local register = require('direct.register')
  local done, succeeded, result_err = false, false, nil
  local started, start_err = register.paste(workspace, nil, function(_, err, ok)
    done, succeeded, result_err = true, ok == true, err
  end)
  must(started, start_err)
  if not vim.wait(15000, function() return done end, 10) then
    error('paste did not settle before timeout', 0)
  end
  if not succeeded then error(tostring(result_err or 'paste failed'), 0) end
elseif kind == 'undo' then
  must(history.undo())
elseif kind == 'redo' then
  must(history.redo())
elseif kind == 'replay' then
  local state, err = history.preflight()
  must(state, err)
else
  error('unknown crash scenario: ' .. tostring(kind), 0)
end
io.stdout:write('DIRECT-OP-OK\n')
]]

local RECOVERY_SCRIPT = [[
local root = assert(vim.env.DIRECT_TEST_ROOT)
package.path = root .. '/lua/?.lua;' .. root .. '/?.lua;' .. package.path

local history = require('direct.history.history')
local workspace = assert(vim.env.DIRECT_TEST_WORKSPACE)
local data_home = assert(vim.env.XDG_DATA_HOME)
local report_path = assert(vim.env.DIRECT_TEST_REPORT)

local function tree(directory, relative, output)
  local entries = {}
  for name, kind in vim.fs.dir(directory) do
    entries[#entries + 1] = { name = name, kind = kind }
  end
  table.sort(entries, function(a, b) return a.name < b.name end)
  for _, entry in ipairs(entries) do
    local path = vim.fs.joinpath(directory, entry.name)
    local child = relative == '' and entry.name or (relative .. '/' .. entry.name)
    if entry.kind == 'directory' then
      output[child .. '/'] = true
      tree(path, child, output)
    else
      local file = assert(io.open(path, 'rb'))
      output[child] = file:read('*a')
      file:close()
    end
  end
end

local function bytes(path)
  local file = io.open(path, 'rb')
  if not file then return nil end
  local value = file:read('*a')
  file:close()
  return value
end

local history_dir = vim.fs.joinpath(data_home, 'direct', 'history')
local function snapshot()
  local filesystem = {}
  tree(workspace, '', filesystem)
  local logs = {}
  for _, name in ipairs({ 'undo.log', 'redo.log', 'transaction.json' }) do
    logs[name] = bytes(vim.fs.joinpath(history_dir, name))
  end
  return { filesystem = filesystem, history = logs }
end

local function preflight()
  local called, state, err = pcall(history.preflight)
  local result = { ok = called and state ~= nil }
  if not called then
    result.error = tostring(state)
  elseif not state then
    result.error = tostring(err)
  end
  return result
end

local first = preflight()
local first_snapshot = snapshot()
local second = preflight()
local second_snapshot = snapshot()
local report = {
  first = first,
  second = second,
  first_snapshot = first_snapshot,
  second_snapshot = second_snapshot,
  stable = vim.deep_equal(first_snapshot, second_snapshot),
}
local file = assert(io.open(report_path, 'wb'))
file:write(vim.json.encode(report), '\n')
file:close()
io.stdout:write('DIRECT-RECOVERY-OK\n')
]]

local function write_script(sb, name, contents)
  local path = vim.fs.joinpath(sb.root, name)
  local file = assert(io.open(path, 'wb'))
  file:write(contents)
  file:close()
  return path
end

local function run_process(script, fixture, options)
  options = options or {}
  local timeout_ms = 30000
  local env = {
    XDG_DATA_HOME = fixture.sb.data_home,
    DIRECT_TEST_ROOT = vim.fn.getcwd(),
    DIRECT_TEST_SCENARIO = fixture.kind,
    DIRECT_TEST_WORKSPACE = fixture.workspace,
    DIRECT_TEST_CRASH_AT = options.crash_at or '',
    DIRECT_TEST_CRASH_TRACE = options.trace_path or '',
  }
  if options.report_path then env.DIRECT_TEST_REPORT = options.report_path end
  local process = vim.system({ vim.v.progpath, '--headless', '-l', script }, {
    env = env,
    text = true,
  })
  local result = process:wait(timeout_ms)
  if result == nil or result.code == 124 then
    local term_ok, term_err = pcall(function() process:kill('sigterm') end)
    local cleanup = process:wait(5000)
    local force_ok, force_err = true, nil
    if cleanup == nil then
      force_ok, force_err = pcall(function() process:kill('sigkill') end)
      cleanup = process:wait(5000)
    end
    local cleanup_context = cleanup
        and string.format('cleanup exit=%s signal=%s', tostring(cleanup.code), tostring(cleanup.signal))
      or 'child was still running after termination attempts'
    H.fail(
      string.format(
        'Neovim child timed out after %dms (%s); SIGTERM=%s (%s); SIGKILL=%s (%s); ' .. 'stdout=%s; stderr=%s',
        timeout_ms,
        table.concat({ vim.v.progpath, '--headless', '-l', script }, ' '),
        tostring(term_ok),
        tostring(term_err),
        tostring(force_ok),
        tostring(force_err),
        tostring(cleanup and cleanup.stdout or (result and result.stdout)),
        tostring(cleanup and cleanup.stderr or (result and result.stderr))
      )
        .. '; '
        .. cleanup_context
    )
  end
  return result
end

local function trace_labels(path)
  local bytes = read_bytes(path)
  if bytes == nil then return {} end
  local lines = vim.split(bytes, '\n', { trimempty = true })
  local seen, unique = {}, {}
  for _, label in ipairs(lines) do
    local valid = label:match('^journal%.before%.%d+$')
      or label:match('^journal%.after%.%d+$')
      or label:match('^filesystem%.before_stack_commit%.%d+$')
      or label:match('^stack%.before_undo_write%.%d+$')
      or label:match('^stack%.after_undo_write%.%d+$')
      or label:match('^stack%.before_redo_write%.%d+$')
      or label:match('^stack%.after_redo_write%.%d+$')
    H.assert_true(valid ~= nil, 'crash trace uses the agreed checkpoint label: ' .. label)
    H.assert_false(seen[label] == true, 'checkpoint ordinal is unique in this process: ' .. label)
    seen[label] = true
    unique[#unique + 1] = label
  end
  return unique
end

local function checkpoints_for(labels)
  local uname = vim.uv.os_uname()
  if uname and uname.sysname == 'Linux' then return labels end

  -- macOS and Windows exercise one observed point per hook family, including
  -- both sides of each atomic stack write, without replaying every ordinal.
  local wanted = {
    'journal.before.',
    'journal.after.',
    'filesystem.before_stack_commit.',
    'stack.before_undo_write.',
    'stack.after_undo_write.',
    'stack.before_redo_write.',
    'stack.after_redo_write.',
  }
  local selected, used = {}, {}
  for _, prefix in ipairs(wanted) do
    for _, label in ipairs(labels) do
      if label:sub(1, #prefix) == prefix and not used[label] then
        used[label] = true
        selected[#selected + 1] = label
        break
      end
    end
  end
  return selected
end

local function expected_before_for(kind, label)
  if label == 'journal.before.1' then return kind ~= 'replay' end
  if kind == 'paste' then
    -- The pending-copy journal is durable before the file operation. A crash
    -- before its next checkpoint leaves no completed copy to record in history.
    local ordinal = tonumber(label:match('^journal%.%w+%.(%d+)$'))
    if ordinal and ordinal <= 2 then return true end
  end
  return false
end

local function assert_matches_candidate(actual, candidate, label)
  H.assert_eq(actual.filesystem, candidate.workspace, label .. ': workspace has one complete, known state')
  H.assert_eq(actual.history.undo, candidate.history.undo, label .. ': undo stack matches filesystem state')
  H.assert_eq(actual.history.redo, candidate.history.redo, label .. ': redo stack matches filesystem state')
  H.assert_eq(
    actual.history.transaction,
    candidate.history.transaction,
    label .. ': journal is clear or deliberately pending'
  )
end

local function assert_original_contents_preserved(filesystem, fixture, label)
  local contents = {
    save = { 'DO-NOT-OVERWRITE\n' },
    ['grouped swap'] = { 'DO-NOT-OVERWRITE\n', 'CONTENT-A\n', 'CONTENT-B\n' },
    paste = { 'DO-NOT-OVERWRITE\n' },
    undo = { 'DO-NOT-OVERWRITE\n', 'PRESERVE-ME\n' },
    redo = { 'DO-NOT-OVERWRITE\n', 'PRESERVE-ME\n' },
    replay = { 'DO-NOT-OVERWRITE\n', 'PRESERVE-ME\n' },
  }
  local values = {}
  for _, value in pairs(filesystem) do
    if type(value) == 'string' then values[value] = true end
  end
  for _, content in ipairs(contents[fixture.kind]) do
    H.assert_true(values[content] == true, label .. ': original bytes remain present')
  end
end

H.describe('real-process crash and recovery matrix', function()
  H.it('recovers every traced checkpoint without data loss or repeated effects', function()
    local operation_script = write_script(H.sandbox(), 'crash_operation.lua', OPERATION_SCRIPT)
    local recovery_sb = H.sandbox()
    local recovery_script = write_script(recovery_sb, 'crash_recovery.lua', RECOVERY_SCRIPT)
    local scenarios = { 'save', 'grouped swap', 'paste', 'undo', 'redo', 'replay' }

    for _, kind in ipairs(scenarios) do
      local baseline = fresh_fixture(kind)
      local trace_path = vim.fs.joinpath(baseline.sb.root, 'baseline.trace')
      local baseline_result = run_process(operation_script, baseline, { trace_path = trace_path })
      H.assert_eq(
        baseline_result.code,
        0,
        kind .. ': no-crash child succeeds; stderr=' .. tostring(baseline_result.stderr)
      )
      H.assert_true(
        (baseline_result.stdout or ''):find('DIRECT-OP-OK', 1, true) ~= nil,
        kind .. ': no-crash child completed its operation'
      )
      local baseline_state = {
        filesystem = snapshot_tree(baseline.workspace),
        history = history_snapshot(baseline.sb),
      }
      assert_matches_candidate(baseline_state, baseline.after, kind .. ': no-crash baseline')
      local labels = trace_labels(trace_path)
      H.assert_true(#labels > 0, kind .. ': baseline reached crash hook checkpoints')
      local selected = checkpoints_for(labels)
      H.assert_true(#selected > 0, kind .. ': platform selection retains checkpoints')

      for _, checkpoint in ipairs(selected) do
        local fixture = fresh_fixture(kind)
        local crash_trace = vim.fs.joinpath(fixture.sb.root, 'crash.trace')
        local crashed = run_process(operation_script, fixture, {
          crash_at = checkpoint,
          trace_path = crash_trace,
        })
        H.assert_eq(crashed.code, 86, kind .. ' @ ' .. checkpoint .. ': child exited at the injected stop point')
        local reached = false
        for _, label in ipairs(trace_labels(crash_trace)) do
          if label == checkpoint then reached = true end
        end
        H.assert_true(reached, kind .. ' @ ' .. checkpoint .. ': trace confirms the stop point')

        local report_path = vim.fs.joinpath(fixture.sb.root, 'recovery.json')
        local recovered = run_process(recovery_script, fixture, { report_path = report_path })
        H.assert_eq(
          recovered.code,
          0,
          kind .. ' @ ' .. checkpoint .. ': fresh-process recovery completed; stderr=' .. tostring(recovered.stderr)
        )
        local report_bytes = read_bytes(report_path)
        H.assert_not_nil(report_bytes, kind .. ' @ ' .. checkpoint .. ': recovery report exists')
        local report = vim.json.decode(report_bytes)
        H.assert_true(
          report.stable,
          kind .. ' @ ' .. checkpoint .. ': repeated recovery in the fresh process is idempotent'
        )
        H.assert_eq(
          report.first.ok,
          report.second.ok,
          kind .. ' @ ' .. checkpoint .. ': recovery result is stable on retry'
        )

        local actual = {
          filesystem = report.first_snapshot.filesystem,
          history = {
            undo = vim.split(report.first_snapshot.history['undo.log'] or '', '\n', { trimempty = true }),
            redo = vim.split(report.first_snapshot.history['redo.log'] or '', '\n', { trimempty = true }),
            transaction = report.first_snapshot.history['transaction.json'],
          },
        }
        if report.first.ok then
          local expect_before = expected_before_for(kind, checkpoint)
          local candidate = expect_before and fixture.before or fixture.after
          assert_matches_candidate(actual, candidate, kind .. ' @ ' .. checkpoint)
          assert_original_contents_preserved(actual.filesystem, fixture, kind .. ' @ ' .. checkpoint)
          if kind == 'paste' then
            if expect_before then
              H.assert_nil(
                report.first_snapshot.filesystem['copy.txt'],
                kind .. ' @ ' .. checkpoint .. ': no uncommitted copy remains'
              )
            else
              H.assert_eq(
                report.first_snapshot.filesystem['copy.txt'],
                'COPY-THIS-CONTENT\n',
                kind .. ' @ ' .. checkpoint .. ': pasted bytes are complete'
              )
            end
            H.assert_eq(
              report.first_snapshot.filesystem['protected.txt'],
              'DO-NOT-OVERWRITE\n',
              kind .. ' @ ' .. checkpoint .. ': existing destination content was not overwritten'
            )
            H.assert_eq(
              fixture_snapshot(fixture).source['copy.txt'],
              'COPY-THIS-CONTENT\n',
              kind .. ' @ ' .. checkpoint .. ': register source content remains intact'
            )
          end
        else
          local err = report.first.error or ''
          H.assert_true(
            err:find('ambiguous', 1, true) ~= nil
              or err:find('preserved', 1, true) ~= nil
              or err:find('manual', 1, true) ~= nil
              or err:find('incomplete', 1, true) ~= nil,
            kind .. ' @ ' .. checkpoint .. ': refusal explicitly requests recovery/inspection'
          )
          H.assert_not_nil(
            actual.history.transaction,
            kind .. ' @ ' .. checkpoint .. ': refused recovery preserves its journal'
          )
          assert_original_contents_preserved(actual.filesystem, fixture, kind .. ' @ ' .. checkpoint)
          H.assert_eq(
            actual.filesystem['protected.txt'],
            'DO-NOT-OVERWRITE\n',
            kind .. ' @ ' .. checkpoint .. ': refusal leaves existing content intact'
          )
          if fixture.source then
            H.assert_eq(
              fixture_snapshot(fixture).source['copy.txt'],
              'COPY-THIS-CONTENT\n',
              kind .. ' @ ' .. checkpoint .. ': refusal leaves source content intact'
            )
          end
        end
      end
    end
  end)
end)
