-- The row-state module is loadable without buffer.lua assembling a context table.
local H = require('tests.support.harness')

H.describe('standalone buffer row-state module', function()
  H.it('exports row and expansion methods before a Buffer is constructed', function()
    local parent_module = package.loaded['direct.buffer.buffer']
    local row_state_module = package.loaded['direct.buffer.row_state']
    package.loaded['direct.buffer.buffer'] = nil
    package.loaded['direct.buffer.row_state'] = nil
    local loaded, row_state, parent_unloaded = pcall(function()
      local result = require('direct.buffer.row_state')
      return result, package.loaded['direct.buffer.buffer'] == nil
    end)
    package.loaded['direct.buffer.buffer'] = parent_module
    package.loaded['direct.buffer.row_state'] = row_state_module

    H.assert_true(loaded, tostring(row_state))
    H.assert_true(parent_unloaded, 'requiring row_state does not load or construct buffer.lua')
    H.assert_eq(type(row_state), 'table', 'row_state module returns a function table')
    H.assert_eq(type(row_state.expand), 'function', 'expand is exported')
    H.assert_eq(type(row_state.collapse), 'function', 'collapse is exported')
    H.assert_eq(type(row_state.restore_deleted_rows), 'function', 'deleted-row restoration is exported')
    H.assert_eq(type(row_state.attach_deleted_guard), 'function', 'deleted-row guard attachment is exported')
  end)
end)
