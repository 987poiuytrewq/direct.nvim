-- The undo-state module is loadable without buffer.lua assembling a context table.
local H = require('tests.support.harness')

H.describe('standalone buffer undo-state module', function()
  H.it('exports reconciliation before a Buffer is constructed', function()
    local parent_module = package.loaded['direct.buffer.buffer']
    local undo_state_module = package.loaded['direct.buffer.undo_state']
    package.loaded['direct.buffer.buffer'] = nil
    package.loaded['direct.buffer.undo_state'] = nil
    local loaded, undo_state, parent_unloaded = pcall(function()
      local result = require('direct.buffer.undo_state')
      return result, package.loaded['direct.buffer.buffer'] == nil
    end)
    package.loaded['direct.buffer.buffer'] = parent_module
    package.loaded['direct.buffer.undo_state'] = undo_state_module

    H.assert_true(loaded, tostring(undo_state))
    H.assert_true(parent_unloaded, 'requiring undo_state does not load or construct buffer.lua')
    H.assert_eq(type(undo_state), 'table', 'undo_state module returns a function table')
    H.assert_eq(
      type(undo_state.reconcile_undone_materialization),
      'function',
      'materialization reconciliation is exported'
    )
  end)
end)
