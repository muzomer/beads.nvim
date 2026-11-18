local M = {}

M.defaults = {
  tree = { position = "left", width = nil, height = nil }, -- width/height: computed at open
  keymaps = require("beads.keys").default_map(), -- key, list of keys or false; false disables all
  fzf = "auto",
  glyphs = {}, -- { open, in_progress, blocked, closed, deferred } overrides, or "ascii"
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
  return M
end

-- "view" | "edit" for a beads detail buffer, "" elsewhere (statusline-friendly).
function M.mode()
  return vim.b.beads_mode or ""
end

return M
