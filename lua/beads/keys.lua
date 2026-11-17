-- Buffer-local keymaps: defaults per view, setup({ keys = { <view> = { <action> = lhs|false } } })
-- overrides, and the g? help float. Never sets global maps.
local M = {}

-- Ordered: { action, default lhs, desc }
M.defaults = {
  tree = {
    { "open", "<CR>", "open bead in the previous window" },
    { "add_child", "a", "add child bead" },
    { "close_bead", "x", "close bead (prompts for a reason)" },
    { "claim", "C", "claim bead" },
    { "refresh", "R", "refresh" },
    { "toggle_closed", "H", "toggle closed beads" },
    { "yank_id", "yy", "yank bead id" },
    { "yank_run", "yr", "yank workflow run command" },
    { "close", "q", "close tree" },
    { "help", "g?", "show this help" },
  },
  detail = {
    { "close_bead", "x", "close bead (prompts for a reason)" },
    { "claim", "C", "claim bead" },
    { "note", "n", "append a note (float)" },
    { "comment", "c", "add a comment (float)" },
    { "yank_id", "yy", "yank bead id" },
    { "yank_run", "yr", "yank workflow run command" },
    { "help", "g?", "show this help" },
  },
}

-- { view = { action = default lhs } } for the config defaults.
function M.default_map()
  local out = {}
  for view, list in pairs(M.defaults) do
    out[view] = {}
    for _, d in ipairs(list) do
      out[view][d[1]] = d[2]
    end
  end
  return out
end

local EXTRA = {
  tree = { "za/zo/zc  fold" },
}

-- Returns the active { action, lhs, desc } list for a view (disabled actions dropped).
function M.resolve(view)
  local cfg = ((require("beads").config.keys or {})[view]) or {}
  local out = {}
  for _, d in ipairs(M.defaults[view]) do
    local lhs = d[2]
    if type(cfg) == "table" and cfg[d[1]] ~= nil then
      lhs = cfg[d[1]]
    end
    if type(lhs) == "string" and lhs ~= "" then
      out[#out + 1] = { d[1], lhs, d[3] }
    end
  end
  return out
end

local function help_float(view)
  local lines = {}
  for _, k in ipairs(M.resolve(view)) do
    lines[#lines + 1] = string.format("%-6s %s", k[2], k[3])
  end
  vim.list_extend(lines, EXTRA[view] or {})
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local width = 10
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 1, math.max(10, vim.o.columns - 4))
  local height = math.min(#lines, math.max(1, vim.o.lines - 4))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " Beads " .. view .. " keys ",
  })
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, lhs in ipairs({ "q", "<Esc>", "g?" }) do
    vim.keymap.set("n", lhs, close, { buffer = buf, nowait = true, silent = true, desc = "Beads: close help" })
  end
end

-- Binds the actions of a view on buf. actions: action name -> function.
-- The "help" action is provided here.
function M.bind(buf, view, actions)
  actions = vim.tbl_extend("keep", actions, {
    help = function()
      help_float(view)
    end,
  })
  for _, k in ipairs(M.resolve(view)) do
    local fn = actions[k[1]]
    if fn then
      vim.keymap.set("n", k[2], fn, {
        buffer = buf,
        nowait = true,
        silent = true,
        desc = "Beads " .. view .. ": " .. k[3],
      })
    end
  end
end

return M
