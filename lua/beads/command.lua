local M = {}

M.subcommands = { "tree", "ready", "list", "search", "needs", "epics", "show", "create", "cd" }

function M.run(args)
  local sub = args[1]
  if not sub or not vim.tbl_contains(M.subcommands, sub) then
    vim.notify("Usage: :Beads <" .. table.concat(M.subcommands, "|") .. ">", vim.log.levels.INFO)
    return
  end
  vim.notify("Beads " .. sub .. ": not implemented yet", vim.log.levels.WARN)
end

return M
