-- The tree module is loadable without buffer.lua assembling a context table.
local H = require('tests.support.harness')

H.describe('standalone buffer tree module', function()
  H.it('exports tree validation and planning methods before a Buffer is constructed', function()
    local parent_module = package.loaded['direct.buffer.buffer']
    local tree_module = package.loaded['direct.buffer.tree']
    package.loaded['direct.buffer.buffer'] = nil
    package.loaded['direct.buffer.tree'] = nil
    local loaded, tree, parent_unloaded = pcall(function()
      local result = require('direct.buffer.tree')
      return result, package.loaded['direct.buffer.buffer'] == nil
    end)
    package.loaded['direct.buffer.buffer'] = parent_module
    package.loaded['direct.buffer.tree'] = tree_module

    H.assert_true(loaded, tostring(tree))
    H.assert_true(parent_unloaded, 'requiring tree does not load or construct buffer.lua')
    H.assert_eq(type(tree), 'table', 'tree module returns a function table')
    H.assert_eq(type(tree.children_integrity), 'function', 'child integrity validation is exported')
    H.assert_eq(type(tree.edited_subtrees), 'function', 'edited subtree planning is exported')
  end)
end)
