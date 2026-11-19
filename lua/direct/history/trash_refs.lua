-- Trash-reference discovery and history filtering.
-- History supplies its existing action, path, identity, and commit owners.

return function(context)
  local M = context.M
  local platform = context.platform
  local commit_stacks = context.commit_stacks

  local function line_might_reference_trash(line)
    if type(line) ~= 'string' then return false end
    for _, op in ipairs({ 'rm', 'rmdir', 'rs', 'rsdir' }) do
      if line:find('"op":"' .. op .. '"', 1, true) or line:find('\\"op\\":\\"' .. op .. '\\"', 1, true) then
        return true
      end
    end
    return false
  end

  local function history_mentions_path(lines, path)
    local candidates = { path, M.paths.canonical(path) }
    for _, candidate in ipairs(candidates) do
      local ok, encoded = pcall(vim.json.encode, candidate)
      if ok and type(encoded) == 'string' then
        local nested_ok, nested = pcall(vim.json.encode, encoded)
        for _, line in ipairs(lines or {}) do
          if
            line:find(encoded, 1, true) ~= nil
            or (nested_ok and type(nested) == 'string' and line:find(nested, 1, true) ~= nil)
          then
            return true
          end
        end
      end
    end
    return false
  end

  local function unreferenced_dropped_trash(dropped_records, undo_lines, redo_lines)
    local candidates, seen = {}, {}
    local function add(path)
      if type(path) ~= 'string' or path == '' then return end
      local canonical = M.paths.canonical(path)
      if not seen[canonical] then
        seen[canonical] = true
        candidates[#candidates + 1] = path
      end
    end
    local function visit(action)
      if type(action) ~= 'table' then return end
      if action.name == 'rm' or action.name == 'rmdir' then
        add(action.dst)
      elseif action.name == 'rs' or action.name == 'rsdir' then
        add(action.src)
      end
      for _, member in ipairs(action.actions or {}) do
        visit(member)
      end
    end
    for _, line in ipairs(dropped_records or {}) do
      if line_might_reference_trash(line) then
        local ok, action = pcall(M.action.deserialize, line)
        if ok and action then visit(action) end
      end
    end

    local remaining = {}
    for _, lines in ipairs({ undo_lines or {}, redo_lines or {} }) do
      for _, line in ipairs(lines) do
        remaining[#remaining + 1] = line
      end
    end
    local paths = {}
    for _, path in ipairs(candidates) do
      if not history_mentions_path(remaining, path) then paths[#paths + 1] = path end
    end
    return paths
  end

  local function references(state)
    local result = {}
    local function add(path)
      if type(path) == 'string' and path ~= '' then result[M.paths.canonical(path)] = true end
    end
    local function visit(action)
      if type(action) ~= 'table' then return end
      if action.name == 'g' or action.name == 'batch' then
        for _, member in ipairs(action.actions or {}) do
          visit(member)
        end
      elseif action.name == 'rm' or action.name == 'rmdir' then
        add(action.dst)
      elseif action.name == 'rs' or action.name == 'rsdir' then
        add(action.src)
      end
    end
    for _, lines in ipairs({ state.undo_lines, state.redo_lines }) do
      for index = 2, #lines do
        local action = M.action.deserialize(lines[index])
        if action then visit(action) end
      end
    end
    return result
  end

  local function history_path_entry(path, directory)
    if type(path) ~= 'string' or path == '' then return nil end
    local canonical = M.paths.canonical(path)
    return {
      path = canonical,
      key = platform.identity_path(canonical),
      directory = directory == true or path:match('[/\\]$') ~= nil,
    }
  end

  local function path_within(directory, candidate)
    local parent = directory.key:gsub('/+$', '')
    local child = candidate.key:gsub('/+$', '')
    if parent == child then return true end
    local prefix = parent == '' and '/' or parent .. '/'
    return child:sub(1, #prefix) == prefix
  end

  local function paths_overlap(a, b)
    return a.key == b.key or (a.directory and path_within(a, b)) or (b.directory and path_within(b, a))
  end

  local function add_affected(affected, entry)
    for _, existing in ipairs(affected) do
      if existing.key == entry.key then
        existing.directory = existing.directory or entry.directory
        return
      end
    end
    affected[#affected + 1] = entry
  end

  local function action_path_entries(action)
    local result = {}
    local function visit(current)
      if type(current) ~= 'table' then return end
      local directory = current.name == 'rmdir' or current.name == 'rsdir' or current.name == 'mkdir'
      for _, field in ipairs({ 'src', 'dst' }) do
        local entry = history_path_entry(current[field], directory)
        if entry then result[#result + 1] = entry end
      end
      if current.name == 'p' or current.name == 'up' then
        for _, pair in ipairs(current.renames or {}) do
          local source, target
          if current.name == 'p' then
            source = M.action.fs.join(current.src, pair.src)
            target = M.action.fs.join(current.dst, pair.dst)
          else
            source = M.action.fs.join(current.dst, pair.dst)
            target = M.action.fs.join(current.src, pair.src)
          end
          local stat = source and M.action.fs.stat(source)
          -- If the register source was removed, conservatively treat the target
          -- as a directory so descendant history cannot be left stranded.
          local entry = history_path_entry(target, not stat or stat.type == 'directory')
          if entry then result[#result + 1] = entry end
        end
      end
      for _, member in ipairs(current.actions or {}) do
        visit(member)
      end
    end
    visit(action)
    return result
  end

  local function filter_trash_records(lines, trash_paths)
    local records, affected, dropped = {}, {}, 0
    for _, target in ipairs(trash_paths) do
      add_affected(affected, target)
    end
    for index = 2, #(lines or {}) do
      local record = lines[index]
      records[#records + 1] = {
        line = record,
        paths = action_path_entries(M.action.deserialize(record)),
        dropped = false,
      }
    end

    -- First discard records that directly reference the payloads, then walk the
    -- overlapping path dependencies until every remaining record is independent.
    local changed = true
    while changed do
      changed = false
      for _, record in ipairs(records) do
        if not record.dropped then
          local dependent = false
          for _, path in ipairs(record.paths) do
            for _, affected_path in ipairs(affected) do
              if paths_overlap(path, affected_path) then
                dependent = true
                break
              end
            end
            if dependent then break end
          end
          if dependent then
            record.dropped = true
            dropped = dropped + 1
            changed = true
            for _, path in ipairs(record.paths) do
              add_affected(affected, path)
            end
          end
        end
      end
    end

    local kept = { M.HEADER }
    for _, record in ipairs(records) do
      if not record.dropped then kept[#kept + 1] = record.line end
    end
    return kept, dropped
  end

  local function plan_trash_history(state, paths)
    if type(state) ~= 'table' or type(paths) ~= 'table' then
      return nil, 'history.plan_trash_history: state and paths are required'
    end
    local targets = {}
    for _, item in ipairs(paths) do
      local path, directory
      if type(item) == 'table' then
        path, directory = item.path, item.directory
      else
        path = item
      end
      local entry = history_path_entry(path, directory)
      if entry then targets[#targets + 1] = entry end
    end
    local undo_lines, undo_dropped = filter_trash_records(state.undo_lines, targets)
    local redo_lines, redo_dropped = filter_trash_records(state.redo_lines, targets)
    return {
      undo_lines = undo_lines,
      redo_lines = redo_lines,
      undo_dropped = undo_dropped,
      redo_dropped = redo_dropped,
      changed = undo_dropped + redo_dropped > 0,
    }
  end

  local function apply_trash_history_plan(state, plan, persist)
    if type(state) ~= 'table' or type(plan) ~= 'table' then
      return nil, 'history.apply_trash_history_plan: state and plan are required'
    end
    if plan.changed and persist then
      local committed, err =
        commit_stacks(state.undo_path, state.redo_path, state.transaction_path, plan.undo_lines, plan.redo_lines)
      if not committed then return nil, err end
    end
    state.undo_lines = plan.undo_lines
    state.redo_lines = plan.redo_lines
    return {
      undo_dropped = plan.undo_dropped or 0,
      redo_dropped = plan.redo_dropped or 0,
    }
  end

  return {
    apply_trash_history_plan = apply_trash_history_plan,
    plan_trash_history = plan_trash_history,
    references = references,
    unreferenced_dropped_trash = unreferenced_dropped_trash,
  }
end
