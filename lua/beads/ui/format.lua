-- Shared bead line formatter used by the tree view and the pickers.
--   format(bead, opts) -> text, ranges
--   text:   "<status glyph> [<type icon>] <id> <P#> <title> <badges> [⛔ blocked by <id>...]"
--   ranges: { group, col, end_col } 0-based byte offsets, end exclusive (extmark friendly)
--   opts.blockers: list of ids appended as "⛔ blocked by <id>" markers
local glyphs = require("beads.glyphs")
local workflow = require("beads.workflow")

local M = {}

local STATUS_GROUPS = {
  open = "BeadsStatusOpen",
  in_progress = "BeadsStatusInProgress",
  blocked = "BeadsStatusBlocked",
  closed = "BeadsStatusClosed",
  deferred = "BeadsStatusDeferred",
}

local function user_badges()
  local g = vim.tbl_extend("force", workflow.default_glyphs, (require("beads").config.workflow or {}).glyphs or {})
  local set = {}
  for _, k in ipairs({ "human", "waiting", "needs_review" }) do
    if g[k] then
      set[g[k]] = true
    end
  end
  return set
end

function M.format(b, opts)
  opts = opts or {}
  local parts, ranges, len = {}, {}, 0
  local function add(s, group)
    if #parts > 0 then
      parts[#parts + 1] = " "
      len = len + 1
    end
    parts[#parts + 1] = s
    if group and #s > 0 then
      ranges[#ranges + 1] = { group = group, col = len, end_col = len + #s }
    end
    len = len + #s
  end
  local sg = glyphs.status(b.status)
  add(sg ~= "" and sg or "·", STATUS_GROUPS[b.status] or "BeadsDim")
  local icon = glyphs.type(b.type)
  if icon ~= "" then
    add(icon, "BeadsDim")
  end
  local id = b.id or ""
  add(id, "BeadsId")
  local p = b.priority
  add("P" .. tostring(p or "?"), (type(p) == "number" and p >= 0 and p <= 4) and ("BeadsPriority" .. p) or "BeadsDim")
  add(b.title or "", "BeadsTitle")
  local user = user_badges()
  for _, badge in ipairs(workflow.badges(b)) do
    add(badge, user[badge] and "BeadsBadgeUser" or "BeadsBadgeAgent")
  end
  for _, bid in ipairs(opts.blockers or {}) do
    add("⛔ blocked by " .. bid, "BeadsBlocked")
  end
  return table.concat(parts), ranges
end

M.SORTS = { "priority", "updated", "id" }

local function by_priority(a, b)
  local pa, pb = a.priority, b.priority
  if pa ~= pb then
    if pa == nil then
      return false
    end
    if pb == nil then
      return true
    end
    return pa < pb
  end
  return a.id < b.id
end

local COMPARE = {
  priority = by_priority,
  -- newest first (ISO timestamps compare as strings), missing last, ties by id
  updated = function(a, b)
    local ua, ub = a.updated_at, b.updated_at
    if ua ~= ub then
      if ua == nil then
        return false
      end
      if ub == nil then
        return true
      end
      return ua > ub
    end
    return a.id < b.id
  end,
  id = function(a, b)
    return a.id < b.id
  end,
}

-- Sort in place. mode: "priority" (default; ascending, nil last, ties by id), "updated", "id".
function M.sort(list, mode)
  table.sort(list, COMPARE[mode or "priority"] or by_priority)
  return list
end

-- Does bead b match the filter text? Whitespace separated terms, all must match:
-- status:/label:/assignee:/type: tokens (exact), anything else is a substring of id or title.
function M.matches(b, text)
  for term in (text or ""):gmatch("%S+") do
    local key, val = term:match("^(%a+):(.*)$")
    local ok
    if key == "status" then
      ok = b.status == val
    elseif key == "assignee" then
      ok = b.assignee == val
    elseif key == "type" then
      ok = b.type == val
    elseif key == "label" then
      ok = vim.tbl_contains(b.labels or {}, val)
    else
      ok = (b.id or ""):find(term, 1, true) ~= nil or (b.title or ""):find(term, 1, true) ~= nil
    end
    if not ok then
      return false
    end
  end
  return true
end

-- text with 24-bit ANSI colours from the resolved fg of each range's group (for fzf).
function M.ansi(text, ranges)
  local sorted = vim.list_extend({}, ranges)
  table.sort(sorted, function(a, b)
    return a.col < b.col
  end)
  local out, pos = {}, 0
  for _, r in ipairs(sorted) do
    out[#out + 1] = text:sub(pos + 1, r.col)
    local seg = text:sub(r.col + 1, r.end_col)
    local fg = vim.api.nvim_get_hl(0, { name = r.group, link = false }).fg
    if fg then
      seg = ("\27[38;2;%d;%d;%dm%s\27[0m"):format(math.floor(fg / 65536) % 256, math.floor(fg / 256) % 256, fg % 256, seg)
    end
    out[#out + 1] = seg
    pos = r.end_col
  end
  out[#out + 1] = text:sub(pos + 1)
  return table.concat(out)
end

return M
