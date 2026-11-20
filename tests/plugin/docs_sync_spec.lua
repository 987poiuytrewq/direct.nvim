-- Documentation defaults stay synchronized with config.defaults and help tags.

local H = require('tests.support.harness')

local function read_file(path)
  local file, err = io.open(path, 'r')
  H.assert_true(file ~= nil, 'open ' .. path .. ': ' .. tostring(err))
  local contents = file:read('*a')
  file:close()
  return contents
end

local function readme_defaults(readme)
  local heading = readme:find('These are the defaults:', 1, true)
  H.assert_true(heading ~= nil, 'README contains the defaults heading')
  local fence = readme:find('```lua', heading, true)
  H.assert_true(fence ~= nil, 'README defaults are in a Lua block')
  local statement = readme:find("require('direct').setup({", fence, true)
  H.assert_true(statement ~= nil, 'README defaults block calls setup()')
  local body_start = statement + #"require('direct').setup({"
  local close = readme:find('\n})', body_start, true)
  H.assert_true(close ~= nil, 'README defaults setup() call is closed')

  local chunk, err = loadstring('return {' .. readme:sub(body_start, close - 1) .. '}', '@README.md')
  H.assert_true(chunk ~= nil, 'compile README defaults block: ' .. tostring(err))
  local ok, value = pcall(chunk)
  H.assert_true(ok, 'evaluate README defaults block: ' .. tostring(value))
  return value
end

H.describe('documentation synchronization', function()
  H.it('keeps the README defaults equal to config.defaults and linked from help', function()
    local defaults = require('direct.config').defaults
    local documented = readme_defaults(read_file('README.md'))
    local help = read_file('doc/direct.txt')

    for key, value in pairs(defaults) do
      H.assert_true(documented[key] ~= nil, 'README defaults include option ' .. tostring(key))
      H.assert_eq(documented[key], value, 'README default matches config.defaults for ' .. tostring(key))
      H.assert_true(
        help:find('*direct-' .. tostring(key) .. '*', 1, true) ~= nil,
        'help has a *direct-' .. tostring(key) .. '* tag'
      )
    end
    for key in pairs(documented) do
      H.assert_true(defaults[key] ~= nil, 'README has no undocumented default option ' .. tostring(key))
    end
  end)
end)
