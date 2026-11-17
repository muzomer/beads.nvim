local M = {}

M.defaults = {
  tree = { width = 50 },
  keys = require("beads.keys").default_map(), -- keys.<view>.<action> = lhs|false
  fzf = "auto",
}

M.config = vim.deepcopy(M.defaults)

local function add_bin_to_path()
  local src = debug.getinfo(1, "S").source:sub(2)
  local bin = vim.fn.fnamemodify(src, ":p:h:h:h") .. "/bin"
  local path = vim.env.PATH or ""
  for _, p in ipairs(vim.split(path, ":", { plain = true })) do
    if p == bin then
      return
    end
  end
  vim.env.PATH = bin .. ":" .. path
end

function M.setup(opts)
  add_bin_to_path()
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  if M.config.fzf == "auto" then
    M.config.fzf = pcall(require, "fzf-lua")
  end
  return M
end

return M
