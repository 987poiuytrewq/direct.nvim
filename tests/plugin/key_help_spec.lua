local H = require('tests.support.harness')

local function close_float_windows()
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_config(winid).relative ~= '' then
      pcall(vim.api.nvim_win_close, winid, true)
    end
  end
end

local function clean_buffers()
  close_float_windows()
  pcall(vim.cmd, '%bwipeout!')
end

local function setup_listing(options)
  clean_buffers()
  local config = require('direct.config')
  config.clear_mappings()
  config.setup(options or {})

  local sandbox = H.sandbox()
  local root = H.mkdir(sandbox.root, 'workspace')
  H.mkfile(root, 'file.txt', { 'contents' })
  require('direct').list(root)
  return config, vim.api.nvim_get_current_buf()
end

local function buffer_mapping(bufnr, lhs, mode)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode or 'n')) do
    if mapping.lhs == lhs then return mapping end
  end
end

local function float_window()
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) then
      local config = vim.api.nvim_win_get_config(winid)
      if config.relative ~= '' then return winid end
    end
  end
end

local function open_help(lhs)
  local keys = vim.api.nvim_replace_termcodes(lhs or 'g?', true, false, true)
  vim.api.nvim_feedkeys(keys, 'mx', false)
  local winid = float_window()
  H.assert_true(winid ~= nil, (lhs or 'g?') .. ' opens a floating help window')
  return winid, vim.api.nvim_win_get_buf(winid)
end

local function feed(lhs) vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, false, true), 'mx', false) end

local function contains(lines, fragment)
  for _, line in ipairs(lines) do
    if line:find(fragment, 1, true) then return true end
  end
  return false
end

H.describe('in-listing key help', function()
  H.it('opens a focused float with deterministic default mappings', function()
    local _, listing_buf = setup_listing()

    local winid, help_buf = open_help()
    local lines = vim.api.nvim_buf_get_lines(help_buf, 0, -1, false)
    H.assert_eq(vim.api.nvim_win_get_config(winid).relative, 'editor', 'help is a floating window')
    H.assert_true(contains(lines, 'Normal  g?'), 'the help action documents its default key')
    H.assert_true(contains(lines, 'Normal  -'), 'help shows the listing-local parent mapping')
    H.assert_true(contains(lines, 'Go to the parent directory'), 'help describes the local dash action')
    H.assert_false(contains(lines, 'list current buffer directory'), 'help omits the global dash action')
    H.assert_true(contains(lines, 'Normal  zo'), 'help includes folding mappings')
    H.assert_true(contains(lines, 'Expand one direct directory level'), 'help describes folding actions')
    H.assert_true(contains(lines, 'Visual  y'), 'help includes visual-mode mappings')
    H.assert_true(contains(lines, 'Yank the selected entries'), 'help describes visual yank')
    H.assert_eq(lines, require('direct.key_help').lines(), 'mapping order and descriptions are deterministic')

    feed('q')
    H.assert_true(vim.api.nvim_buf_is_valid(listing_buf), 'closing help preserves the listing buffer')
    H.assert_eq(vim.api.nvim_get_current_buf(), listing_buf, 'closing help returns focus to the listing')
    H.assert_false(vim.api.nvim_buf_is_valid(help_buf), 'the scratch help buffer is wiped on close')
  end)

  H.it('shows a custom physical key and labels it as an override', function()
    local _, listing_buf = setup_listing({
      mappings = {
        undo = '<leader>u',
      },
    })

    local _, help_buf = open_help()
    local lines = vim.api.nvim_buf_get_lines(help_buf, 0, -1, false)
    H.assert_true(contains(lines, '<leader>u'), 'the configured undo lhs is shown')
    H.assert_true(contains(lines, 'custom'), 'the override is identified as custom')
    H.assert_true(contains(lines, 'Undo the last change'), 'the undo action is described')
    H.assert_false(contains(lines, 'Normal  u '), 'the displaced default lhs is not shown')

    feed('<Esc>')
    H.assert_eq(vim.api.nvim_get_current_buf(), listing_buf, 'Escape returns to the listing')
  end)

  H.it('omits actions explicitly disabled in the mappings option', function()
    setup_listing({
      mappings = {
        toggle_hidden = false,
      },
    })

    local _, help_buf = open_help()
    local lines = vim.api.nvim_buf_get_lines(help_buf, 0, -1, false)
    H.assert_false(contains(lines, 'Toggle hidden entries'), 'disabled action is absent')
    H.assert_false(contains(lines, 'Normal  gh'), 'disabled default key is absent')
  end)

  H.it('shows only the mapping that wins a configured lhs collision', function()
    setup_listing({
      mappings = {
        undo = 'x',
        expand = 'x',
      },
    })

    local _, help_buf = open_help()
    local lines = vim.api.nvim_buf_get_lines(help_buf, 0, -1, false)
    H.assert_true(contains(lines, 'Normal  x'), 'the shared lhs is visible')
    H.assert_true(contains(lines, 'Expand one direct directory level'), 'later folding mapping wins')
    H.assert_false(contains(lines, 'Undo the last change'), 'the shadowed buffer mapping is omitted')
  end)

  H.it('keeps explicit mappings and the help action when defaults are off', function()
    local _, listing_buf = setup_listing({
      map_default_keys = false,
      mappings = {
        show_help = '<F1>',
        undo = '<leader>u',
      },
    })

    H.assert_nil(buffer_mapping(listing_buf, 'g?'), 'default help key is not installed')
    H.assert_true(buffer_mapping(listing_buf, '<F1>') ~= nil, 'explicit help key remains installed')
    H.assert_nil(buffer_mapping(listing_buf, 'u'), 'default undo key is not installed')

    local _, help_buf = open_help('<F1>')
    local lines = vim.api.nvim_buf_get_lines(help_buf, 0, -1, false)
    H.assert_true(contains(lines, '<F1>'), 'custom help key is included')
    H.assert_true(contains(lines, '<leader>u'), 'explicit action key remains visible')
    H.assert_false(contains(lines, 'Normal  gh'), 'disabled default action is absent')
  end)

  H.it('allows show_help=false to remove g? while retaining its Plug entry', function()
    local _, listing_buf = setup_listing({
      mappings = {
        show_help = false,
      },
    })

    H.assert_nil(buffer_mapping(listing_buf, 'g?'), 'false disables the help key')
    H.assert_true(
      vim.fn.maparg('<Plug>(direct-show-help)', 'n', false, true).rhs ~= '',
      'the Plug entry remains available'
    )
  end)
end)
