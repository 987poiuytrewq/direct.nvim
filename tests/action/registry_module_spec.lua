-- The action registry is loadable without action.lua assembling its facade.
local H = require('tests.support.harness')

H.describe('standalone action registry module', function()
  H.it('exports registry operations without requiring the action facade', function()
    local parent_module = package.loaded['direct.action.action']
    local registry_module = package.loaded['direct.action.registry']
    local registry, actual_parent
    local ok, failure = xpcall(function()
      package.loaded['direct.action.action'] = nil
      package.loaded['direct.action.registry'] = nil
      registry = require('direct.action.registry')

      H.assert_nil(package.loaded['direct.action.action'], 'requiring registry does not load action.lua')
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

      -- Bind the current facade (or load one after the require-independence
      -- assertion), then verify reattachment replaces the prior facade.
      actual_parent = parent_module or require('direct.action.action')
      local path = require('direct.paths').canonical(vim.fn.tempname())
      local record = '{"op":"touch","dst":' .. vim.json.encode(path) .. '}'
      local first_calls, second_calls = 0, 0
      local first_parent = {
        path_reason = function() return nil end,
        Touch = function(dst)
          first_calls = first_calls + 1
          return { name = 'touch', _kind = 'touch', dst = dst }
        end,
      }
      local second_parent = {
        path_reason = function() return nil end,
        Touch = function(dst)
          second_calls = second_calls + 1
          return { name = 'touch', _kind = 'touch', dst = dst }
        end,
      }

      registry.attach(first_parent)
      local first_action, first_err = registry.deserialize(record)
      H.assert_not_nil(first_action, tostring(first_err))
      H.assert_eq(first_calls, 1, 'deserialization uses the first attached facade')

      registry.attach(second_parent)
      local second_action, second_err = registry.deserialize(record)
      H.assert_not_nil(second_action, tostring(second_err))
      H.assert_eq(first_calls, 1, 'reattaching replaces the previous facade')
      H.assert_eq(second_calls, 1, 'deserialization uses the latest attached facade')
    end, debug.traceback)

    if registry and actual_parent then pcall(registry.attach, actual_parent) end
    package.loaded['direct.action.action'] = parent_module
    package.loaded['direct.action.registry'] = registry_module
    if not ok then error(failure, 0) end
  end)
end)
