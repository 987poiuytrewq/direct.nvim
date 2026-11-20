-- The action registry is loadable without action.lua assembling its facade.
local H = require('tests.support.harness')

H.describe('standalone action registry module', function()
  H.it('exports registry operations without requiring the action facade', function()
    local parent_module = package.loaded['direct.action.action']
    local registry_module = package.loaded['direct.action.registry']
    package.loaded['direct.action.action'] = nil
    package.loaded['direct.action.registry'] = nil
    local loaded, registry, parent_unloaded = pcall(function()
      local result = require('direct.action.registry')
      return result, package.loaded['direct.action.action'] == nil
    end)
    package.loaded['direct.action.action'] = parent_module
    package.loaded['direct.action.registry'] = registry_module

    H.assert_true(loaded, tostring(registry))
    H.assert_true(parent_unloaded, 'requiring registry does not load action.lua')
    H.assert_eq(type(registry), 'table', 'registry module returns a function table')
    H.assert_eq(type(registry.attach), 'function', 'action facade attachment is exported')
    H.assert_eq(type(registry.serialize_group), 'function', 'group serialization is exported')
    H.assert_eq(type(registry.execute), 'function', 'synchronous execution is exported')
    H.assert_eq(type(registry.execute_async), 'function', 'asynchronous execution is exported')
    H.assert_eq(type(registry.Batch), 'function', 'batch construction is exported')
    H.assert_eq(type(registry.serialize), 'function', 'serialization is exported')
    H.assert_eq(type(registry.deserialize), 'function', 'deserialization is exported')
    H.assert_eq(type(registry.reverse_action), 'function', 'action reversal is exported')
    H.assert_eq(type(registry.reverse), 'function', 'serialized reversal is exported')
  end)
end)
