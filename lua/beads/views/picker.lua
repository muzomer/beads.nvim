-- Pickers: ready, list, search, needs, epics. Adapters: pickers/fzf.lua, pickers/select.lua.
local cli = require("beads.cli")
local store = require("beads.store")
local model = require("beads.model")
local workflow = require("beads.workflow")

local M = {}

M.sources = { "ready", "list", "search", "needs", "epics" }

local function sort_beads(list)
  table.sort(list, function(a, b)
    local pa, pb = a.priority or 99, b.priority or 99
    if pa ~= pb then
      return pa < pb
    end
    return a.id < b.id
  end)
  return list
end

local function from_store(filter, cb)
  local root = cli.get_root()
  store.refresh(root, function(state, err)
    if err then
      return cb(nil, err)
    end
    local out = {}
    for _, b in pairs(state.by_id) do
      if filter(b) then
        out[#out + 1] = b
      end
    end
    cb(sort_beads(out))
  end)
end

local function from_cli(fn, ...)
  local args = { ... }
  local cb = table.remove(args)
  table.insert(args, function(res)
    if res.err then
      return cb(nil, res.err)
    end
    cb(model.normalize_all(res.data))
  end)
  fn(unpack(args))
end

function M.load(source, query, cb)
  if source == "ready" then
    from_cli(cli.ready, cb)
  elseif source == "search" then
    from_cli(cli.search, query, cb)
  elseif source == "list" then
    from_store(function(b)
      return b.status == "open" or b.status == "in_progress"
    end, cb)
  elseif source == "needs" then
    from_store(workflow.is_needs_me, cb)
  elseif source == "epics" then
    from_store(function(b)
      return b.type == "epic"
    end, cb)
  else
    cb(nil, "unknown picker source: " .. tostring(source))
  end
end

-- id, P<n>, status, title, badges
function M.format(b)
  local parts = { b.id, "P" .. tostring(b.priority or "?"), b.status or "?", b.title or "" }
  local badges = workflow.badges(b)
  if #badges > 0 then
    parts[#parts + 1] = table.concat(badges, " ")
  end
  return table.concat(parts, "  ")
end

function M.id_of_line(line)
  return (tostring(line or ""):gsub("\27%[[%d;]*m", "")):match("^%s*([%w%-%._]+)")
end

function M.yank(text)
  vim.fn.setreg('"', text)
  vim.notify("Yanked: " .. text, vim.log.levels.INFO)
end

function M.open_bead(id)
  vim.cmd.edit(vim.fn.fnameescape("beads://" .. id))
end

function M.close_bead(id)
  vim.ui.input({ prompt = "Close " .. id .. " reason (optional): " }, function(reason)
    if reason == nil then
      return
    end
    local root = cli.get_root()
    cli.close(id, reason, function(res)
      if res.err then
        return vim.notify("bd close failed: " .. res.err, vim.log.levels.ERROR)
      end
      store.mark_self_write(root)
      store.refresh(root)
    end)
  end)
end

function M.open(source, query)
  local function go(q)
    M.load(source, q, function(beads, err)
      if err then
        return vim.notify("Beads " .. source .. ": " .. err, vim.log.levels.ERROR)
      end
      if #beads == 0 then
        return vim.notify("Beads " .. source .. ": nothing found", vim.log.levels.INFO)
      end
      local adapter = require("beads").config.fzf and "fzf" or "select"
      require("beads.pickers." .. adapter).pick(source, beads, M)
    end)
  end
  if source == "search" and (not query or query == "") then
    vim.ui.input({ prompt = "Search beads: " }, function(q)
      if q and q ~= "" then
        go(q)
      end
    end)
    return
  end
  go(query)
end

return M
