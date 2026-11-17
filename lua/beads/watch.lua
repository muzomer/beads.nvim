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

local function fire(root, st)
  if st.stopped then
    return
  end
  if store.consume_self_write(root) then
    return
  end
  store.refresh(root)
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
        "beads: backend is not embedded; refreshing on focus instead of watching files",
        vim.log.levels.INFO
      )
    end
  end)
  cli.set_root(prev)
end

-- Call when a beads view opens; returns release(), to call when it closes.
function M.acquire(root)
  local st = roots[root]
  if not st then
    st = { count = 0, handles = {}, stopped = false, quiet_until = 0 }
    roots[root] = st
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
