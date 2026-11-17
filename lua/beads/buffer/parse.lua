-- Buffer lines -> editable bead fields. Inverse of beads.buffer.render.
local M = {}

local SECTIONS = { Description = "description", Design = "design", Acceptance = "acceptance" }

local function list(v)
  local inner = v:match("^%[(.*)%]$") or v
  local out = {}
  for item in inner:gmatch("[^,]+") do
    item = vim.trim(item)
    if item ~= "" then
      out[#out + 1] = item
    end
  end
  return out
end

local function parse_frontmatter(lines, fields)
  local i = 2
  while i <= #lines and lines[i] ~= "---" do
    local key, value = lines[i]:match("^([%w_]+):%s*(.-)%s*$")
    if key then
      if key == "labels" or key == "blocked_by" then
        fields[key] = list(value)
      elseif key == "priority" then
        fields.priority = tonumber(value)
      elseif value ~= "" then
        fields[key] = value
      end
    end
    i = i + 1
  end
  return i + 1
end

---@param lines string[]
---@return table fields
function M.parse(lines)
  local fields = { labels = {}, blocked_by = {}, description = "", design = "", acceptance = "" }
  local start = 1
  if lines[1] == "---" then
    start = parse_frontmatter(lines, fields)
  end

  local current, buf = nil, {}
  local function flush()
    if current then
      if buf[#buf] == "" then
        buf[#buf] = nil
      end
      fields[current] = table.concat(buf, "\n")
    end
    buf = {}
  end

  -- Only the known section headings split the buffer; any other heading is content.
  -- A ``` opener is paired with the next fence only if that does not cross a real
  -- section boundary: any known heading between opener and closer must be followed
  -- (after the closer) by the next section's heading, otherwise the opener is unclosed
  -- and ignored so it cannot swallow later sections or pair across sections.
  local NEXT = { description = { "Design" }, design = { "Acceptance" }, acceptance = { "Workflow" } }
  local function known_heading(l)
    local h = l:match("^## (.-)%s*$")
    return h and (SECTIONS[h] or h == "Workflow" or h == "Notes" or h == "Comments") and h or nil
  end
  local function closer_for(i, sect)
    local j = i + 1
    local crossed = false
    while j <= #lines and not lines[j]:match("^```") do
      if known_heading(lines[j]) then
        crossed = true
      end
      j = j + 1
    end
    if j > #lines then
      return nil
    end
    if crossed then
      local wanted = NEXT[sect]
      local ok = false
      for k = j + 1, #lines do
        local h = known_heading(lines[k])
        if h and wanted and vim.tbl_contains(wanted, h) then
          ok = true
          break
        end
      end
      if not ok then
        return nil
      end
    end
    return j
  end
  local fenced = false
  local close_at
  for i = start, #lines do
    local l = lines[i]
    if l:match("^```") then
      if fenced then
        if i == close_at then
          fenced = false
        end
      else
        close_at = closer_for(i, current)
        fenced = close_at ~= nil
      end
    end
    local heading = not fenced and l:match("^## (.-)%s*$")
    local known = heading and (SECTIONS[heading] or heading == "Workflow" or heading == "Notes" or heading == "Comments")
    if known then
      flush()
      current = SECTIONS[heading]
      if not current then
        break
      end
    elseif current then
      buf[#buf + 1] = l
    elseif not fenced and fields.title == nil and l:match("^# ") then
      fields.title = l:sub(3)
    end
  end
  flush()
  return fields
end

return M
