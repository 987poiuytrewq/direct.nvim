-- The navigation module is loadable without buffer.lua assembling a context table.
local H = require('tests.support.harness')

H.describe('standalone buffer navigation module', function()
  H.it('exports navigation and folding methods before a Buffer is constructed', function()
    local parent_module = package.loaded['direct.buffer.buffer']
    local navigation_module = package.loaded['direct.buffer.navigation']
    package.loaded['direct.buffer.buffer'] = nil
    package.loaded['direct.buffer.navigation'] = nil
    local loaded, navigation, parent_unloaded = pcall(function()
      local result = require('direct.buffer.navigation')
      return result, package.loaded['direct.buffer.buffer'] == nil
    end)
    package.loaded['direct.buffer.buffer'] = parent_module
    package.loaded['direct.buffer.navigation'] = navigation_module

    H.assert_true(loaded, tostring(navigation))
    H.assert_true(parent_unloaded, 'requiring navigation does not load or construct buffer.lua')
    H.assert_eq(type(navigation), 'table', 'navigation module returns a function table')
    H.assert_eq(type(navigation.navigate_git_status), 'function', 'Git-status navigation is exported')
    H.assert_eq(type(navigation.navigate_file), 'function', 'file navigation is exported')
    H.assert_eq(type(navigation._folding_context), 'function', 'folding context is exported')
    H.assert_eq(type(navigation.expand_recursive), 'function', 'recursive expansion is exported')
    H.assert_eq(type(navigation.toggle_recursive), 'function', 'recursive toggle is exported')
    H.assert_eq(type(navigation.expand_all), 'function', 'expand all is exported')
    H.assert_eq(type(navigation.collapse_all), 'function', 'collapse all is exported')
  end)
end)
