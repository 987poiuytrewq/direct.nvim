-- Project filtered directory chains as a single editable path row.

local M = {}

local fs = require('direct.fs')
local git = require('direct.git')
local listing = require('direct.buffer.listing')
local paths = require('direct.paths')
local rows = require('direct.buffer.rows')
local buffer_state = require('direct.buffer.state')

local is_dir_line = rows.is_dir_line
local dirs_then_name = rows.dirs_then_name

local function buffer_module()
  local module = buffer_state.list_parent
  assert(type(module) == 'table', 'buffer.collapse parent is not attached')
  return module
end

local function entry_path(root, line) return buffer_module().entry_path(root, line) end

local function path_identity(path) return fs.path_identity(path, fs.stat(path)) end

local function list_with_snapshot(root, show_hidden, respect_gitignore)
  return listing.list_with_snapshot(root, buffer_module().read, show_hidden, respect_gitignore)
end

local function filter_git_status_lines(root, lines, snapshot)
  local filtered = {}
  for _, line in ipairs(lines or {}) do
    if git.status_for(snapshot, entry_path(root, line)) then filtered[#filtered + 1] = line end
  end
  return filtered
end

local function filter_git_diff_lines(root, lines, snapshot)
  local filtered = {}
  for _, line in ipairs(lines or {}) do
    if git.status_for(snapshot, entry_path(root, line)) then filtered[#filtered + 1] = line end
  end
  return filtered
end

local function get_directory_snapshot(state, directory) return listing.get_directory_snapshot(state, directory) end

local function apply_snapshot(directory, physical, snapshot)
  return listing.apply_snapshot(directory, physical, snapshot)
end

function M.collapse_single_entry_paths(root, lines, options)
  local rendered, components_by_line, snapshots = {}, {}, {}

  local function children_for(directory)
    local children, snapshot, err
    if options.capture then
      children, snapshot, err = list_with_snapshot(directory, options.show_hidden, options.respect_gitignore)
      if not children then return nil, err end
      snapshots[#snapshots + 1] = snapshot
    else
      snapshot = get_directory_snapshot(options.state, directory)
      if snapshot then
        local physical
        physical, err = fs.read_dir_lines(directory)
        if not physical then return nil, err end
        children, err = apply_snapshot(directory, physical, snapshot)
        if not children then return nil, err end
      else
        -- A newly appeared directory has no saved filter context. Inspect it
        -- only so sync can reject the external change safely.
        local listed, _, list_err = list_with_snapshot(directory, options.show_hidden, options.respect_gitignore)
        children, err = listed, list_err
        if not children then return nil, err end
      end
    end
    if options.status_only then children = filter_git_status_lines(directory, children, options.git_status) end
    if options.git_diff_only then children = filter_git_diff_lines(directory, children, options.git_diff) end
    return children
  end

  local function render_chain(path, entry_name, components, deleted, seen_directories)
    local name = paths.strip_directory_marker(entry_name)
    local is_directory = is_dir_line(entry_name)
    local next_components = vim.deepcopy(components)
    next_components[#next_components + 1] = {
      name = name,
      directory = is_directory,
    }
    local function append_current()
      local line =
        table.concat(vim.tbl_map(function(item) return item.name end, next_components), paths.directory_separator())
      if is_directory then line = paths.mark_directory(line) end
      rendered[#rendered + 1] = line
      components_by_line[line] = next_components
      return true
    end
    if not is_directory or deleted then return append_current() end

    local identity = path_identity(path)
    local identity_key = identity and (identity.inode or identity.path)
    if identity_key and seen_directories[identity_key] then return append_current() end
    if identity_key then seen_directories[identity_key] = true end

    local directory = paths.strip_trailing_separator(path)
    local children, err = children_for(directory)
    if not children then
      if options.capture then return append_current() end
      return nil, err
    end
    if #children == 1 and is_dir_line(children[1]) then
      local child = children[1]
      return render_chain(entry_path(directory, child), child, next_components, false, seen_directories)
    end
    return append_current()
  end

  for _, line in ipairs(lines or {}) do
    local path = entry_path(root, line)
    local deleted = options.deleted_paths and options.deleted_paths[vim.fs.normalize(path)] ~= nil
    local ok, err = render_chain(path, line, {}, deleted, {})
    if not ok then return nil, nil, nil, err end
  end

  local ordered = dirs_then_name(rendered)
  local components = {}
  for index, line in ipairs(ordered) do
    components[index] = components_by_line[line]
  end
  return ordered, components, snapshots
end

return M
