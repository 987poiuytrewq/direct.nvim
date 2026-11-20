-- Parse materialized tree edits and produce validated filesystem action plans.

local M = {}

local action_mod = require('direct.action.action')
local buffer_state = require('direct.buffer.state')
local fs = require('direct.fs')
local paths = require('direct.paths')
local rows = require('direct.buffer.rows')

local states = buffer_state.states
local namespace = buffer_state.namespace
local row_ids_by_row = rows.row_ids_by_row
local set_row_mark = rows.set_row_mark
local is_dir_line = rows.is_dir_line
local strip_directory_marker = paths.strip_directory_marker

local function buffer_module()
  local module = buffer_state.list_parent
  assert(type(module) == 'table', 'buffer.tree parent is not attached')
  return module
end

local function component_reason(...)
  local plan = buffer_state.sync_plan
  assert(type(plan) == 'table', 'buffer.tree sync plan is not attached')
  return plan.component_reason(...)
end

local function nested_path_reason(...)
  local plan = buffer_state.sync_plan
  assert(type(plan) == 'table', 'buffer.tree sync plan is not attached')
  return plan.nested_path_reason(...)
end

local function entry_path(root, line) return buffer_module().entry_path(root, line) end

local function indent_size() return require('direct.config').options.indent_size end

local function tree_refusal(reason, line, path) return nil, reason, { line = line, path = path } end

local function finish_children_integrity(bufnr, lines, recovered_rows, preview)
  if not preview then
    for id, row in pairs(recovered_rows) do
      local ok = pcall(set_row_mark, bufnr, row, id)
      if not ok then return tree_refusal('child identity marks could not be restored safely', row) end
    end
  end
  return lines
end

local function unique_text_line(lines, text)
  local found
  for row, line in ipairs(lines or {}) do
    if line == text then
      if found ~= nil then return nil end
      found = row - 1
    end
  end
  return found
end

local function first_unidentified_row(nodes)
  for _, node in ipairs(nodes) do
    if not node.id then return node.row end
  end
end

local function restore_missing_child_rows(bufnr, lines, state, expected_order, mark_rows, invalid_child_ids)
  local recovered_rows, missing_children = {}, false
  for _, rec in ipairs(expected_order) do
    if mark_rows[rec.id] == nil then
      if not invalid_child_ids[rec.id] then
        return nil, 'child identity marks are invalid or duplicated', unique_text_line(lines, rec.text)
      end
      missing_children = true
    end
  end
  if not missing_children then return recovered_rows end
  if vim.fn.undotree(bufnr).seq_cur ~= state.materialization_seq then
    for _, rec in ipairs(expected_order) do
      if invalid_child_ids[rec.id] and mark_rows[rec.id] == nil then
        return nil,
          'child identity marks were lost outside an undo to their materialization baseline',
          invalid_child_ids[rec.id] or unique_text_line(lines, rec.text)
      end
    end
    return nil, 'child identity marks were lost outside an undo to their materialization baseline'
  end

  -- Undo can invalidate extmarks despite restoring the materialized rows. Reattach
  -- only against each expanded root's identity and ordered subtree baseline.
  local root_rows, previous_root_row = {}, -1
  for _, root_id in ipairs(state.root_ids or {}) do
    local row = mark_rows[root_id]
    if row == nil or row <= previous_root_row then
      return nil, 'child rows cannot be uniquely associated with their root identity', row
    end
    root_rows[root_id], previous_root_row = row, row
  end

  local expected_child_ids = {}
  local function append_subtree(parent_id, parent_depth, out)
    local expansion = state.expanded[parent_id]
    if not expansion then return true end
    local previous_order = 0
    for _, child in ipairs(expansion.children) do
      if
        child.kind ~= 'child'
        or child.parent ~= parent_id
        or state.rows[child.id] ~= child
        or child.order <= previous_order
        or child.depth ~= parent_depth + 1
        or child.text ~= string.rep(' ', indent_size() * child.depth) .. child.name
      then
        return false
      end
      previous_order = child.order
      expected_child_ids[child.id] = true
      out[#out + 1] = child
      if not append_subtree(child.id, child.depth, out) then return false end
    end
    return true
  end

  for _, root_id in ipairs(state.root_ids or {}) do
    local root, expansion = state.rows[root_id], state.expanded[root_id]
    if root and expansion and #expansion.children > 0 then
      local subtree = {}
      local parent_row = root_rows[root_id]
      if not append_subtree(root_id, root.depth or 0, subtree) then
        return nil, 'child materialization baseline is inconsistent', parent_row
      end
      for offset, child in ipairs(subtree) do
        local row = parent_row + offset
        if lines[row + 1] ~= child.text then
          return nil, 'child row text differs from its materialization baseline', row
        end
        local occupied_by_root = false
        for _, other_root_id in ipairs(state.root_ids or {}) do
          if root_rows[other_root_id] == row then
            occupied_by_root = true
            break
          end
        end
        if occupied_by_root then return nil, 'child order no longer follows its owning root row', row end
        local existing_row = mark_rows[child.id]
        if existing_row ~= nil and existing_row ~= row then
          return nil, 'child row identity moved from its materialization baseline', row
        end
        if existing_row == nil and not invalid_child_ids[child.id] then
          return nil, 'child identity marks are invalid or duplicated', row
        end
        if existing_row == nil then recovered_rows[child.id] = row end
        mark_rows[child.id] = row
      end
    end
  end
  for id, row in pairs(invalid_child_ids) do
    if not expected_child_ids[id] then return nil, 'child identity marks are invalid or duplicated', row end
  end
  for _, rec in ipairs(expected_order) do
    if mark_rows[rec.id] == nil then
      return nil,
        'child rows were added, deleted, reordered, or lost identity',
        invalid_child_ids[rec.id] or unique_text_line(lines, rec.text)
    end
  end
  return recovered_rows
end

do
  local function children_integrity(bufnr, lines, preview)
    local state = states[bufnr]
    if not state then return lines end
    local seq_cur = vim.fn.undotree(bufnr).seq_cur
    for _, materialization in ipairs(state.materialization_recoveries or {}) do
      if materialization.seq == seq_cur then
        return tree_refusal('redone child materialization could not be uniquely restored')
      end
    end
    local expected_order, child_count = {}, 0
    for _, id in ipairs(state.display_ids or {}) do
      local rec = state.rows[id]
      if rec and rec.kind == 'child' then
        expected_order[#expected_order + 1] = rec
        child_count = child_count + 1
      end
    end
    if child_count == 0 then
      -- Keep ordinary root-only validation semantics, but do not let an extmark
      -- restored by :redo become an untracked root action after its snapshot was
      -- rejected or its records were discarded.
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, {})) do
        if not state.rows[mark[1]] then
          return tree_refusal('child identity marks are invalid or duplicated', mark[2])
        end
      end
      local visible_roots = {}
      local row_ids = row_ids_by_row(bufnr)
      for row, line in ipairs(lines) do
        local id = row_ids[row - 1]
        local rec = id and state.rows[id]
        if not (rec and rec.deleted_kind) then visible_roots[#visible_roots + 1] = line end
      end
      return visible_roots
    end
    local mark_rows, seen_id, seen_row, invalid_child_ids = {}, {}, {}, {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })) do
      local id, row, details = mark[1], mark[2], mark[4] or {}
      local rec = state.rows[id]
      if not rec then return tree_refusal('child identity marks are invalid or duplicated', row) end
      if details.invalid then
        if rec.kind == 'child' then
          if invalid_child_ids[id] then return tree_refusal('child identity marks are invalid or duplicated', row) end
          invalid_child_ids[id] = row
        end
        -- Root identities may be invalidated by deletion or rename. Preserve that
        -- intent for identity-based sync planning below.
      else
        local other_id = seen_row[row]
        local other = other_id and state.rows[other_id]
        if seen_id[id] or (other_id and (rec.kind == 'child' or other and other.kind == 'child')) then
          return tree_refusal('child identity marks are invalid or duplicated', row)
        end
        seen_id[id], seen_row[row] = true, id
        mark_rows[id] = row
      end
    end

    local recovered_rows, recovery_err, recovery_line =
      restore_missing_child_rows(bufnr, lines, state, expected_order, mark_rows, invalid_child_ids)
    if not recovered_rows then return tree_refusal(recovery_err, recovery_line) end

    local previous_row = -1
    for _, rec in ipairs(expected_order) do
      local row = mark_rows[rec.id]
      if row == nil or row <= previous_row then
        return tree_refusal('child rows were added, deleted, reordered, or lost identity', row)
      end
      if lines[row + 1] ~= rec.text then
        return tree_refusal('child row text differs from its materialization baseline', row)
      end
      previous_row = row
    end

    -- Every expanded parent with children must retain its identity.  For each
    -- subtree, unmarked inserted lines between the parent and its last child are
    -- not root entries and may never be mistaken for root edits.
    local protected = {}
    for parent_id, expansion in pairs(state.expanded or {}) do
      if #expansion.children > 0 then
        local parent_row = mark_rows[parent_id]
        -- A missing expanded parent can be a deleted or renamed root directory;
        -- its independently marked descendants stay excluded from root edits.
        if parent_row ~= nil then
          local last = parent_row
          for _, rec in ipairs(expected_order) do
            local ancestor = rec.parent
            while ancestor do
              if ancestor == parent_id then
                local child_row = mark_rows[rec.id]
                if child_row == nil or child_row <= parent_row then
                  return tree_refusal('child order no longer follows its parent', child_row or parent_row)
                end
                last = math.max(last, child_row)
                break
              end
              local ancestor_rec = state.rows[ancestor]
              ancestor = ancestor_rec and ancestor_rec.parent or nil
            end
          end
          for row = parent_row + 1, last do
            protected[row] = true
          end
        end
      end
    end

    local row_ids = {}
    for id, row in pairs(mark_rows) do
      if row_ids[row] ~= nil then return tree_refusal('child identity marks are invalid or duplicated', row) end
      row_ids[row] = id
    end
    local actual_children = 0
    for row, line in ipairs(lines) do
      local id = row_ids[row - 1]
      local rec = id and state.rows[id]
      if rec and rec.kind == 'child' then
        actual_children = actual_children + 1
      elseif protected[row - 1] or (not rec and line:match('^%s')) then
        return tree_refusal('unidentified child row is present', row - 1)
      end
    end
    if actual_children ~= child_count then
      return tree_refusal('child row count differs from its materialization baseline')
    end

    local root_lines = {}
    for row, line in ipairs(lines) do
      local id = row_ids[row - 1]
      local rec = id and state.rows[id]
      if (not rec or rec.kind ~= 'child') and not (rec and rec.deleted_kind) then root_lines[#root_lines + 1] = line end
    end
    return finish_children_integrity(bufnr, root_lines, recovered_rows, preview)
  end

  -- edited_subtrees(bufnr, lines) -> a per-expanded-directory action plan, or
  -- nil, reason. The ordinary children_integrity path remains the fast path for
  -- an unchanged materialization. For edits, extmarks provide identity and the
  -- parsed indentation provides each row's desired parent and filesystem path.
  local function parse_tree_nodes(lines, spaces_per_level, state, marks_by_row, expansion_is_live)
    local nodes, nodes_by_id, nodes_by_key, children_by_parent = {}, {}, {}, {}
    local stack, previous_depth = {}, 0
    for row, line in ipairs(lines) do
      local prefix = line:match('^( *)') or ''
      if #prefix % spaces_per_level ~= 0 then
        if not stack[1] or not is_dir_line(stack[1].name) then
          return nil, 'root names may not begin with whitespace', row - 1
        end
        return nil, 'child row indentation must use groups of ' .. spaces_per_level .. ' spaces', row - 1
      end
      local depth = #prefix / spaces_per_level
      if depth > previous_depth + 1 then return nil, 'a child row skips a directory level', row - 1 end
      local name = line:sub(#prefix + 1)
      if name == '' then return nil, 'empty child row', row - 1 end

      local parent = depth > 0 and stack[depth] or nil
      if depth > 0 and not parent then return nil, 'child row has no parent directory', row - 1 end
      if parent and not is_dir_line(parent.name) then return nil, 'child row parent is not a directory', row - 1 end
      if parent and parent.id and not expansion_is_live(parent.id) then
        return nil, 'cannot edit child rows under a collapsed directory', row - 1
      end

      local id = marks_by_row[row - 1]
      local rec = id and state.rows[id] or nil
      local reason
      if rec and rec.collapsed_components and nested_path_reason then
        reason = nested_path_reason(name)
      else
        reason = component_reason(name)
      end
      if reason then return nil, reason, row - 1, name end
      local parent_key = parent and parent.key or nil
      local node = {
        id = id,
        rec = rec,
        name = name,
        depth = depth,
        parent_id = parent_key,
        parent_key = parent_key,
        key = id or ('new:' .. row),
        row = row - 1,
      }
      nodes[#nodes + 1] = node
      if id then nodes_by_id[id] = node end
      nodes_by_key[node.key] = node
      if depth > 0 then
        children_by_parent[parent_key] = children_by_parent[parent_key] or {}
        children_by_parent[parent_key][#children_by_parent[parent_key] + 1] = node
      end
      stack[depth + 1] = node
      for level = depth + 2, #stack do
        stack[level] = nil
      end
      previous_depth = depth
    end
    return { nodes = nodes, by_id = nodes_by_id, by_key = nodes_by_key, children = children_by_parent }
  end

  local function edited_subtrees(bufnr, lines)
    local state = states[bufnr]
    if not state then return tree_refusal('child identity state is unavailable') end
    local undo_tree = vim.fn.undotree(bufnr)
    local seq_cur = undo_tree.seq_cur
    if #(state.materialization_recoveries or {}) > 0 then
      return tree_refusal('redone child materialization could not be uniquely restored')
    end
    local active, undone_ids, current_path = {}, {}, false
    for _, entry in ipairs(undo_tree.entries or {}) do
      if not current_path then
        active[entry.seq] = true
        if entry.seq == seq_cur then current_path = true end
      end
    end
    for _, materialization in ipairs(state.materialization_undos or {}) do
      if not active[materialization.seq] and (materialization.base_seq == 0 or active[materialization.base_seq]) then
        for _, id in ipairs(materialization.child_ids or {}) do
          undone_ids[id] = true
        end
      end
    end
    local function expansion_is_live(parent_id)
      local expansion = state.expanded[parent_id]
      if not expansion then return false end
      if #(expansion.children or {}) == 0 then return true end
      for _, child in ipairs(expansion.children) do
        if not undone_ids[child.id] then return true end
      end
      return false
    end

    local marks_by_row, valid_ids, invalid_ids, invalid_rows = {}, {}, {}, {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })) do
      local id, row, details = mark[1], mark[2], mark[4] or {}
      if not state.rows[id] or valid_ids[id] or invalid_ids[id] then
        return tree_refusal('child identity marks are invalid or duplicated', row)
      end
      if details.invalid then
        invalid_ids[id], invalid_rows[id] = true, row
      else
        if marks_by_row[row] then return tree_refusal('child identity marks are invalid or duplicated', row) end
        marks_by_row[row], valid_ids[id] = id, true
      end
    end
    for _, id in ipairs(state.display_ids or {}) do
      if not undone_ids[id] and not valid_ids[id] and not invalid_ids[id] then
        return tree_refusal('child identity mark was lost')
      end
    end

    -- A modified listing may use Neovim's one-empty-line representation for an
    -- intentionally emptied tree. A clean empty listing is handled by sync's
    -- existing root-listing special case.
    if #lines == 1 and lines[1] == '' and vim.bo[bufnr].modified then lines = {} end

    local parsed, parse_err, parse_line, parse_path =
      parse_tree_nodes(lines, indent_size(), state, marks_by_row, expansion_is_live)
    if not parsed then return tree_refusal(parse_err, parse_line, parse_path) end
    local nodes, nodes_by_id, nodes_by_key, children_by_parent =
      parsed.nodes, parsed.by_id, parsed.by_key, parsed.children

    -- Top-level rows use the same identity rule as expanded siblings: an
    -- invalidated row can be recovered as a rename only within a one-for-one
    -- interval bounded by surviving identities. Keep the old delete/create
    -- interpretation when counts or file/directory types do not match.
    local old_roots, current_roots = {}, {}
    for _, id in ipairs(state.root_ids or {}) do
      local rec = state.rows[id]
      if rec and not rec.deleted_kind then old_roots[#old_roots + 1] = rec end
    end
    for _, node in ipairs(nodes) do
      if node.depth == 0 then current_roots[#current_roots + 1] = node end
    end
    local current_root_index = {}
    for index, node in ipairs(current_roots) do
      if node.id then current_root_index[node.id] = index end
    end
    local root_anchors = {}
    for old_index, rec in ipairs(old_roots) do
      local new_index = current_root_index[rec.id]
      if new_index then root_anchors[#root_anchors + 1] = { old = old_index, new = new_index } end
    end
    local roots_reordered = false
    for index = 2, #root_anchors do
      if root_anchors[index].new <= root_anchors[index - 1].new then
        roots_reordered = true
        break
      end
    end
    if not roots_reordered then
      local old_after, new_after = 0, 0
      local function pair_root_interval(old_before, new_before)
        local removed, inserted = {}, {}
        for oi = old_after + 1, old_before - 1 do
          local rec = old_roots[oi]
          if invalid_ids[rec.id] and not nodes_by_id[rec.id] then removed[#removed + 1] = rec end
        end
        for ni = new_after + 1, new_before - 1 do
          local node = current_roots[ni]
          if not node.id then inserted[#inserted + 1] = node end
        end
        if #removed > 0 and #removed == #inserted then
          local same_types = true
          for pair = 1, #removed do
            if
              removed[pair].name == inserted[pair].name
              or is_dir_line(removed[pair].name) ~= is_dir_line(inserted[pair].name)
            then
              same_types = false
              break
            end
          end
          if same_types then
            for pair = 1, #removed do
              local rec, node = removed[pair], inserted[pair]
              node.id, node.rec = rec.id, rec
              nodes_by_id[rec.id] = node
              invalid_ids[rec.id] = nil
            end
          end
        end
      end
      for _, anchor in ipairs(root_anchors) do
        pair_root_interval(anchor.old, anchor.new)
        old_after, new_after = anchor.old, anchor.new
      end
      pair_root_interval(#old_roots + 1, #current_roots + 1)
    end

    -- Root classifier input excludes identity-preserving moves across the root
    -- boundary. A root moved into a child remains in its original virtual slot;
    -- a child moved to the root is handled by the tree Move action, not ADD.
    local roots = {}
    local root_rows, root_ids = {}, {}
    for _, id in ipairs(state.root_ids or {}) do
      root_ids[id] = true
      local rec, now = state.rows[id], nodes_by_id[id]
      if not rec.deleted_kind and now then
        local line = now.depth == 0 and now.name or rec.name
        roots[#roots + 1] = line
        root_rows[#root_rows + 1] = { id = id, line = line, row = now.row }
      end
    end
    for _, node in ipairs(nodes) do
      if node.depth == 0 and not node.id then
        roots[#roots + 1] = node.name
        root_rows[#root_rows + 1] = { line = node.name, row = node.row }
      end
    end
    for _, siblings in pairs(children_by_parent) do
      local seen_names = {}
      for _, node in ipairs(siblings) do
        local basename = strip_directory_marker(node.name)
        if seen_names[basename] then return tree_refusal('duplicate child entry: ' .. basename, node.row, node.path) end
        seen_names[basename] = true
      end
    end

    local nodes_by_row = {}
    for _, node in ipairs(nodes) do
      nodes_by_row[node.row] = node
    end
    for id in pairs(invalid_ids) do
      local rec = state.rows[id]
      local replacement = rec and rec.kind == 'child' and nodes_by_row[invalid_rows[id]] or nil
      if replacement and not replacement.id then
        if replacement.depth ~= rec.depth or replacement.parent_id ~= rec.parent then
          return tree_refusal(
            'child identity was replaced outside its original directory row',
            replacement.row,
            rec.path
          )
        end
        -- `cc`/line replacement invalidates extmarks in Neovim. Recover identity
        -- only at the exact original row, parent, and depth; never adopt by name.
        replacement.id, replacement.rec = id, rec
        nodes_by_id[id] = replacement
      elseif rec and rec.kind == 'child' then
        local preceding = nodes_by_row[invalid_rows[id] - 1]
        if preceding and not preceding.id and preceding.depth ~= rec.depth then
          return tree_refusal('child identity was replaced at a different tree depth', preceding.row, rec.path)
        end
      end
    end

    -- `cc` and whole-line replacements can invalidate an extmark even though
    -- the edit is a rename. Reattach an invalid identity only inside an unbroken
    -- sibling interval where removed and new rows pair one-for-one, bounded by
    -- surviving identities. If counts differ, that interval mixes uncertain
    -- renames with creates/deletes and is refused rather than guessed.
    for parent_id, expansion in pairs(state.expanded or {}) do
      if expansion_is_live(parent_id) then
        local old_children, current = {}, children_by_parent[parent_id] or {}
        for _, child in ipairs(expansion.children or {}) do
          if not undone_ids[child.id] then old_children[#old_children + 1] = child end
        end
        local current_index, old_index = {}, {}
        for index, node in ipairs(current) do
          if node.id then current_index[node.id] = index end
        end
        for index, child in ipairs(old_children) do
          old_index[child.id] = index
        end
        local anchors = {}
        for id, oi in pairs(old_index) do
          local ni = current_index[id]
          if ni then anchors[#anchors + 1] = { old = oi, new = ni } end
        end
        table.sort(anchors, function(a, b) return a.old < b.old end)
        local anchors_reordered = false
        for index = 2, #anchors do
          if anchors[index].new <= anchors[index - 1].new then
            anchors_reordered = true
            break
          end
        end
        if anchors_reordered then
          local has_unidentified_change = false
          for _, child in ipairs(old_children) do
            if invalid_ids[child.id] and not nodes_by_id[child.id] then
              has_unidentified_change = true
              break
            end
          end
          if not has_unidentified_change then
            for _, node in ipairs(current) do
              if not node.id then
                has_unidentified_change = true
                break
              end
            end
          end
          if has_unidentified_change then
            return tree_refusal(
              'reordered child identities cannot be safely paired with line replacements',
              first_unidentified_row(current)
            )
          end
        end
        local old_after, new_after = 0, 0
        local function pair_interval(old_before, new_before)
          local removed, inserted = {}, {}
          for oi = old_after + 1, old_before - 1 do
            local child = old_children[oi]
            if invalid_ids[child.id] and not nodes_by_id[child.id] then removed[#removed + 1] = child end
          end
          for ni = new_after + 1, new_before - 1 do
            local node = current[ni]
            if not node.id then inserted[#inserted + 1] = node end
          end
          if #removed > 0 and #inserted > 0 then
            if #removed ~= #inserted then
              return tree_refusal(
                'child row identities are ambiguous between rename and create/delete',
                inserted[1] and inserted[1].row or nil
              )
            end
            for pair = 1, #removed do
              local child, node = removed[pair], inserted[pair]
              node.id, node.rec = child.id, child
              nodes_by_id[child.id] = node
              invalid_ids[child.id] = nil
            end
          end
          return true
        end
        if not anchors_reordered then
          for _, anchor in ipairs(anchors) do
            local ok, pair_err, pair_context = pair_interval(anchor.old, anchor.new)
            if not ok then return nil, pair_err, pair_context end
            old_after, new_after = anchor.old, anchor.new
          end
          local ok, pair_err, pair_context = pair_interval(#old_children + 1, #current + 1)
          if not ok then return nil, pair_err, pair_context end
        end
      end
    end

    local lost_child_identity = false
    for id in pairs(invalid_ids) do
      local rec = state.rows[id]
      if rec and rec.kind == 'child' and not nodes_by_id[id] and not undone_ids[id] then
        lost_child_identity = true
        break
      end
    end
    if lost_child_identity then
      for id in pairs(invalid_ids) do
        local rec = state.rows[id]
        if rec and rec.kind == 'child' and not nodes_by_id[id] and not undone_ids[id] then
          for _, node in ipairs(nodes) do
            if node.depth == 0 and not node.id and node.row == invalid_rows[id] then
              return tree_refusal('child identity was lost while a root row was added', node.row, node.name)
            end
          end
        end
      end
    end

    local changed_parents = {}
    for parent_id, expansion in pairs(state.expanded or {}) do
      local parent = state.rows[parent_id]
      if parent and not parent.deleted_kind and nodes_by_id[parent_id] and expansion_is_live(parent_id) then
        local current = children_by_parent[parent_id] or {}
        local old_child_ids, old_children = {}, {}
        for _, child in ipairs(expansion.children or {}) do
          if not undone_ids[child.id] then
            old_children[#old_children + 1] = child
            old_child_ids[child.id] = true
          end
        end
        local changed = false
        for _, child in ipairs(old_children) do
          local now = nodes_by_id[child.id]
          if not now or now.name ~= child.name or now.parent_key ~= parent_id then
            changed = true
            break
          end
        end
        if not changed then
          for _, child in ipairs(current) do
            if not old_child_ids[child.id] then
              changed = true
              break
            end
          end
        end
        if changed then
          for _, child in ipairs(old_children) do
            local now = nodes_by_id[child.id]
            local edited = not now or now.name ~= child.name or now.parent_key ~= parent_id
            if edited and not child.deleted_kind then
              local disk_identity = fs.path_identity(child.path, fs.stat(child.path))
              if
                not child.identity
                or not disk_identity
                or not fs.path_identities_match(child.identity, disk_identity)
              then
                return tree_refusal(
                  'expanded directory entry changed on disk since it was read: '
                    .. tostring(child.path)
                    .. '; restore it or use :DirectList! to discard the edit and redo it',
                  now and now.row or invalid_rows[child.id],
                  child.path
                )
              end
            end
          end
          changed_parents[parent_id] = true
        end
      end
    end

    local function target_path(node)
      if node.depth == 0 then
        node.path = entry_path(state.root, node.name)
      else
        local parent = nodes_by_key[node.parent_key]
        if not parent or not is_dir_line(parent.name) then return nil end
        local parent_path = target_path(parent)
        if not parent_path then return nil end
        node.path = entry_path(parent_path, node.name)
      end
      return node.path
    end
    for _, node in ipairs(nodes) do
      if not target_path(node) then return tree_refusal('child row has no destination directory', node.row) end
    end

    local creates, moves, removals, yanks = {}, {}, {}, {}
    local planned_directories = {}
    local deleted_ids, moving_ids = {}, {}
    for id in pairs(root_ids) do
      local rec, node = state.rows[id], nodes_by_id[id]
      if
        rec
        and not rec.deleted_kind
        and node
        and is_dir_line(rec.name)
        and node.depth == 0
        and rec.name ~= node.name
      then
        -- Root-directory moves are emitted by the root identity plan. Mark them
        -- here so separate descendant edits cannot be staged against stale paths.
        moving_ids[id] = true
      end
    end
    for _, id in ipairs(state.display_ids or {}) do
      local rec = state.rows[id]
      if rec and rec.kind == 'child' and not rec.deleted_kind and not undone_ids[id] and not nodes_by_id[id] then
        deleted_ids[id] = true
      end
    end
    for id in pairs(deleted_ids) do
      local rec = state.rows[id]
      local ancestor = rec.parent
      local covered = false
      while ancestor do
        if deleted_ids[ancestor] then
          covered = true
          break
        end
        local parent_rec = state.rows[ancestor]
        ancestor = parent_rec and parent_rec.parent or nil
      end
      if not covered then
        yanks[#yanks + 1] = rec.path
        if is_dir_line(rec.name) then
          removals[#removals + 1] = action_mod.RemoveDirectory(rec.path)
        else
          removals[#removals + 1] = action_mod.Remove(rec.path)
        end
      end
    end

    local function under_deleted_parent(node)
      local parent_key = node.parent_key
      while parent_key do
        local parent = nodes_by_key[parent_key]
        if parent and parent.rec and parent.rec.deleted_kind then return true end
        parent_key = parent and parent.parent_key or nil
      end
      return false
    end

    for _, node in ipairs(nodes) do
      if not under_deleted_parent(node) and not (node.rec and node.rec.deleted_kind) then
        if not node.id then
          if node.depth > 0 then
            local destination = node.path
            if is_dir_line(node.name) then
              creates[#creates + 1] =
                { depth = node.depth, row = node.row, action = action_mod.MakeDirectory(destination) }
            else
              creates[#creates + 1] = { depth = node.depth, row = node.row, action = action_mod.Touch(destination) }
            end
          end
        else
          local rec = node.rec
          local moved_from_root = rec.kind == 'root' and node.depth > 0
          local child_changed = rec.kind == 'child'
            and (rec.parent ~= node.parent_key or rec.name ~= node.name or rec.depth ~= node.depth)
          if moved_from_root or child_changed then
            if is_dir_line(rec.name) ~= is_dir_line(node.name) and state.expanded[node.id] then
              return tree_refusal('cannot change the type of an expanded directory', node.row, node.path)
            end
            moving_ids[node.id] = true
            if moved_from_root and rec.collapsed_components and #rec.collapsed_components > 1 then
              local parent = nodes_by_key[node.parent_key]
              local destination_parent = parent and target_path(parent)
              if not destination_parent then return tree_refusal('child row has no destination directory', node.row) end
              local marker = node.name:sub(-1)
              local relative = strip_directory_marker(node.name)
              if marker == '\\' then relative = relative:gsub('\\', '/') end
              local names = {}
              for part in (relative .. '/'):gmatch('(.-)/') do
                names[#names + 1] = part
              end
              for index = 1, #names - 1 do
                local directory = entry_path(destination_parent, names[index] .. marker)
                local key = vim.fs.normalize(directory)
                if not planned_directories[key] then
                  if fs.taken(directory) then
                    if not fs.is_dir(directory) then
                      return tree_refusal('path parent is not a directory: ' .. directory, node.row, directory)
                    end
                  else
                    creates[#creates + 1] = {
                      depth = node.depth + index,
                      row = node.row,
                      action = action_mod.MakeDirectory(directory),
                    }
                    planned_directories[key] = true
                  end
                end
                destination_parent = directory
              end
            end
            moves[#moves + 1] = { depth = node.depth, row = node.row, action = action_mod.Move(rec.path, node.path) }
          end
        end
      end
    end

    -- A descendant whose own name/parent changes while an ancestor also moves
    -- needs ordered, path-dependent staging. Refuse that combination until the
    -- transaction scheduler can express its dependency explicitly.
    for _, node in ipairs(nodes) do
      if node.id and moving_ids[node.id] then
        local ancestor = node.parent_key
        while ancestor do
          if moving_ids[ancestor] then
            return tree_refusal('edit moved directories and their descendants in separate syncs', node.row, node.path)
          end
          local parent = nodes_by_key[ancestor]
          ancestor = parent and parent.parent_key or nil
        end
      end
    end
    local function moved_ancestor(parent_key)
      local ancestor = parent_key
      while ancestor do
        if moving_ids[ancestor] then return ancestor end
        local parent = nodes_by_key[ancestor]
        ancestor = parent and parent.parent_key or nil
      end
      return nil
    end
    for _, node in ipairs(nodes) do
      if not node.id and moved_ancestor(node.parent_key) then
        return tree_refusal('edit a moved directory and its new children in separate syncs', node.row, node.path)
      end
    end
    for id in pairs(deleted_ids) do
      local rec = state.rows[id]
      local ancestor = rec.parent
      while ancestor do
        if moving_ids[ancestor] then
          return tree_refusal(
            'edit a moved directory and its removed children in separate syncs',
            invalid_rows[id],
            rec.path
          )
        end
        local parent_rec = state.rows[ancestor]
        ancestor = parent_rec and parent_rec.parent or nil
      end
    end

    local source_paths = {}
    for _, item in ipairs(moves) do
      source_paths[#source_paths + 1] = item.action.src
    end
    local source_index = fs.path_identity_index(source_paths)
    for _, item in ipairs(creates) do
      if fs.taken(item.action.dst) then
        return tree_refusal('destination already exists: ' .. item.action.dst, item.row, item.action.dst)
      end
    end
    for _, item in ipairs(moves) do
      local source_target = fs.path_identity_index_contains(source_index, item.action.dst)
      if fs.taken(item.action.dst) and not source_target then
        return tree_refusal('move destination already exists: ' .. item.action.dst, item.row, item.action.dst)
      end
    end

    table.sort(creates, function(a, b) return a.depth < b.depth end)
    local actions = {}
    for _, item in ipairs(creates) do
      actions[#actions + 1] = item.action
    end
    for _, item in ipairs(moves) do
      actions[#actions + 1] = item.action
    end
    for _, action in ipairs(removals) do
      actions[#actions + 1] = action
    end
    local expanded_targets = {}
    for parent_id in pairs(state.expanded or {}) do
      local node = nodes_by_id[parent_id]
      if node and is_dir_line(node.name) then
        expanded_targets[#expanded_targets + 1] = {
          id = parent_id,
          path = target_path(node),
          depth = node.depth or 0,
        }
      end
    end
    table.sort(expanded_targets, function(a, b) return a.depth < b.depth end)
    return {
      root_lines = roots,
      root_rows = root_rows,
      actions = actions,
      yanks = yanks,
      changed_parents = changed_parents,
      nodes_by_id = nodes_by_id,
      expanded_targets = expanded_targets,
    }
  end
  M.children_integrity = children_integrity
  M.edited_subtrees = edited_subtrees
end

return M
