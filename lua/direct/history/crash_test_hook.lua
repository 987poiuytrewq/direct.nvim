-- Test-only crash checkpoints. This module intentionally has no setup() API:
-- production behavior is unchanged unless one of the test environment
-- variables is present.
local M = {}

function M.checkpoint(label)
  local crash_at = os.getenv('DIRECT_TEST_CRASH_AT')
  local trace_path = os.getenv('DIRECT_TEST_CRASH_TRACE')
  if not crash_at and not trace_path then return end

  if trace_path and trace_path ~= '' then
    local file, open_err = io.open(trace_path, 'ab')
    if not file then error('could not open crash-test trace: ' .. tostring(open_err)) end
    local written, write_err = file:write(label, '\n')
    if not written then
      file:close()
      error('could not write crash-test trace: ' .. tostring(write_err))
    end
    local flushed, flush_err = file:flush()
    local closed, close_err = file:close()
    if not flushed then error('could not flush crash-test trace: ' .. tostring(flush_err)) end
    if not closed then error('could not close crash-test trace: ' .. tostring(close_err)) end
  end

  if crash_at == label then os.exit(86) end
end

return M
