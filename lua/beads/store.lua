-- Per-root in-memory cache of all beads (closed included), with coalesced refresh.
local cli = require("beads.cli")
local model = require("beads.model")

local M = {}

local SELF_WRITE_WINDOW_MS = 1500

local entries = {}

local function build_state(beads)
  local by_id, kids, top = {}, {}, {}
  for _, b in ipairs(beads) do
    if b.id then
      by_id[b.id] = b
    end
  end
  for _, b in ipairs(beads) do
    if b.id then
      if b.parent then
        kids[b.parent] = kids[b.parent] or {}
        table.insert(kids[b.parent], b)
      else
        top[#top + 1] = b
      end
    end
  end
  return {
    by_id = by_id,
    children_of = function(id)
      return vim.list_slice(kids[id] or {})
    end,
    roots = function()
      return vim.list_slice(top)
    end,
  }
end

local function entry(root)
  local e = entries[root]
  if not e then
    e = {
      state = build_state({}),
      subs = {},
      in_flight = false,
      trailing = nil, -- callbacks waiting for the trailing call
      self_write = nil,
    }
    entries[root] = e
  end
  return e
end

function M.get(root)
  return entry(root).state
end

function M.subscribe(root, fn)
  local e = entry(root)
  local token = {}
  e.subs[#e.subs + 1] = { token = token, fn = fn }
  return function()
    for i, s in ipairs(e.subs) do
      if s.token == token then
        table.remove(e.subs, i)
        return
      end
    end
  end
end

local function start(root, e, cbs)
  e.in_flight = true
  -- cli resolves the root synchronously when spawning; swap it just for that call.
  local prev = cli.get_root_override()
  cli.set_root(root)
  cli.list({ all = true }, function(res)
    local err
    if res.err then
      err = res.err
    else
      e.state = build_state(model.normalize_all(res.data))
    end
    local trailing = e.trailing
    e.trailing = nil
    e.in_flight = false
    if trailing then
      start(root, e, trailing)
    end
    for _, s in ipairs(vim.list_slice(e.subs)) do
      s.fn(e.state, err)
    end
    for _, cb in ipairs(cbs) do
      cb(e.state, err)
    end
  end)
  cli.set_root(prev)
end

-- cb(state, err) is called when a refresh covering this request completes.
function M.refresh(root, cb)
  local e = entry(root)
  local cbs = cb and { cb } or {}
  if e.in_flight then
    e.trailing = e.trailing or {}
    vim.list_extend(e.trailing, cbs)
    return
  end
  start(root, e, cbs)
end

function M.is_refreshing(root)
  return entry(root).in_flight
end

-- Marks that the plugin itself just wrote to root; a watcher-triggered refresh
-- within the window can then be skipped via consume_self_write.
function M.mark_self_write(root)
  entry(root).self_write = vim.uv.now()
end

-- True (and clears the marker) if a self-write happened within the window.
function M.consume_self_write(root)
  local e = entry(root)
  local t = e.self_write
  e.self_write = nil
  return t ~= nil and (vim.uv.now() - t) <= SELF_WRITE_WINDOW_MS
end

return M
