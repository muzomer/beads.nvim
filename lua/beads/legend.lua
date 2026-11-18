-- Symbol legend for the help float and README: built from the active (possibly overridden) glyphs.
local M = {}

local STATUSES = {
  { "open", "open" },
  { "in_progress", "in progress" },
  { "blocked", "blocked" },
  { "closed", "closed" },
  { "deferred", "deferred" },
}

local BADGES = {
  { "clean", "review clean" },
  { "issues", "review found issues (rN = review round)" },
  { "gate_pass", "gate pass" },
  { "gate_fail", "gate fail" },
  { "human", "needs a human" },
  { "needs_review", "needs review" },
  { "parked", "parked" },
  { "waiting", "waiting on you" },
}

local function row(glyph, meaning)
  return string.format("%-6s %s", glyph, meaning)
end

-- group: keys group of the help float (tree_view, detail_view, detail_edit, ...) or nil/global.
function M.lines(group)
  local g = require("beads.glyphs")
  local wf = require("beads.workflow")
  local user = require("beads").config.workflow
  local badge = vim.tbl_extend("force", wf.default_glyphs, user and user.glyphs or {})
  local out = {}
  for _, s in ipairs(STATUSES) do
    out[#out + 1] = row(g.status(s[1]), s[2])
  end
  if group ~= "detail_view" and group ~= "detail_edit" then
    out[#out + 1] = row("·", "unknown status")
  end
  if group == "tree_view" then
    for _, b in ipairs(BADGES) do
      out[#out + 1] = row(badge[b[1]], b[2])
    end
    out[#out + 1] = row("▾", "expanded (has children)")
    out[#out + 1] = row("▸", "folded (has children)")
    out[#out + 1] = row("⛔", "blocked by another bead")
    out[#out + 1] = row("│ ├ └", "tree guides (nesting)")
    out[#out + 1] = row("▍", "marked for a group action (m / M)")
  elseif group == "detail_view" or group == "detail_edit" then
    out[#out + 1] = row("[+]", "modified (unsaved edits)")
    out[#out + 1] = row("⚠", "changed on disk")
  end
  return out
end

return M
