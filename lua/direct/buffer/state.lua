-- Shared buffer state and sync lifecycle hooks.
-- Row identities stay owned by rows.lua; this module exposes their store beside
-- state shared directly by the buffer facade and standalone feature modules.

local rows = require('direct.buffer.rows')

return {
  states = rows.states,
  namespace = rows.namespace,
  pending_sync = {},
  restore_deleted_rows = nil,
  reconcile_undone_materialization = nil,
  sync_plan = nil,
  tree_plan = nil,
  collapse_single_entry_paths = nil,
}
