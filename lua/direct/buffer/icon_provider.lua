-- Optional file icon providers. Provider failures never prevent a listing from
-- rendering; callers retain the configured generic glyph when this returns nil.
local M = {}

local warned_custom_providers = setmetatable({}, { __mode = 'k' })

local function valid_icon(glyph, highlight)
  if type(glyph) ~= 'string' or glyph == '' then return nil end
  if type(highlight) ~= 'string' or highlight == '' then highlight = nil end
  return glyph, highlight
end

local function mini_icon(name)
  local mini = rawget(_G, 'MiniIcons')
  if type(mini) ~= 'table' then return nil end
  local ok, glyph, highlight = pcall(function() return mini.get('file', name) end)
  if not ok then return nil end
  return valid_icon(glyph, highlight)
end

local function devicon(name)
  local ok, provider = pcall(require, 'nvim-web-devicons')
  if not ok or type(provider) ~= 'table' then return nil end
  local called, glyph = pcall(function() return provider.get_icon(name, nil, { default = true }) end)
  if not called then return nil end
  return valid_icon(glyph)
end

local function custom_icon(provider, name, kind)
  local ok, glyph, highlight = pcall(provider, name, kind)
  if not ok then
    if not warned_custom_providers[provider] then
      warned_custom_providers[provider] = true
      require('direct.ui').notify(
        'Custom icon provider failed; using the generic file icon: ' .. tostring(glyph),
        vim.log.levels.WARN
      )
    end
    return nil
  end
  return valid_icon(glyph, highlight)
end

--- Return a provider glyph and optional highlight for a file, or nil on fallback.
---@param name string
---@param provider 'auto'|'mini'|'devicons'|false|fun(name: string, type: string): string?, string?
---@return string? glyph
---@return string? highlight
function M.file_icon(name, provider)
  name = tostring(name or '')
  if provider == false then return nil end
  if type(provider) == 'function' then return custom_icon(provider, name, 'file') end
  if provider == 'mini' then return mini_icon(name) end
  if provider == 'devicons' then return devicon(name) end
  if provider == 'auto' or provider == nil then
    local glyph, highlight = mini_icon(name)
    if glyph then return glyph, highlight end
    return devicon(name)
  end
  return nil
end

return M
