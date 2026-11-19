-- The open module is loadable without buffer.lua assembling a context table.
local H = require('tests.support.harness')

H.describe('standalone buffer open module', function()
  H.it('exports open and row-path methods before a Buffer is constructed', function()
    local parent_module = package.loaded['direct.buffer.buffer']
    local open_module = package.loaded['direct.buffer.open']
    package.loaded['direct.buffer.buffer'] = nil
    package.loaded['direct.buffer.open'] = nil
    local loaded, open, parent_unloaded = pcall(function()
      local result = require('direct.buffer.open')
      return result, package.loaded['direct.buffer.buffer'] == nil
    end)
    package.loaded['direct.buffer.buffer'] = parent_module
    package.loaded['direct.buffer.open'] = open_module

    H.assert_true(loaded, tostring(open))
    H.assert_true(parent_unloaded, 'requiring open does not load or construct buffer.lua')
    H.assert_eq(type(open), 'table', 'open module returns a function table')
    H.assert_eq(type(open.open), 'function', 'open method is exported')
    H.assert_eq(type(open.get_paths), 'function', 'get_paths method is exported')
    H.assert_eq(type(open.get_entry_path), 'function', 'get_entry_path method is exported')
    H.assert_eq(type(open.get_entry_record), 'function', 'get_entry_record method is exported')
    H.assert_eq(type(open.paste_destination), 'function', 'paste destination method is exported')
    H.assert_eq(type(open.refresh_after_paste), 'function', 'post-paste refresh method is exported')
  end)
end)
