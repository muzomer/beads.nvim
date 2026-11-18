-- Bead -> buffer lines (YAML-style frontmatter + markdown sections) with read-only regions.
local workflow = require("beads.workflow")

local M = {}

local function push_text(lines, text)
  if text ~= nil and text ~= "" then
    for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
      lines[#lines + 1] = l
    end
  end
  lines[#lines + 1] = ""
end

local function list(v)
  return "[" .. table.concat(v or {}, ", ") .. "]"
end

local function frontmatter(lines, b, with_id)
  lines[#lines + 1] = "---"
  if with_id then
    lines[#lines + 1] = "id: " .. b.id
  end
  lines[#lines + 1] = "status: " .. (b.status or "")
  lines[#lines + 1] = "priority: " .. tostring(b.priority == nil and 2 or b.priority)
  lines[#lines + 1] = "type: " .. (b.type or "task")
  lines[#lines + 1] = "assignee: " .. (b.assignee or "")
  lines[#lines + 1] = "labels: " .. list(b.labels)
  lines[#lines + 1] = "parent: " .. (b.parent or "")
  lines[#lines + 1] = "blocked_by: " .. list(b.blocked_by)
  lines[#lines + 1] = "---"
end

local function editable_sections(lines, b)
  lines[#lines + 1] = "# " .. (b.title or "")
  lines[#lines + 1] = "## Description"
  push_text(lines, b.description)
  lines[#lines + 1] = "## Design"
  push_text(lines, b.design)
  lines[#lines + 1] = "## Acceptance"
  push_text(lines, b.acceptance)
end

local function flat(v)
  return (tostring(v):gsub("\n", " "))
end

local function time(created)
  if type(created) ~= "string" then
    return ""
  end
  local date, hm = created:match("^(%d%d%d%d%-%d%d%-%d%d)[T ](%d%d:%d%d)")
  if date then
    return date .. " " .. hm
  end
  return created
end

-- One Questions line: "- [needs] preview", preview = first line of the first message.
function M.thread_line(t)
  local needs = "-"
  if t.status == "resolved" then
    needs = "done"
  elseif t.needs == "agent" then
    needs = "agent"
  elseif t.needs == "user" then
    needs = "you"
  end
  local first = t.messages and t.messages[1]
  local preview = vim.split((first and first.body) or "", "\n", { plain = true })[1] or ""
  return ("- [%s]%s %s"):format(needs, t.human and " (human)" or "", preview)
end

function M.render(bead)
  local lines, regions = {}, {}
  frontmatter(lines, bead, true)
  regions[#regions + 1] = { name = "id", first = 2, last = 2 }
  editable_sections(lines, bead)

  local first = #lines + 1
  lines[#lines + 1] = "## Workflow"
  for _, f in ipairs(workflow.fields(bead)) do
    lines[#lines + 1] = f.name .. ": " .. flat(f.value)
  end
  lines[#lines + 1] = ""
  regions[#regions + 1] = { name = "workflow", first = first, last = #lines }

  first = #lines + 1
  lines[#lines + 1] = "## Notes"
  push_text(lines, bead.notes)
  regions[#regions + 1] = { name = "notes", first = first, last = #lines }

  first = #lines + 1
  lines[#lines + 1] = "## Comments"
  for _, c in ipairs(bead.comments or {}) do
    lines[#lines + 1] = "### " .. (c.author or "") .. " - " .. time(c.created_at)
    push_text(lines, c.text)
  end
  regions[#regions + 1] = { name = "comments", first = first, last = #lines }

  if bead.threads and #bead.threads > 0 then
    first = #lines + 1
    lines[#lines + 1] = "## Questions"
    for _, t in ipairs(bead.threads) do
      lines[#lines + 1] = M.thread_line(t)
    end
    regions[#regions + 1] = { name = "questions", first = first, last = #lines }
  end
  return lines, regions
end

function M.template(opts)
  opts = opts or {}
  local lines = {}
  frontmatter(lines, { status = "open", priority = 2, type = "task", parent = opts.parent }, false)
  editable_sections(lines, {})
  return lines, {}
end

return M
