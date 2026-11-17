local M = {}

M.defaults = {
  tree = { width = 50 },
  keys = require("beads.keys").default_map(), -- keys.<view>.<action> = lhs|false
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
