-- Shared group actions (the A menu): used by the tree and the fzf pickers. new(get_root, on_done)
-- returns { act, yank, menu }; on_done(ids, failed_ids) runs after every group run.
local store = require("beads.store")
local workflow = require("beads.workflow")

local M = {}

function M.new(get_root, on_done)
  local self = {}
  local v = setmetatable({}, { __index = function(_, k)
    if k == "root" then
      return get_root()
    end
  end })
  local function group_run(op, ids, opts)
    require("beads.group").run(v.root, op, ids, opts, function(failed)
      if on_done then
        on_done(ids, failed)
      end
    end)
  end
  local function confirm(label, ids, cb)
    local n = #ids
    local lines
    if n > 5 then
      local by_id = store.get(v.root).by_id or {}
      lines = {}
      for _, id in ipairs(ids) do
        lines[#lines + 1] = id .. "  " .. ((by_id[id] and by_id[id].title) or "")
      end
    end
    require("beads.group").confirm(label, n, cb, lines)
  end
  local function act(op, given)
    local ids = given
    if #ids == 0 then
      return
    end
    confirm(op, ids, function()
      if op == "close" then
        vim.ui.input({ prompt = "Close reason (optional): " }, function(reason)
          if reason ~= nil then
            group_run("close", ids, { reason = reason })
          end
        end)
      else
        group_run(op, ids)
      end
    end)
  end
  -- Group field / label / parent / dependency actions: the value is asked once, then the
  -- confirmation, then one bd batch or one bd update per bead.
  local function quote_val(s)
    if s:find('[%s"]') then
      return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
    end
    return s
  end
  local function pick(prompt, list, fmt, cb)
    vim.ui.select(list, { prompt = prompt, format_item = fmt }, function(choice)
      if choice ~= nil then
        cb(choice)
      end
    end)
  end
  local function ask(prompt, cb)
    vim.ui.input({ prompt = prompt }, function(text)
      text = text and vim.trim(text) or ""
      if text ~= "" then
        cb(text)
      end
    end)
  end
  local function beads_of(ids)
    local by_id = store.get(v.root).by_id
    local out = {}
    for _, id in ipairs(ids) do
      out[#out + 1] = by_id[id] or { id = id, labels = {}, blocked_by = {} }
    end
    return out
  end
  local function ordered_by_id(list)
    return require("beads.group").sort_by_id(list)
  end
  local function field_batch(ids, key, value)
    local lines = {}
    for _, id in ipairs(ids) do
      lines[#lines + 1] = ("update %s %s=%s"):format(id, key, quote_val(value))
    end
    confirm("Set " .. key .. " on", ids, function()
      group_run("batch", ids, { lines = lines })
    end)
  end
  local function per_bead(ids, label, flags)
    confirm(label, ids, function()
      group_run("update", ids, { flags = flags })
    end)
  end
  local function dep_batch(ids, op, x)
    local lines = {}
    for _, id in ipairs(ids) do
      lines[#lines + 1] = op == "add" and ("dep add %s %s blocks"):format(id, x) or ("dep remove %s %s"):format(id, x)
    end
    local label = op == "add" and ("Block by " .. x .. " on") or ("Remove dependency " .. x .. " from")
    confirm(label, ids, function()
      group_run("batch", ids, { lines = lines })
    end)
  end
  local function bead_label(b)
    return b.id .. "  " .. (b.title or "")
  end
  local function field_action(k, ids)
    if k == "set_priority" then
      local list = { "P0 critical", "P1 high", "P2 medium", "P3 low", "P4 backlog" }
      pick("Priority: ", list, tostring, function(c)
        field_batch(ids, "priority", c:match("^P(%d)"))
      end)
    elseif k == "set_status" then
      pick("Status: ", { "open", "in_progress", "blocked", "deferred", "closed" }, tostring, function(c)
        field_batch(ids, "status", c)
      end)
    elseif k == "set_assignee" then
      ask("Assignee: ", function(t)
        field_batch(ids, "assignee", t)
      end)
    elseif k == "set_type" then
      pick("Type: ", { "task", "bug", "feature", "epic", "chore" }, tostring, function(c)
        per_bead(ids, "Set type on", { "--type", c })
      end)
    elseif k == "add_label" then
      ask("Label to add: ", function(t)
        per_bead(ids, "Add label " .. t .. " to", { "--add-label", t })
      end)
    elseif k == "remove_label" then
      local seen, list = {}, {}
      for _, b in ipairs(beads_of(ids)) do
        for _, l in ipairs(b.labels or {}) do
          if not seen[l] then
            seen[l] = true
            list[#list + 1] = l
          end
        end
      end
      list = vim.fn.sort(list)
      if #list == 0 then
        return vim.notify("Beads: the selected beads have no labels", vim.log.levels.INFO)
      end
      pick("Label to remove: ", list, tostring, function(c)
        per_bead(ids, "Remove label " .. c .. " from", { "--remove-label", c })
      end)
    elseif k == "set_parent" then
      local sel, epics = {}, {}
      for _, id in ipairs(ids) do
        sel[id] = true
      end
      local all = store.get(v.root).by_id
      local function below_selected(b)
        local seen, p = {}, b.parent
        while p and not seen[p] do
          if sel[p] then
            return true
          end
          seen[p] = true
          p = all[p] and all[p].parent
        end
        return false
      end
      for _, b in pairs(all) do
        if b.type == "epic" and b.status ~= "closed" and not sel[b.id] and not below_selected(b) then
          epics[#epics + 1] = b
        end
      end
      if #epics == 0 then
        return vim.notify("Beads: no epics to move under", vim.log.levels.INFO)
      end
      pick("Move under epic: ", ordered_by_id(epics), bead_label, function(c)
        per_bead(ids, "Move under " .. c.id .. ":", { "--parent", c.id })
      end)
    elseif k == "remove_parent" then
      per_bead(ids, "Remove parent of", { "--parent", "" })
    elseif k == "add_dep" then
      local list = {}
      for _, b in pairs(store.get(v.root).by_id) do
        if b.status ~= "closed" then
          list[#list + 1] = b
        end
      end
      pick("Blocked by: ", ordered_by_id(list), bead_label, function(c)
        for _, id in ipairs(ids) do
          if id == c.id then
            return vim.notify("Beads: " .. c.id .. " is one of the selected beads and cannot block itself", vim.log.levels.WARN)
          end
        end
        dep_batch(ids, "add", c.id)
      end)
    elseif k == "remove_dep" then
      local by_id = store.get(v.root).by_id
      local seen, list = {}, {}
      for _, b in ipairs(beads_of(ids)) do
        for _, x in ipairs(b.blocked_by or {}) do
          if not seen[x] then
            seen[x] = true
            list[#list + 1] = by_id[x] or { id = x }
          end
        end
      end
      if #list == 0 then
        return vim.notify("Beads: the selected beads have no blocking dependencies", vim.log.levels.INFO)
      end
      pick("Remove dependency on: ", ordered_by_id(list), bead_label, function(c)
        local targets = {}
        for _, b in ipairs(beads_of(ids)) do
          if vim.tbl_contains(b.blocked_by or {}, c.id) then
            targets[#targets + 1] = b.id
          end
        end
        if #targets == 0 then
          return vim.notify("Beads: none of the selected beads depend on " .. c.id, vim.log.levels.INFO)
        end
        dep_batch(targets, "remove", c.id)
      end)
    end
  end
  local function yank(what, given)
    local ids = given
    if #ids == 0 then
      return
    end
    local by_id = store.get(v.root).by_id
    local out = {}
    for _, id in ipairs(ids) do
      if what == "run" then
        if by_id[id] then
          out[#out + 1] = workflow.run_command(by_id[id])
        end
      else
        out[#out + 1] = id
      end
    end
    if #out == 1 then
      return workflow.yank(out[1])
    end
    vim.fn.setreg('"', table.concat(out, "\n"))
    vim.notify("Beads: yanked " .. #out .. (what == "run" and " run commands" or " ids"), vim.log.levels.INFO)
  end
  function self.menu(ids)
    local items = {
      { "close", "close" },
      { "claim", "claim" },
      { "reopen", "reopen" },
      { "set_priority", "set priority" },
      { "set_status", "set status" },
      { "set_assignee", "set assignee" },
      { "set_type", "set type" },
      { "add_label", "add label" },
      { "remove_label", "remove label" },
      { "set_parent", "move under epic" },
      { "remove_parent", "remove parent" },
      { "add_dep", "blocked by..." },
      { "remove_dep", "remove dependency" },
      { "yank_id", "yank ids" },
      { "yank_run", "yank run commands" },
    }
    if #ids == 0 then
      return
    end
    vim.ui.select(items, {
      prompt = ("Beads: %d bead%s"):format(#ids, #ids == 1 and "" or "s"),
      format_item = function(it)
        return it[2]
      end,
    }, function(choice)
      if not choice then
        return
      end
      local k = choice[1]
      if k == "yank_id" or k == "yank_run" then
        return yank(k == "yank_run" and "run" or "id", ids)
      end
      if k:find("^set_") or k:find("^add_") or k:find("^remove_") then
        return field_action(k, ids)
      end
      act(k, ids)
    end)
  end
  self.act = act
  self.yank = yank
  return self
end

return M
