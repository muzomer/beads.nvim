local M = {}

M.subcommands = { "tree", "ready", "list", "search", "needs", "epics", "questions", "show", "create", "cd", "poke", "output", "chat" }

-- Pass-through to agent-poke.nvim (required at the moment of use).
function M.agent(sub, arg)
  local root = require("beads.cli").get_root()
  if sub == "poke" and arg ~= "pick" then
    local ids = {}
    for _, t in ipairs(require("beads.questions.store").list(root, { status = "open", needs = "agent" })) do
      ids[#ids + 1] = t.id
    end
    if #ids == 0 then
      vim.notify("Beads: no thread is waiting on the agent", vim.log.levels.INFO)
      return
    end
    require("beads.workflow").deliver(
      root,
      "Question threads waiting on you: "
        .. table.concat(ids, ", ")
        .. ". Read each thread and answer with the beads-ask CLI:\n"
        .. "  beads-ask reply <thread-id> <body|->",
      nil
    )
    return
  end
  local ok, ap = pcall(require, "agent-poke")
  if not ok or type(ap) ~= "table" then
    vim.notify(
      "Beads: " .. sub .. ": agent-poke.nvim is not installed (https://github.com/muzomer/agent-poke.nvim)",
      vim.log.levels.WARN
    )
    return
  end
  if sub == "poke" then
    ap.pick(root)
  else
    ap[sub](root)
  end
end

function M.run(args)
  local sub = args[1]
  if not sub or not vim.tbl_contains(M.subcommands, sub) then
    vim.notify("Beads: usage :Beads <" .. table.concat(M.subcommands, "|") .. ">", vim.log.levels.INFO)
    return
  end
  if sub == "cd" then
    local path = args[2]
    if not path or path == "" then
      vim.notify("Beads: root " .. require("beads.cli").get_root(), vim.log.levels.INFO)
      return
    end
    require("beads.cli").set_root(vim.fn.fnamemodify(vim.fn.expand(path), ":p"))
    return
  end
  if sub == "show" then
    local id = args[2]
    if not id or id == "" then
      vim.notify("Beads: usage :Beads show <id>", vim.log.levels.INFO)
      return
    end
    vim.cmd.edit(vim.fn.fnameescape("beads://" .. id))
    return
  end
  if sub == "poke" or sub == "output" or sub == "chat" then
    M.agent(sub, args[2])
    return
  end
  if sub == "tree" then
    require("beads.views.tree").toggle(args[2])
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
end

return M
