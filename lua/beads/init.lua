local M = {}

M.defaults = {
  tree = { width = 50 },
  keys = {
    open = "<CR>",
    close = "q",
    refresh = "R",
    toggle = "<Tab>",
  },
  fzf = "auto",
}

M.config = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  if M.config.fzf == "auto" then
    M.config.fzf = pcall(require, "fzf-lua")
  end
  return M
end

return M
