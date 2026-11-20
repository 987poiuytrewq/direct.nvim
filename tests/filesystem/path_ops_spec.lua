-- path_ops_spec.lua -- standalone filesystem path operation exports.
local H = require('tests.support.harness')

H.describe('standalone filesystem path operations', function()
  H.it('can be required and used without a parent context or Buffer', function()
    local path_ops = require('direct.fs.path_ops')

    H.assert_true(type(path_ops) == 'table', 'the module returns its operation table')
    H.assert_true(type(path_ops.same_path) == 'function', 'path identity operations are exported')
    H.assert_true(type(path_ops.read_dir_lines) == 'function', 'directory operations are exported')
    H.assert_eq(path_ops.basename('/one/two/'), 'two', 'the module provides the standalone path API')
  end)
end)
