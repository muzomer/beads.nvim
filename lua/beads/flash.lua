-- Brief BeadsFlash line highlight on the cursor line of a window (jump landing marker).
local M = {}

local NS = vim.api.nvim_create_namespace("beads_flash")

-- Flashes the cursor line of `win` (default: current) for setup({ flash_ms }) ms (default 350; false disables).
function M.flash(win)
  local ms = require("beads").config.flash_ms
  if ms == false then
    return
  end
  ms = tonumber(ms) or 350
  win = win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local row = vim.api.nvim_win_get_cursor(win)[1] - 1
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, buf, NS, row, 0, {
    line_hl_group = "BeadsFlash",
    priority = 300,
  })
  if not ok then
    return
  end
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_del_extmark, buf, NS, id)
    end
  end, ms)
end

return M
