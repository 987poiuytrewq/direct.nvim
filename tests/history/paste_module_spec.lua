-- The Paste history module can be required without history.lua assembling a context.
local H = require('tests.support.harness')

H.describe('standalone history paste module', function()
  H.it('exports paste-journal methods before history.lua is loaded', function()
    local history_module = package.loaded['direct.history.history']
    local paste_module = package.loaded['direct.history.paste']
    package.loaded['direct.history.history'] = nil
    package.loaded['direct.history.paste'] = nil
    local loaded, paste, history_unloaded = pcall(function()
      local result = require('direct.history.paste')
      return result, package.loaded['direct.history.history'] == nil
    end)
    package.loaded['direct.history.history'] = history_module
    package.loaded['direct.history.paste'] = paste_module

    H.assert_true(loaded, tostring(paste))
    H.assert_true(history_unloaded, 'requiring paste does not load or construct history.lua')
    H.assert_eq(type(paste), 'table', 'paste module returns a function table')
    H.assert_eq(type(paste.begin_paste), 'function', 'begin_paste is exported')
    H.assert_eq(type(paste.begin_paste_async), 'function', 'begin_paste_async is exported')
    H.assert_eq(type(paste.note_paste_pending), 'function', 'pending journal update is exported')
    H.assert_eq(type(paste.note_paste_complete), 'function', 'completed journal update is exported')
    H.assert_eq(type(paste.cancel_paste_pending), 'function', 'cancel journal update is exported')
    H.assert_eq(type(paste.finish_paste), 'function', 'finish_paste is exported')
    H.assert_eq(type(paste.write_paste_journal), 'function', 'journal writer is exported')
  end)
end)
