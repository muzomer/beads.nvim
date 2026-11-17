local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/?.lua;" .. package.path

local candidates = {
  vim.env.PLENARY_DIR,
  root .. "/.deps/plenary.nvim",
  vim.fn.stdpath("data") .. "/site/pack/core/opt/plenary.nvim",
  vim.fn.stdpath("data") .. "/lazy/plenary.nvim",
}
local found
for _, p in ipairs(candidates) do
  if p and p ~= "" and vim.fn.isdirectory(p) == 1 then
    found = p
    break
  end
end
if not found then
  found = root .. "/.deps/plenary.nvim"
  vim.fn.system({ "git", "clone", "--depth=1", "https://github.com/nvim-lua/plenary.nvim", found })
end
vim.opt.runtimepath:prepend(found)
vim.cmd("runtime plugin/plenary.vim")
vim.o.swapfile = false
