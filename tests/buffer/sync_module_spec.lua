-- The sync module is loadable without buffer.lua assembling a context table.
local H = require('tests.support.harness')

H.describe('standalone buffer sync module', function()
  H.it('exports sync methods before a Buffer is constructed', function()
    local sync = require('direct.buffer.sync')

    H.assert_eq(type(sync), 'table', 'sync module returns a function table')
    H.assert_eq(type(sync.sync), 'function', 'sync method is exported')
    H.assert_eq(type(sync.sync_async), 'function', 'async sync method is exported')
  end)
end)
