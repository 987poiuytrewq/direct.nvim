-- Read-only floating view for an on-demand save plan.
local M = {}

local action = require('direct.action.action')

local function preview_lines(plan, err, root)
  local lines = {
    'Save preview',
    'Root: ' .. tostring(root or ''),
    'Preview only; no filesystem or history changes have been made.',
    '',
  }
  if not plan then
    local refusal_lines = vim.split(tostring(err or 'The save plan is unavailable.'), '\n', { plain = true })
    vim.list_extend(lines, refusal_lines)
  elseif #(plan.actions or {}) == 0 then
    lines[#lines + 1] = 'No filesystem actions are planned.'
  else
    for _, item in ipairs(plan.actions) do
      lines[#lines + 1] = action.describe_action(item)
    end
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'Press q or <Esc> to close.'
  return lines
end

function M.show(plan, err, root)
  local lines = preview_lines(plan, err, root)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].filetype = 'direct-plan'

  local content_width = 0
  for _, line in ipairs(lines) do
    content_width = math.max(content_width, vim.fn.strdisplaywidth(line))
  end
  local width = math.max(1, math.min(content_width, vim.o.columns - 4))
  local height = math.max(1, math.min(#lines, vim.o.lines - vim.o.cmdheight - 4))
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = 'minimal',
    border = 'rounded',
    title = ' Direct plan ',
    title_pos = 'center',
    focusable = true,
  })
  vim.wo[winid].wrap = true

  local function close()
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    elseif vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
  for _, lhs in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', lhs, close, {
      buffer = bufnr,
      silent = true,
      desc = 'direct: close save plan',
    })
  end
  return bufnr, winid
end

return M
