-- LSP file-operation helpers used by history reversal.
-- The filesystem action module is injected to keep URI construction aligned
-- with the same absolute-path handling as the action owner.

return function(context)
  local action = context.action

  local function rename_files(current, files, paths)
    if current.name == 'mv' then
      files[#files + 1] = {
        oldUri = vim.uri_from_fname(action.fs.abspath(current.src)),
        newUri = vim.uri_from_fname(action.fs.abspath(current.dst)),
      }
      paths[#paths + 1] = current.src
      paths[#paths + 1] = current.dst
    elseif current.name == 'g' or current.name == 'batch' then
      for _, member in ipairs(current.actions or {}) do
        rename_files(member, files, paths)
      end
    end
  end

  return { rename_files = rename_files }
end
