-- Status glyphs and optional type icons, from setup({ glyphs = ..., type_icons = ... }).
local M = {}

M.defaults = { open = "○", in_progress = "◐", blocked = "●", closed = "✓", deferred = "❄" }
M.ascii = { open = "o", in_progress = "~", blocked = "x", closed = "v", deferred = "z" }

local function cfg()
  return require("beads").config
end

function M.status(status)
  local g = cfg().glyphs
  if g == "ascii" then
    g = M.ascii
  end
  g = type(g) == "table" and g or {}
  return g[status] or M.defaults[status] or ""
end

-- Type icons are off by default; enable with type_icons = { epic = "...", ... }.
function M.type(issue_type)
  local t = cfg().type_icons
  if type(t) == "table" then
    return t[issue_type] or ""
  end
  return ""
end

return M
