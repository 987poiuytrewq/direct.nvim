local H = require('tests.support.harness')

local function fresh_config()
  package.loaded['direct.config'] = nil
  package.loaded['direct.config.options'] = nil
  package.loaded['direct.config.mappings'] = nil
  local config = require('direct.config')
  config.clear_mappings()
  return config
end

H.describe('sort and custom hidden configuration', function()
  H.it('defaults to name order with directories first and no custom hide function', function()
    local config = fresh_config()
    H.assert_eq(config.defaults.sort, 'name', 'byte-wise name sorting remains the default')
    H.assert_true(config.defaults.sort_directories_first, 'directories stay first by default')
    H.assert_nil(config.defaults.is_hidden, 'no custom hidden rule is installed by default')
    config.clear_mappings()
  end)

  H.it('accepts natural and function sort modes plus an is_hidden callback', function()
    local config = fresh_config()
    local comparator = function(a, b) return a.name < b.name end
    local hidden = function(name, path, kind)
      return name == '__pycache__' and type(path) == 'string' and kind == 'directory' or nil
    end

    local options = config.setup({
      sort = 'natural',
      sort_directories_first = false,
      is_hidden = hidden,
    })
    H.assert_eq(options.sort, 'natural', 'natural sort is accepted')
    H.assert_false(options.sort_directories_first, 'directory grouping can be disabled')
    H.assert_eq(options.is_hidden, hidden, 'the custom hidden callback is retained')

    options = config.setup({ sort = comparator })
    H.assert_eq(options.sort, comparator, 'a custom comparator is accepted')
    config.clear_mappings()
  end)

  H.it('rejects unsupported sort values, directory flags, and hidden rules', function()
    local config = fresh_config()
    H.capture_messages()
    local options = config.setup({
      sort = 'alphabetical',
      sort_directories_first = 'false',
      is_hidden = false,
    })

    H.assert_eq(options.sort, 'name', 'invalid sort keeps the default')
    H.assert_true(options.sort_directories_first, 'invalid directory flag keeps the default')
    H.assert_nil(options.is_hidden, 'invalid hidden rule is not installed')
    H.assert_notified('sort must be', vim.log.levels.ERROR)
    H.assert_notified('sort_directories_first', vim.log.levels.ERROR)
    H.assert_notified('is_hidden', vim.log.levels.ERROR)
    config.clear_mappings()
  end)
end)
