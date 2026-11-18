local M = {}

M.defaults = {
  tree = { position = "left", width = "auto", height = "auto", max_width = nil, max_height = nil }, -- auto fits the content; max_*: caps (default half the columns / 40% of the lines)
  keymaps = require("beads.keys").default_map(), -- key, list of keys or false; false disables all
  mouse = true, -- tree: click selects/opens/folds; false installs no mouse maps
  fzf = "auto",
  glyphs = {}, -- { open, in_progress, blocked, closed, deferred } overrides, or "ascii"
  flash_ms = 350, -- jump flash duration in ms; false disables
  notify = true, -- false silences the grouped "changed externally" notifications
  notify_group_ms = 1500, -- external changes within this window are reported in one notification
  type_icons = false, -- or { epic = "", bug = "", feature = "", task = "", chore = "" }
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
  opts = opts or {}
  local keys = require("beads.keys")
  local over_keymaps = opts.keymaps
  local rest = vim.deepcopy(opts)
  rest.keymaps = nil
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), rest)
  if over_keymaps == nil then
    M.config.keymaps = vim.deepcopy(M.defaults.keymaps)
  else
    M.config.keymaps = keys.merge(vim.deepcopy(M.defaults.keymaps), over_keymaps)
  end
  if M.config.fzf == "auto" then
    M.config.fzf = pcall(require, "fzf-lua")
  end
  keys.setup_globals()
  require("beads.highlights").setup()
  require("beads.views.tree").setup_current()
  return M
end

-- "view" | "edit" for a beads detail buffer, "" elsewhere (statusline-friendly).
function M.mode()
  return vim.b.beads_mode or ""
end

-- Short statusline text from the store of the current root; never spawns bd.
function M.status()
  local g = require("beads.glyphs")
  local state = require("beads.store").get(require("beads.cli").get_root())
  local ip, waiting = 0, 0
  for _, b in pairs(state.by_id) do
    if b.status == "in_progress" then
      ip = ip + 1
    end
    if b.waiting_user then
      waiting = waiting + 1
    end
  end
  return ("%s %d  %s %d ready  💬 %d"):format(g.status("in_progress"), ip, g.status("open"), state.ready_n or 0, waiting)
end

-- lualine component: lualine_x = { require("beads").lualine }
M.lualine = {
  function()
    return M.status()
  end,
}

return M
