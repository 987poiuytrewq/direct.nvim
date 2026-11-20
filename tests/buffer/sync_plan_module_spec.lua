-- The sync planner can be required without buffer.lua assembling a context.
local H = require('tests.support.harness')

H.describe('standalone buffer sync planner', function()
  H.it('exports planner functions before a Buffer is constructed', function()
    local parent_module = package.loaded['direct.buffer.buffer']
    local planner_module = package.loaded['direct.buffer.sync_plan']
    package.loaded['direct.buffer.buffer'] = nil
    package.loaded['direct.buffer.sync_plan'] = nil
    local loaded, planner, parent_unloaded = pcall(function()
      local result = require('direct.buffer.sync_plan')
      return result, package.loaded['direct.buffer.buffer'] == nil
    end)
    package.loaded['direct.buffer.buffer'] = parent_module
    package.loaded['direct.buffer.sync_plan'] = planner_module

    H.assert_true(loaded, tostring(planner))
    H.assert_true(parent_unloaded, 'requiring sync_plan does not load or construct buffer.lua')
    H.assert_eq(type(planner), 'table', 'planner module returns a function table')
    H.assert_eq(type(planner.classify_identity), 'function', 'identity classifier is exported')
    H.assert_eq(type(planner.component_reason), 'function', 'component validator is exported')
    H.assert_eq(type(planner.first_unsafe), 'function', 'unsafe-path finder is exported')
    H.assert_eq(type(planner.ambiguous_message), 'function', 'ambiguity formatter is exported')
    H.assert_eq(type(planner.result_entry), 'function', 'result selector is exported')
    H.assert_eq(type(planner.build_actions), 'function', 'action builder is exported')
    H.assert_eq(type(planner.nested_path_reason), 'function', 'nested-path validator is exported')
  end)
end)
