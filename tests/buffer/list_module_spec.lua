-- The list module can be loaded without buffer.lua assembling a context table.
local H = require('tests.support.harness')

H.describe('standalone buffer list module', function()
  H.it('exports listing methods before a Buffer is constructed', function()
    local parent_module = package.loaded['direct.buffer.buffer']
    local list_module = package.loaded['direct.buffer.list']
    package.loaded['direct.buffer.buffer'] = nil
    package.loaded['direct.buffer.list'] = nil
    local loaded, list, parent_unloaded = pcall(function()
      local result = require('direct.buffer.list')
      return result, package.loaded['direct.buffer.buffer'] == nil
    end)
    package.loaded['direct.buffer.buffer'] = parent_module
    package.loaded['direct.buffer.list'] = list_module

    H.assert_true(loaded, tostring(list))
    H.assert_true(parent_unloaded, 'requiring list does not load or construct buffer.lua')
    H.assert_eq(type(list), 'table', 'list module returns a function table')
    H.assert_eq(type(list.restore), 'function', 'restore is exported')
    H.assert_eq(type(list.list), 'function', 'list is exported')
    H.assert_eq(type(list.place_cursor), 'function', 'cursor placement is exported')
    H.assert_eq(type(list.list_buffer), 'function', 'buffer listing is exported')
  end)
end)
