-- Progress of questions sent to agent-poke.nvim: one entry per delivered prompt, fed by agent-poke's
-- User AgentPokeProgress autocmd and by polling progress(id) while a target-delivered prompt is "sent".
-- Views (thread float, tree, detail winbar) register with watch(); one timer runs only while some
-- watcher is alive and some entry is active, so nothing leaks after a view closes.
local M = {}

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local PERIOD = 120
local POLL_MS = 2000
local ACTIVE = { sent = true, queued = true, working = true }

local entries = {} -- { id?, root, bead, thread, base_n?, prompt?, stage?, target?, since, polled }
local watchers = {} -- key -> { valid = fn, update = fn }
local timer
local frame = 0
local hooked = false

M.sent_timeout_ms = 120000 -- a "sent" stage older than this is no longer polled or spun
M.unclaimed_ms = 10000 -- an id-less entry claims root events only this long after add()
M.max_entries = 50

local function stale(e)
  return e.stage == "sent" and vim.uv.now() - (e.since or 0) >= M.sent_timeout_ms
end

local function active(e)
  return ACTIVE[e.stage] == true and not stale(e)
end

-- Drops id-less entries whose correlating event window has passed.
local function prune()
  local now = vim.uv.now()
  for i = #entries, 1, -1 do
    local e = entries[i]
    if e.id == nil and now - (e.added or 0) >= M.unclaimed_ms then
      table.remove(entries, i)
    end
  end
end

local function notify_watchers()
  for key, w in pairs(watchers) do
    if w.valid() then
      pcall(w.update)
    else
      watchers[key] = nil
    end
  end
end

local function stop()
  if timer then
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
    timer = nil
  end
end

local function remove(e)
  for i, x in ipairs(entries) do
    if x == e then
      table.remove(entries, i)
      return
    end
  end
end

local function set_stage(e, stage, err, target)
  if target ~= nil then
    e.target = target
  end
  if stage == "done" then
    remove(e)
    return notify_watchers()
  end
  if stage ~= e.stage then
    e.stage = stage
    e.since = vim.uv.now()
    e.polled = e.since
  end
  e.err = err
  if stage == "failed" and e.prompt and not e.registered then
    e.registered = true
    vim.fn.setreg('"', e.prompt)
  end
  notify_watchers()
  M.ensure()
end

local function poll()
  local ok, ap = pcall(require, "agent-poke")
  if not (ok and type(ap) == "table" and ap.progress) then
    return
  end
  local now = vim.uv.now()
  for _, e in ipairs(vim.list_slice(entries)) do
    if e.stage == "sent" and e.id and not stale(e) and now - (e.polled or 0) >= POLL_MS then
      e.polled = now
      local pok, stage, err = pcall(ap.progress, e.id)
      if pok and stage and stage ~= e.stage then
        set_stage(e, stage, err)
      end
    end
  end
end

local function tick(this)
  if timer ~= this then
    return
  end
  for key, w in pairs(watchers) do
    if not w.valid() then
      watchers[key] = nil
    end
  end
  local any = false
  for _, e in ipairs(entries) do
    any = any or active(e)
  end
  if not any or next(watchers) == nil then
    stop()
    return notify_watchers()
  end
  frame = frame + 1
  poll()
  notify_watchers()
end

-- Starts the timer when a watcher and an active entry exist.
function M.ensure()
  if timer then
    return
  end
  local any = false
  for _, e in ipairs(entries) do
    any = any or active(e)
  end
  if not any or next(watchers) == nil then
    return
  end
  local t = vim.uv.new_timer()
  timer = t
  t:start(
    PERIOD,
    PERIOD,
    vim.schedule_wrap(function()
      tick(t)
    end)
  )
end

local function on_event(data)
  if type(data) ~= "table" then
    return
  end
  local e
  prune()
  for _, x in ipairs(entries) do
    if data.id ~= nil and x.id == data.id then
      e = x
      break
    end
  end
  if not e then
    for i = #entries, 1, -1 do
      local x = entries[i]
      if x.id == nil and x.root == data.root then
        e = x
        e.id = data.id
        break
      end
    end
  end
  if e then
    set_stage(e, data.stage, e.err, data.target)
  end
end

-- A reply from the agent (a message after the one we sent) ends the waiting state.
local function on_threads(dbuf)
  local detail = require("beads.views.detail")
  local snap = detail.snapshot(dbuf)
  if not snap then
    return
  end
  local root = detail.root(dbuf)
  local changed = false
  for _, e in ipairs(vim.list_slice(entries)) do
    if e.base_n and e.root == root and e.bead == snap.id then
      for _, t in ipairs(snap.threads or {}) do
        local msgs = t.messages or {}
        if t.id == e.thread and #msgs > e.base_n and (msgs[#msgs].author or "") ~= "user" then
          remove(e)
          changed = true
        end
      end
    end
  end
  if changed then
    notify_watchers()
  end
end

local function hook()
  if hooked then
    return
  end
  hooked = true
  local g = vim.api.nvim_create_augroup("BeadsProgress", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = g,
    pattern = "AgentPokeProgress",
    callback = function(a)
      on_event(a.data)
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = g,
    pattern = "BeadsThreadsRefreshed",
    callback = function(a)
      if type(a.data) == "number" then
        on_threads(a.data)
      end
    end,
  })
end

-- Registers a delivered prompt. ctx: { root, bead, thread, base_n?, prompt, id?, stage? } (id from poke).
function M.add(ctx)
  hook()
  for _, e in ipairs(vim.list_slice(entries)) do
    if e.root == ctx.root and e.bead == ctx.bead and e.thread == ctx.thread then
      remove(e)
    end
  end
  entries[#entries + 1] = {
    id = ctx.id,
    root = ctx.root,
    bead = ctx.bead,
    thread = ctx.thread,
    base_n = ctx.base_n,
    prompt = ctx.prompt,
    added = vim.uv.now(),
    since = vim.uv.now(),
    polled = vim.uv.now(),
  }
  prune()
  while #entries > math.max(1, M.max_entries) do
    table.remove(entries, 1)
  end
end

-- Registers a view: valid() says whether it is still shown, update() redraws its waiting state.
function M.watch(key, w)
  watchers[key] = w
  M.ensure()
end

function M.glyph()
  local g = vim.tbl_extend("force", require("beads.workflow").default_glyphs, (require("beads").config.workflow or {}).glyphs or {})
  return g.waiting or "💬"
end

local function find(root, bead, thread)
  for i = #entries, 1, -1 do
    local e = entries[i]
    if e.root == root and e.bead == bead and (thread == nil or e.thread == thread) and e.stage then
      return e
    end
  end
end

-- The spinner frame while a question of the bead waits on the agent, else nil.
function M.waiting(root, bead)
  for _, e in ipairs(entries) do
    if e.root == root and e.bead == bead and active(e) then
      return FRAMES[frame % #FRAMES + 1]
    end
  end
end

-- The stage line of a thread, or nil.
function M.stage_text(root, bead, thread)
  local e = find(root, bead, thread)
  if not e then
    return nil
  end
  if e.stage == "sent" then
    return type(e.target) == "string" and e.target ~= "" and ("sent to " .. e.target) or "sent"
  elseif e.stage == "queued" then
    return "queued"
  elseif e.stage == "working" then
    return FRAMES[frame % #FRAMES + 1] .. " agent is replying…"
  elseif e.stage == "failed" then
    return 'no agent picked it up — prompt in " register'
  end
end

return M
