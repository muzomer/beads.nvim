local M = {}

M.subcommands = { "tree", "ready", "list", "search", "needs", "epics", "questions", "show", "create", "cd" }

function M.run(args)
  local sub = args[1]
  if not sub or not vim.tbl_contains(M.subcommands, sub) then
    vim.notify("Usage: :Beads <" .. table.concat(M.subcommands, "|") .. ">", vim.log.levels.INFO)
    return
  end
  if sub == "cd" then
    local path = args[2]
    if not path or path == "" then
      vim.notify("Beads root: " .. require("beads.cli").get_root(), vim.log.levels.INFO)
      return
    end
    require("beads.cli").set_root(vim.fn.fnamemodify(vim.fn.expand(path), ":p"))
    return
  end
  if sub == "show" then
    local id = args[2]
    if not id or id == "" then
      vim.notify("Usage: :Beads show <id>", vim.log.levels.INFO)
      return
    end
    vim.cmd.edit(vim.fn.fnameescape("beads://" .. id))
    return
  end
  if sub == "tree" then
    require("beads.views.tree").toggle()
    return
  end
  if sub == "questions" then
    require("beads.views.questions").open()
    return
  end
  if sub == "create" then
    require("beads.views.detail").open_new()
    return
  end
  if vim.tbl_contains(require("beads.views.picker").sources, sub) then
    local query = #args > 1 and table.concat(vim.list_slice(args, 2), " ") or nil
    require("beads.views.picker").open(sub, query)
    return
  end
  vim.notify("Beads " .. sub .. ": not implemented yet", vim.log.levels.WARN)
end

return M
