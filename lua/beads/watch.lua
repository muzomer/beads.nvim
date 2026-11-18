-- Watches a beads root for external changes and refreshes the store.
-- Embedded backend: uv.fs_event on .beads/ (+ dolt noms dirs). Otherwise: refresh on
-- FocusGained/BufEnter of beads buffers, with a one-time notice.
local cli = require("beads.cli")
local store = require("beads.store")

local M = {}

local DEBOUNCE_MS = 200
local QUIET_MS = 400 -- ignore events caused by our own refresh (bd list rewrites the manifest)

local roots = {} -- root -> { count, handles, timer, stopped, mode, quiet_until, unsub }
local augroup = nil

local function close_handle(h)
  if h and not h:is_closing() then
    h:stop()
    h:close()
  end
end

local MAX_NAMED = 6

local function flush_notice(st)
  if st.notify_timer then
    close_handle(st.notify_timer)
    st.notify_timer = nil
  end
  local ids = st.changed or {}
  st.changed = nil
  if st.stopped or #ids == 0 then
    return
  end
  table.sort(ids)
  local shown = vim.list_slice(ids, 1, MAX_NAMED)
  local more = #ids > #shown and (" (+%d more)"):format(#ids - #shown) or ""
  vim.notify("Beads: changed externally: " .. table.concat(shown, ", ") .. more, vim.log.levels.INFO)
end

-- Collects ids changed by an external write; one notification per notify_group_ms window.
local function note_changes(st, ids)
  local cfg = require("beads").config
  if cfg.notify == false or #ids == 0 then
    return
  end
  st.changed = st.changed or {}
  for _, id in ipairs(ids) do
    if not vim.tbl_contains(st.changed, id) then
      st.changed[#st.changed + 1] = id
    end
  end
  if not st.notify_timer then
    st.notify_timer = vim.uv.new_timer()
    st.notify_timer:start(cfg.notify_group_ms or 1500, 0, function()
      vim.schedule(function()
        flush_notice(st)
      end)
    end)
  end
end

local function diff_ids(old, new)
  local ids = {}
  if next(old.by_id) == nil then
    return ids -- nothing was loaded before: not a change
  end
  for id, b in pairs(new.by_id) do
    local o = old.by_id[id]
    if not o or o.updated_at ~= b.updated_at then
      ids[#ids + 1] = id
    end
  end
  for id in pairs(old.by_id) do
    if not new.by_id[id] then
      ids[#ids + 1] = id
    end
  end
  return ids
end

local function fire(root, st)
  if st.stopped then
    return
  end
  if store.consume_self_write(root) then
    return
  end
  local old = store.get(root)
  store.refresh(root, function(new, err)
    if not err and not st.stopped then
      note_changes(st, diff_ids(old, new))
    end
  end)
end

local function schedule(root, st)
  if st.stopped then
    return
  end
  if not st.timer then
    st.timer = vim.uv.new_timer()
  end
  st.timer:stop()
  st.timer:start(DEBOUNCE_MS, 0, function()
    vim.schedule(function()
      fire(root, st)
    end)
  end)
end

local function on_event(root, st, name)
  if st.stopped then
    return
  end
  -- bd list (any store refresh) rewrites the manifest but never touches last-touched, so
  -- manifest events are ignored while a refresh runs or just after; last-touched always counts.
  if name == "manifest" and (store.is_refreshing(root) or vim.uv.now() < st.quiet_until) then
    return
  end
  if name == "last-touched" or name == "manifest" then
    schedule(root, st)
  end
end

local function watch_dir(root, st, dir, accept)
  local h = vim.uv.new_fs_event()
  if not h then
    return
  end
  local ok = h:start(dir, {}, function(err, name)
    if err then
      return
    end
    vim.schedule(function()
      if name and accept(name) then
        on_event(root, st, name)
      end
    end)
  end)
  if ok == nil or ok < 0 then
    close_handle(h)
    return
  end
  st.handles[#st.handles + 1] = h
end

local function start_embedded(root, st)
  st.unsub = store.subscribe(root, function()
    st.quiet_until = vim.uv.now() + QUIET_MS
  end)
  local beads = root .. "/.beads"
  watch_dir(root, st, beads, function(n)
    return n == "last-touched"
  end)
  local base = beads .. "/embeddeddolt"
  for name, t in vim.fs.dir(base) do
    if t == "directory" then
      local noms = base .. "/" .. name .. "/.dolt/noms"
      if vim.uv.fs_stat(noms) then
        watch_dir(root, st, noms, function(n)
          return n == "manifest"
        end)
      end
    end
  end
end

local function focus_refresh()
  for root, st in pairs(roots) do
    if st.mode == "focus" then
      schedule(root, st)
    end
  end
end

local function ensure_autocmds()
  if augroup then
    return
  end
  augroup = vim.api.nvim_create_augroup("BeadsWatch", { clear = true })
  vim.api.nvim_create_autocmd("FocusGained", { group = augroup, callback = focus_refresh })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    pattern = "beads://*",
    callback = focus_refresh,
  })
end

local function maybe_drop_autocmds()
  for _, st in pairs(roots) do
    if st.mode == "focus" then
      return
    end
  end
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    augroup = nil
  end
end

local function stop(root, st)
  st.stopped = true
  for _, h in ipairs(st.handles) do
    close_handle(h)
  end
  st.handles = {}
  close_handle(st.timer)
  st.timer = nil
  close_handle(st.notify_timer)
  st.notify_timer = nil
  close_handle(st.qtimer)
  st.qtimer = nil
  close_handle(st.qnotify_timer)
  st.qnotify_timer = nil
  st.replies = nil
  st.changed = nil
  if st.unsub then
    st.unsub()
    st.unsub = nil
  end
  roots[root] = nil
  maybe_drop_autocmds()
end

local function detect(root, st)
  local prev = cli.get_root_override()
  cli.set_root(root)
  cli.context(function(res)
    if st.stopped then
      return
    end
    local mode = res.data and res.data.dolt_mode
    if mode == "embedded" then
      st.mode = "embedded"
      start_embedded(root, st)
    else
      st.mode = "focus"
      ensure_autocmds()
      vim.notify(
        "Beads: backend is not embedded; refreshing on focus instead of watching files",
        vim.log.levels.INFO
      )
    end
  end)
  cli.set_root(prev)
end

-- Questions watcher: <root>/.beads-nvim/questions.json is written by beads-ask (another process).
local function qsnapshot(root)
  local snap = {}
  local ok, threads = pcall(require("beads.questions.store").list, root)
  for _, t in ipairs(ok and threads or {}) do
    snap[t.id] = #(t.messages or {})
  end
  return snap
end

local function flush_replies(st)
  close_handle(st.qnotify_timer)
  st.qnotify_timer = nil
  local list = st.replies or {}
  st.replies = nil
  if st.stopped or #list == 0 then
    return
  end
  if #list == 1 then
    vim.notify("Beads: agent replied on " .. list[1].bead .. ": " .. list[1].line, vim.log.levels.INFO)
    return
  end
  local ids, lines = {}, {}
  for _, r in ipairs(list) do
    if not vim.tbl_contains(ids, r.bead) then
      ids[#ids + 1] = r.bead
    end
    lines[#lines + 1] = ("  %s: %s"):format(r.bead, r.line)
  end
  vim.notify(
    "Beads: agent replied on " .. table.concat(ids, ", ") .. "\n" .. table.concat(lines, "\n"),
    vim.log.levels.INFO
  )
end

local function qfire(root, st)
  if st.stopped then
    return
  end
  local ok, threads = pcall(require("beads.questions.store").list, root)
  local old, new = st.qsnap or {}, {}
  local cfg = require("beads").config
  for _, t in ipairs(ok and threads or {}) do
    local msgs = t.messages or {}
    new[t.id] = #msgs
    local known = old[t.id] or math.min(1, #msgs) -- a new thread's first message is its opener
    for i = known + 1, #msgs do
      if msgs[i].author ~= "user" and cfg.notify ~= false then
        st.replies = st.replies or {}
        local line = vim.split(msgs[i].body or "", "\n", { plain = true })[1] or ""
        st.replies[#st.replies + 1] = { bead = t.bead, line = line }
      end
    end
  end
  st.qsnap = new
  if st.replies and not st.qnotify_timer then
    st.qnotify_timer = vim.uv.new_timer()
    st.qnotify_timer:start(cfg.notify_group_ms or 1500, 0, function()
      vim.schedule(function()
        flush_replies(st)
      end)
    end)
  end
  store.refresh(root, function()
    if not st.stopped then
      require("beads.views.detail").refresh_root_threads(root)
    end
  end)
end

local function start_questions(root, st)
  st.qsnap = qsnapshot(root)
  local dir = root .. "/.beads-nvim"
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
    local f = io.open(dir .. "/.gitignore", "w")
    if f then
      f:write("*\n")
      f:close()
    end
  end
  local h = vim.uv.new_fs_event()
  if not h then
    return
  end
  local ok = h:start(dir, {}, function(err, name)
    if err or name ~= "questions.json" then
      return
    end
    vim.schedule(function()
      if st.stopped then
        return
      end
      if not st.qtimer then
        st.qtimer = vim.uv.new_timer()
      end
      st.qtimer:stop()
      st.qtimer:start(DEBOUNCE_MS, 0, function()
        vim.schedule(function()
          qfire(root, st)
        end)
      end)
    end)
  end)
  if ok == nil or ok < 0 then
    close_handle(h)
    return
  end
  st.handles[#st.handles + 1] = h
end

-- Call when a beads view opens; returns release(), to call when it closes.
function M.acquire(root)
  local st = roots[root]
  if not st then
    st = { count = 0, handles = {}, stopped = false, quiet_until = 0 }
    roots[root] = st
    start_questions(root, st)
    detect(root, st)
  end
  st.count = st.count + 1
  local released = false
  return function()
    if released then
      return
    end
    released = true
    st.count = st.count - 1
    if st.count <= 0 and roots[root] == st then
      stop(root, st)
    end
  end
end

return M
