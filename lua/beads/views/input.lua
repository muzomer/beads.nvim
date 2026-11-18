-- Floating multi-line input box (keymaps.input): used to ask questions and to reply in threads.
local keys = require("beads.keys")

local M = {}

-- opts: { title = string, on_submit = function(text, send) } ; send is true for the "send" key.
-- Empty text closes the box and stores nothing.
function M.open(opts)
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[fbuf].buftype = "acwrite"
  vim.bo[fbuf].bufhidden = "wipe"
  vim.bo[fbuf].filetype = "markdown"
  vim.api.nvim_buf_set_name(fbuf, "beads-input:" .. fbuf)
  local width = math.min(70, math.max(20, vim.o.columns - 4))
  local height = 8
  local win = vim.api.nvim_open_win(fbuf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = (" %s (%s save, %s send, %s cancel) "):format(
      opts.title,
      keys.first("input", "submit") or "",
      keys.first("input", "send") or "",
      keys.first("input", "cancel") or ""
    ),
  })
  vim.wo[win].wrap = true
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  local function finish(send)
    return function()
      local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false), "\n"))
      vim.bo[fbuf].modified = false
      close()
      if text ~= "" then
        opts.on_submit(text, send)
      end
    end
  end
  vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = fbuf, callback = finish(false) })
  keys.bind_input(fbuf, finish(false), close, finish(true))
  vim.cmd("startinsert")
  return win
end

return M
