-- One async direct operation may own the editor until its UI callback settles.
local M = {}

local active = false
local label
local generation = 0
local current_token
local current_bufnr
local finish_callbacks = {}
local save_queue = {}
local active_save

local function schedule_save_queue()
  vim.schedule(function()
    if active or active_save then return end
    local request = table.remove(save_queue, 1)
    if not request then return end
    active_save = request

    local completed = false
    local function complete(ok, err, detail)
      if completed then return end
      completed = true
      if active_save == request then active_save = nil end
      local called, callback_err = pcall(request.callback, ok, err, detail)
      if not called then require('direct.ui').report_error('complete a queued save', callback_err) end
      if request.wipe_cleanup then pcall(request.wipe_cleanup) end
      schedule_save_queue()
    end

    local called, started, start_err = xpcall(function() return request.start(complete) end, debug.traceback)
    if not called then
      complete(nil, started)
    elseif started == nil then
      complete(nil, start_err)
    end
  end)
end

function M.is_pending() return active end

function M.is_active(token) return active and (token == nil or token == current_token) end

function M.can_queue_save() return not active or label == 'sync' end

function M.enqueue_save(bufnr, start, callback)
  if type(start) ~= 'function' then return nil, 'a save start function is required' end
  local request = {
    bufnr = bufnr,
    start = start,
    callback = callback or function() end,
  }
  save_queue[#save_queue + 1] = request
  schedule_save_queue()
  return request
end

function M.has_saves() return active_save ~= nil or #save_queue > 0 or (active and label == 'sync') end

function M.active_for_buffer(bufnr, operation)
  return active and current_bufnr == bufnr and (operation == nil or label == operation)
end

function M.defer_cleanup(bufnr, cleanup)
  if not active or current_bufnr ~= bufnr then return false end
  finish_callbacks[#finish_callbacks + 1] = cleanup
  return true
end

-- Keep the Lua-side listing state alive when a queued or running write's buffer
-- is wiped. The save owns that state until its completion callback settles.
function M.save_wiped(bufnr, cleanup)
  local last_match = active_save and active_save.bufnr == bufnr and active_save or nil
  for _, request in ipairs(save_queue) do
    if request.bufnr == bufnr then last_match = request end
  end
  if not last_match then return false end
  last_match.wipe_cleanup = cleanup
  return true
end

function M.begin(operation, bufnr)
  if active then return nil, 'another direct operation is pending' end
  active = true
  label = operation or 'operation'
  current_bufnr = bufnr
  finish_callbacks = {}
  generation = generation + 1
  current_token = generation
  return true, current_token
end

function M.finish(token)
  if token ~= nil and token ~= current_token then return false end
  local callbacks = finish_callbacks
  active = false
  label = nil
  current_bufnr = nil
  current_token = nil
  finish_callbacks = {}
  for _, callback in ipairs(callbacks) do
    local called, err = pcall(callback)
    if not called then require('direct.ui').report_error('release a completed operation', err) end
  end
  schedule_save_queue()
  return true
end

function M.refuse(operation, only_label)
  if not active then return false end
  if only_label ~= nil and label ~= only_label and not (only_label == 'willRenameFiles' and label == 'sync') then
    return false
  end
  local ui = require('direct.ui')
  ui.notify(
    'direct: cannot '
      .. tostring(operation or 'start operation')
      .. ' while '
      .. tostring(label or 'another operation')
      .. ' is pending',
    vim.log.levels.WARN
  )
  return true
end

return M
