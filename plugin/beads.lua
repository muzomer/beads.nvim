if vim.g.loaded_beads == 1 and vim.fn.exists(":Beads") == 2 then
  return
end
vim.g.loaded_beads = 1

local SUBCOMMANDS = { "tree", "ready", "list", "search", "needs", "epics", "show", "create", "cd" }

vim.api.nvim_create_user_command("Beads", function(opts)
  require("beads.command").run(opts.fargs)
end, {
  nargs = "*",
  desc = "Beads issue tracker",
  complete = function(arglead, cmdline)
    local n = #vim.split(vim.trim(cmdline), "%s+")
    if n > 2 or (n == 2 and cmdline:match("%s$")) then
      return {}
    end
    return vim.tbl_filter(function(s)
      return vim.startswith(s, arglead)
    end, SUBCOMMANDS)
  end,
})

local group = vim.api.nvim_create_augroup("BeadsDetail", { clear = true })
vim.api.nvim_create_autocmd("BufReadCmd", {
  group = group,
  pattern = "beads://*",
  callback = function(args)
    require("beads.views.detail").load(args.buf)
  end,
})
vim.api.nvim_create_autocmd("BufWriteCmd", {
  group = group,
  pattern = "beads://*",
  callback = function(args)
    require("beads.buffer.write").write(args.buf)
  end,
})
