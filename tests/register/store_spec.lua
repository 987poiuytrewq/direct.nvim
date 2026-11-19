local H = require('tests.support.harness')
local register = require('direct.register')
local store = require('direct.register.store')
local fs = require('direct.fs')
local paths = require('direct.paths')

H.describe('register store', function()
  H.it('persists sorted manifest entries behind the register facade', function()
    local sb = H.sandbox()
    local register_dir = assert(paths.ensure_data_dir('register'))
    local snapshot = paths.join(register_dir, 'snapshot')
    local first_payload = H.mkfile(sb.root, 'trash/first', { 'first' })
    local second_payload = H.mkfile(sb.root, 'trash/second', { 'second' })
    local made, make_err = fs.mkdirp(snapshot)
    H.assert_true(made, tostring(make_err))

    local written, write_err = store.write_manifest(snapshot, {
      { name = 'z.txt', path = second_payload },
      { name = 'a.txt', path = first_payload },
    })
    H.assert_true(written, tostring(write_err))

    local entries, entries_err = register.entries(snapshot)
    H.assert_not_nil(entries, tostring(entries_err))
    H.assert_eq({ entries[1].name, entries[2].name }, { 'a.txt', 'z.txt' }, 'manifest entries are sorted by name')
    H.assert_eq(register.entry_path(snapshot, 'a.txt'), first_payload, 'entry_path returns the persisted payload')
    H.assert_eq(register.resolve(snapshot, 'z.txt'), second_payload, 'resolve returns the persisted payload')
    H.assert_eq(register.entry_names(snapshot), { 'a.txt', 'z.txt' }, 'entry_names delegates to manifest storage')
  end)

  H.it('rejects duplicate names in a persisted manifest', function()
    local sb = H.sandbox()
    local register_dir = assert(paths.ensure_data_dir('register'))
    local snapshot = paths.join(register_dir, 'snapshot')
    local payload = H.mkfile(sb.root, 'trash/payload', { 'content' })
    local made, make_err = fs.mkdirp(snapshot)
    H.assert_true(made, tostring(make_err))

    local manifest = vim.json.encode({
      format = 'direct-register',
      entries = {
        { name = 'same.txt', path = payload },
        { name = 'same.txt', path = payload },
      },
    })
    vim.fn.writefile({ manifest }, store.manifest_path(snapshot))

    local entries, err = register.entries(snapshot)
    H.assert_nil(entries, 'duplicate names make a manifest unreadable')
    H.assert_eq(err, 'register manifest has an invalid entry name')
  end)
end)
