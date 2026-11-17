-- Findings test for bead beads_nvim-4gx.1 (lua/beads/questions/store.lua save()).
-- Blocker: save ignored write/close errors, so on disk full a truncated temp file was
-- renamed over questions.json; the next read saw a corrupt file ({}), and the next
-- write silently dropped every existing thread.
--
-- Disk full is simulated with a real fault: the store's temp file
-- (<root>/.beads-nvim/questions.json.<pid>.tmp) is pre-created as a symlink to
-- /dev/full, so writing it fails with ENOSPC (Linux only).

local qs = require("beads.questions.store")

local function new_root()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

local function qfile(root)
  return root .. "/.beads-nvim/questions.json"
end

local function tmpfile(root)
  return ("%s.%d.tmp"):format(qfile(root), vim.fn.getpid())
end

local function read_raw(path)
  return table.concat(vim.fn.readfile(path, "b"), "\n")
end

-- Arrange: a store with one thread, then make the next save hit a full disk.
local function seeded_full_disk_root()
  local root = new_root()
  local t = qs.add(root, { bead = "bd-1", messages = { { author = "user", body = "first question" } } })
  local before = read_raw(qfile(root))
  assert(vim.loop.fs_symlink("/dev/full", tmpfile(root)))
  return root, t, before
end

local function assert_unchanged(root, tid, before)
  local st = vim.loop.fs_lstat(qfile(root))
  assert.are.equal("file", st and st.type, "questions.json must stay a regular file")
  assert.are.equal(before, read_raw(qfile(root)))
  local got = qs.get(root, tid)
  assert.is_not_nil(got, "existing thread must survive a failed write")
  assert.are.equal("first question", got.messages[1].body)
  assert.is_nil(vim.loop.fs_lstat(tmpfile(root)), "temp file must be removed after a failed write")
end

describe("questions store write errors (disk full)", function()
  if not vim.loop.fs_stat("/dev/full") then
    pending("/dev/full not available")
    return
  end

  it("add raises and leaves questions.json and its threads intact", function()
    local root, t, before = seeded_full_disk_root()
    local ok = pcall(qs.add, root, { bead = "bd-2", messages = { { author = "user", body = "second" } } })
    assert.is_false(ok, "add must raise when the write fails")
    assert_unchanged(root, t.id, before)
  end)

  it("reply raises and leaves questions.json and its threads intact", function()
    local root, t, before = seeded_full_disk_root()
    local ok = pcall(qs.reply, root, t.id, "agent", "an answer")
    assert.is_false(ok, "reply must raise when the write fails")
    assert_unchanged(root, t.id, before)
  end)

  it("resolve raises and leaves questions.json and its threads intact", function()
    local root, t, before = seeded_full_disk_root()
    local ok = pcall(qs.resolve, root, t.id)
    assert.is_false(ok, "resolve must raise when the write fails")
    assert_unchanged(root, t.id, before)
    assert.are.equal("open", qs.get(root, t.id).status)
  end)

  it("after a failed write the lock is released and the next write keeps all threads", function()
    local root, t = seeded_full_disk_root()
    pcall(qs.add, root, { bead = "bd-2", messages = { { author = "user", body = "lost?" } } })
    vim.loop.fs_unlink(tmpfile(root)) -- disk has space again
    local t3 = qs.add(root, { bead = "bd-3", messages = { { author = "user", body = "third" } } })
    local all = qs.list(root)
    local ids = {}
    for _, th in ipairs(all) do
      ids[th.id] = true
    end
    assert.is_true(ids[t.id], "first thread must still be present")
    assert.is_true(ids[t3.id], "new thread must be present")
  end)
end)
