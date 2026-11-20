-- The move-planning module is loadable without action.lua assembling a facade.
local H = require('tests.support.harness')

H.describe('standalone action moves module', function()
  H.it('exports move planning helpers without requiring the action facade', function()
    local parent_module = package.loaded['direct.action.action']
    local moves_module = package.loaded['direct.action.moves']
    package.loaded['direct.action.action'] = nil
    package.loaded['direct.action.moves'] = nil
    local loaded, moves, parent_unloaded = pcall(function()
      local result = require('direct.action.moves')
      return result, package.loaded['direct.action.action'] == nil
    end)
    package.loaded['direct.action.action'] = parent_module
    package.loaded['direct.action.moves'] = moves_module

    H.assert_true(loaded, tostring(moves))
    H.assert_true(parent_unloaded, 'requiring moves does not load action.lua')
    H.assert_eq(type(moves), 'table', 'moves module returns a function table')
    H.assert_eq(type(moves.first_free_temp), 'function', 'temporary-path allocation is exported')
    H.assert_eq(type(moves.stage_moves), 'function', 'move staging is exported')
    H.assert_eq(type(moves.plan_move_steps), 'function', 'move-step planning is exported')
    H.assert_eq(type(moves.move_groups), 'function', 'move grouping is exported')
    H.assert_eq(type(moves.make_group), 'function', 'group construction is exported')
  end)
end)
