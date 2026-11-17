-- Normalizes `bd show --json` and `bd list --json` items into one Bead model.
local M = {}

local function val(v)
  if v == nil or v == vim.NIL then
    return nil
  end
  return v
end

local function tbl(v)
  v = val(v)
  if type(v) == "table" then
    return v
  end
  return {}
end

---@param item table decoded bead from bd show/list
---@return table bead
function M.normalize(item)
  item = tbl(item)
  local blocked_by, parent, children = {}, nil, {}
  for _, d in ipairs(tbl(item.dependencies)) do
    if type(d) == "table" then
      local kind = val(d.dependency_type) or val(d.type)
      local target = val(d.depends_on_id) or val(d.id)
      if kind == "blocks" and target then
        blocked_by[#blocked_by + 1] = target
      elseif kind == "parent-child" and target and not parent then
        parent = target
      end
    end
  end
  for _, d in ipairs(tbl(item.dependents)) do
    if type(d) == "table" and val(d.dependency_type) == "parent-child" and val(d.id) then
      children[#children + 1] = d.id
    end
  end
  return {
    id = val(item.id),
    title = val(item.title),
    status = val(item.status),
    priority = val(item.priority),
    type = val(item.issue_type),
    assignee = val(item.assignee),
    labels = tbl(item.labels),
    parent = val(item.parent) or parent,
    description = val(item.description),
    design = val(item.design),
    acceptance = val(item.acceptance_criteria),
    notes = val(item.notes),
    comments = tbl(item.comments),
    metadata = tbl(item.metadata),
    updated_at = val(item.updated_at),
    blocked_by = blocked_by,
    children = children,
  }
end

function M.normalize_all(items)
  local out = {}
  for i, it in ipairs(tbl(items)) do
    out[i] = M.normalize(it)
  end
  return out
end

return M
