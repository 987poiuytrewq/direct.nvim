-- The collapse module is loadable without buffer.lua assembling a context table.
local H = require('tests.support.harness')

H.describe('standalone buffer collapse module', function()
  H.it('exports collapse helpers before a Buffer is constructed', function()
    local parent_module = package.loaded['direct.buffer.buffer']
    local collapse_module = package.loaded['direct.buffer.collapse']
    package.loaded['direct.buffer.buffer'] = nil
    package.loaded['direct.buffer.collapse'] = nil
    local loaded, collapse, parent_unloaded = pcall(function()
      local result = require('direct.buffer.collapse')
      return result, package.loaded['direct.buffer.buffer'] == nil
    end)
    package.loaded['direct.buffer.buffer'] = parent_module
    package.loaded['direct.buffer.collapse'] = collapse_module

    H.assert_true(loaded, tostring(collapse))
    H.assert_true(parent_unloaded, 'requiring collapse does not load or construct buffer.lua')
    H.assert_eq(type(collapse), 'table', 'collapse module returns a function table')
    H.assert_eq(type(collapse.collapse_single_entry_paths), 'function', 'single-entry path collapsing is exported')
  end)
end)
