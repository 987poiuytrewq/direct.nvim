-- The reversal module can be required without assembling history.lua.
local H = require('tests.support.harness')

H.describe('standalone history reverse module', function()
  H.it('exports undo and redo methods before history.lua is loaded', function()
    local history_module = package.loaded['direct.history.history']
    local reverse_module = package.loaded['direct.history.reverse']
    package.loaded['direct.history.history'] = nil
    package.loaded['direct.history.reverse'] = nil

    local loaded, reverse, history_unloaded = pcall(function()
      local result = require('direct.history.reverse')
      return result, package.loaded['direct.history.history'] == nil
    end)

    package.loaded['direct.history.history'] = history_module
    package.loaded['direct.history.reverse'] = reverse_module

    H.assert_true(loaded, tostring(reverse))
    H.assert_true(history_unloaded, 'requiring reverse does not load history.lua')
    H.assert_eq(type(reverse), 'table', 'reverse module returns a function table')
    H.assert_eq(type(reverse.undo), 'function', 'undo is exported')
    H.assert_eq(type(reverse.redo), 'function', 'redo is exported')
    H.assert_eq(type(reverse._reverse), 'function', 'synchronous reversal is exported')
    H.assert_eq(type(reverse.undo_async), 'function', 'async undo is exported')
    H.assert_eq(type(reverse.redo_async), 'function', 'async redo is exported')
    H.assert_eq(type(reverse._reverse_async), 'function', 'async reversal is exported')
  end)
end)
