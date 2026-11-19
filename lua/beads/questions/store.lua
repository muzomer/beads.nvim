-- Question threads persisted in <root>/.beads-nvim/questions.json.
-- Writers take a mkdir-based lock and replace the file atomically (temp + rename).
-- No plenary dependency: this runs in bare `nvim --clean -l` processes too.
local M = {}

local uv = vim.uv or vim.loop

local LOCK_STALE_MS = 10000
local LOCK_TIMEOUT_MS = 15000

local function dir_of(root)
  return root .. "/.beads-nvim"
end

local function file_of(root)
  return dir_of(root) .. "/questions.json"
end

local function now_ms()
  return uv.hrtime() / 1e6
end

local function read_all(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

-- Missing or corrupt file reads as no threads, never an error.
local function load(root)
  local s = read_all(file_of(root))
  if not s or s == "" then
    return {}
  end
  local ok, data = pcall(vim.json.decode, s)
  if not ok or type(data) ~= "table" then
    return {}
  end
  if type(data.threads) == "table" then
    data = data.threads
  end
  if next(data) ~= nil and not vim.islist(data) then
    return {}
  end
  local out = {}
  for _, t in ipairs(data) do
    if type(t) == "table" then
      out[#out + 1] = t
    end
  end
  return out
end

local function derive_needs(thread)
  if thread.status == "resolved" then
    return "none"
  end
  local last = thread.messages and thread.messages[#thread.messages]
  if not last then
    return "user"
  end
  return last.author == "user" and "agent" or "user"
end

local function ensure_dir(root)
  local d = dir_of(root)
  vim.fn.mkdir(d, "p")
  local gi = d .. "/.gitignore"
  if not uv.fs_stat(gi) then
    local f = io.open(gi, "w")
    if f then
      f:write("*\n")
      f:close()
    end
  end
end

local function with_lock(root, fn)
  ensure_dir(root)
  local lock = dir_of(root) .. "/questions.lock"
  local start = now_ms()
  while true do
    if uv.fs_mkdir(lock, 448) then
      break
    end
    local st = uv.fs_stat(lock)
    if st and (os.time() - st.mtime.sec) * 1000 > LOCK_STALE_MS then
      uv.fs_rmdir(lock)
    elseif now_ms() - start > LOCK_TIMEOUT_MS then
      error("beads.questions.store: timed out waiting for lock")
    else
      uv.sleep(2)
    end
  end
  local ok, res = pcall(fn)
  uv.fs_rmdir(lock)
  if not ok then
    error(res, 0)
  end
  return res
end

local function save(root, threads)
  local path = file_of(root)
  local tmp = ("%s.%d.tmp"):format(path, uv.os_getpid())
  local body = #threads == 0 and "[]" or vim.json.encode(threads)
  local f = assert(io.open(tmp, "w"))
  local wok, werr = f:write(body)
  if wok then
    wok, werr = f:flush()
  end
  local cok, cerr = f:close()
  if not wok or not cok then
    uv.fs_unlink(tmp)
    error("beads.questions.store: write failed: " .. tostring(werr or cerr))
  end
  local ok, err = uv.fs_rename(tmp, path)
  if not ok then
    uv.fs_unlink(tmp)
    error("beads.questions.store: rename failed: " .. tostring(err))
  end
end

local function next_id(prefix, items)
  local max = 0
  for _, it in ipairs(items) do
    local n = type(it.id) == "string" and tonumber(it.id:match("^" .. prefix .. "(%d+)$"))
    if n and n > max then
      max = n
    end
  end
  return prefix .. (max + 1)
end

local function make_message(thread, m)
  local msg = {
    id = next_id("m", thread.messages),
    author = m.author,
    ts = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    body = m.body,
    proposal = m.proposal,
  }
  thread.messages[#thread.messages + 1] = msg
end

local function find(threads, tid)
  for _, t in ipairs(threads) do
    if t.id == tid then
      return t
    end
  end
end

-- False when questions.json exists but cannot be read or parsed (a missing file is fine; an empty one is a half-written read).
function M.readable(root)
  local path = file_of(root)
  if not uv.fs_stat(path) then
    return true
  end
  local s = read_all(path)
  if s == nil then
    return false
  end
  if s == "" then
    return false
  end
  local ok, data = pcall(vim.json.decode, s)
  if not ok or type(data) ~= "table" then
    return false
  end
  if type(data.threads) == "table" then
    data = data.threads
  end
  return next(data) == nil or vim.islist(data)
end

function M.list(root, filter)
  filter = filter or {}
  local out = {}
  for _, t in ipairs(load(root)) do
    if
      (not filter.bead or t.bead == filter.bead)
      and (not filter.needs or t.needs == filter.needs)
      and (not filter.status or t.status == filter.status)
    then
      out[#out + 1] = t
    end
  end
  return out
end

function M.get(root, tid)
  return find(load(root), tid)
end

function M.add(root, thread)
  return with_lock(root, function()
    local threads = load(root)
    local t = {
      id = next_id("t", threads),
      bead = thread.bead,
      section = thread.section,
      quote = thread.quote,
      status = "open",
      messages = {},
    }
    for _, m in ipairs(thread.messages or {}) do
      make_message(t, m)
    end
    t.needs = derive_needs(t)
    threads[#threads + 1] = t
    save(root, threads)
    return t
  end)
end

function M.reply(root, tid, author, body, proposal)
  return with_lock(root, function()
    local threads = load(root)
    local t = find(threads, tid)
    if not t then
      return nil
    end
    t.messages = t.messages or {}
    make_message(t, { author = author, body = body, proposal = proposal })
    t.needs = derive_needs(t)
    save(root, threads)
    return t
  end)
end

function M.resolve(root, tid)
  return with_lock(root, function()
    local threads = load(root)
    local t = find(threads, tid)
    if not t then
      return nil
    end
    t.status = "resolved"
    t.needs = "none"
    save(root, threads)
    return t
  end)
end

-- Remembers that the thread's transcript was saved as a bead comment.
function M.mark_saved(root, tid, saved)
  return with_lock(root, function()
    local threads = load(root)
    local t = find(threads, tid)
    if not t then
      return nil
    end
    t.saved_comment = saved ~= false
    save(root, threads)
    return t
  end)
end

return M
