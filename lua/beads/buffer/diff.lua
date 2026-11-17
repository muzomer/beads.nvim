-- Snapshot bead vs parsed buffer -> bd operations. Only changed fields are emitted;
-- edits in read-only regions (id, Workflow, Notes, Comments) are discarded with a warning.
local parse = require("beads.buffer.parse")
local render = require("beads.buffer.render")

local M = {}

local function s(v)
  return v == nil and "" or tostring(v)
end

local function sorted(t)
  local out = vim.deepcopy(t or {})
  table.sort(out)
  return out
end

local function set_of(t)
  local out = {}
  for _, v in ipairs(t or {}) do
    out[v] = true
  end
  return out
end

-- Line ranges of the read-only regions, located by their headings after "## Acceptance".
local function region_texts(lines)
  local start = 1
  for i, l in ipairs(lines) do
    if l == "## Acceptance" then
      start = i
      break
    end
  end
  local pos, from = {}, start
  for _, name in ipairs({ "Workflow", "Notes", "Comments" }) do
    for i = from, #lines do
      if lines[i] == "## " .. name then
        pos[name] = i
        from = i + 1
        break
      end
    end
  end
  local out = {}
  local names = { "Workflow", "Notes", "Comments" }
  for k, name in ipairs(names) do
    if pos[name] then
      local last = #lines
      for j = k + 1, #names do
        if pos[names[j]] then
          last = pos[names[j]] - 1
          break
        end
      end
      out[name] = table.concat(lines, "\n", pos[name], last)
    end
  end
  return out
end

local function buffer_id(lines)
  if lines[1] ~= "---" then
    return nil
  end
  for i = 2, #lines do
    if lines[i] == "---" then
      return nil
    end
    local v = lines[i]:match("^id:%s*(.-)%s*$")
    if v then
      return v
    end
  end
end

function M.compute(bead, lines)
  local f = parse.parse(lines)
  local args = { "update", bead.id }
  local files = {}
  local warnings = {}

  local function field(flag, old, new)
    if s(old) ~= s(new) then
      args[#args + 1] = flag
      args[#args + 1] = s(new)
    end
  end

  field("--title", bead.title, f.title)
  field("--status", bead.status, f.status)
  field("--priority", bead.priority, f.priority)
  field("--type", bead.type, f.type)
  field("--assignee", bead.assignee, f.assignee)
  field("--parent", bead.parent, f.parent)
  field("--acceptance", bead.acceptance, f.acceptance)

  if not vim.deep_equal(sorted(bead.labels), sorted(f.labels)) then
    if #f.labels == 0 then
      -- bd ignores an empty --set-labels value, so remove labels one by one.
      for _, l in ipairs(bead.labels or {}) do
        args[#args + 1] = "--remove-label"
        args[#args + 1] = l
      end
    else
      args[#args + 1] = "--set-labels"
      args[#args + 1] = table.concat(f.labels, ",")
    end
  end

  if s(bead.description) ~= s(f.description) then
    files["--body-file"] = f.description
  end
  if s(bead.design) ~= s(f.design) then
    files["--design-file"] = f.design
  end

  local deps = {}
  local old, new = set_of(bead.blocked_by), set_of(f.blocked_by)
  for _, d in ipairs(f.blocked_by) do
    if not old[d] then
      deps[#deps + 1] = ("dep add %s %s blocks"):format(bead.id, d)
    end
  end
  for _, d in ipairs(bead.blocked_by or {}) do
    if not new[d] then
      deps[#deps + 1] = ("dep remove %s %s"):format(bead.id, d)
    end
  end

  local bid = buffer_id(lines)
  if bid ~= nil and bid ~= bead.id then
    warnings[#warnings + 1] = "id is read-only; edit ignored"
  end
  local want = region_texts((render.render(bead)))
  local got = region_texts(lines)
  for _, name in ipairs({ "Workflow", "Notes", "Comments" }) do
    if want[name] ~= got[name] then
      warnings[#warnings + 1] = name .. " is read-only; edit ignored"
    end
  end

  local update
  if #args > 2 or next(files) ~= nil then
    update = { args = args, files = files }
  end
  return { update = update, deps = deps, warnings = warnings }
end

function M.create(lines)
  local f = parse.parse(lines)
  local args = { "create", "--title", f.title or "" }
  local files = {}
  local function add(flag, v)
    if v ~= nil and v ~= "" then
      args[#args + 1] = flag
      args[#args + 1] = tostring(v)
    end
  end
  add("-t", f.type)
  add("-p", f.priority)
  add("-a", f.assignee)
  add("--parent", f.parent)
  if #f.labels > 0 then
    add("-l", table.concat(f.labels, ","))
  end
  if #f.blocked_by > 0 then
    local d = {}
    for _, id in ipairs(f.blocked_by) do
      d[#d + 1] = "blocks:" .. id
    end
    add("--deps", table.concat(d, ","))
  end
  add("--acceptance", f.acceptance)
  if f.description ~= "" then
    files["--body-file"] = f.description
  end
  if f.design ~= "" then
    files["--design-file"] = f.design
  end
  return { args = args, files = files }
end

return M
