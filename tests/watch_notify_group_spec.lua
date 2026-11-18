-- Bead beads_nvim-4u9.9: watcher-detected external changes are grouped into one notification per
-- notify_group_ms (default 1500) naming the changed ids; notify = false silences them.
--
-- Fake `bd` (test double for the external binary), as in tests/watch_findings_spec.lua: embedded
-- backend, `bd list` rewrites the Dolt manifest like the real one and prints
-- $FAKE_DIR/<root name>.list.json, so a test can change a bead's updated_at between refreshes.
--
-- assumption: `notify` and `notify_group_ms` are top-level require("beads").setup() keys.
-- assumption: the grouped notification starts with "Beads: " and names every changed id.

local store = require("beads.store")

local FAKE_BD = [[#!/bin/sh
r=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-C" ]; then r="$a"; fi
  prev="$a"
done
name=$(basename "$r")
printf '%s\n' "$*" >> "$FAKE_DIR/$name.calls"
m="$r/.beads/embeddeddolt/db/.dolt/noms/manifest"
case " $* " in
  *" context "*)
    printf '{"backend":"dolt","beads_dir":"%s/.beads","database":"db","dolt_mode":"embedded","repo_root":"%s","is_redirected":false,"is_worktree":false,"schema_version":1}\n' "$r" "$r"
    ;;
  *" list "*)
    if [ -f "$m" ]; then cp "$m" "$m.tmp" && mv "$m.tmp" "$m"; fi
    if [ -f "$FAKE_DIR/$name.list.json" ]; then cat "$FAKE_DIR/$name.list.json"; else printf '[]\n'; fi
    ;;
  *" ready "*)
    if [ -f "$m" ]; then cp "$m" "$m.tmp" && mv "$m.tmp" "$m"; fi
    printf '[]\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
]]

local IDS = { "ng-a1", "ng-b2", "ng-c3", "ng-d4" }

local orig_path, orig_notify, bin_dir, fake_dir, watch
local releases, notes

local function sleep(ms)
  vim.wait(ms, function()
    return false
  end, 10)
end

local function new_root()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/.beads/embeddeddolt/db/.dolt/noms", "p")
  vim.fn.writefile({ "x" }, dir .. "/.beads/last-touched")
  vim.fn.writefile({ "manifest-v1" }, dir .. "/.beads/embeddeddolt/db/.dolt/noms/manifest")
  vim.fn.writefile({ "" }, dir .. "/.beads/issues.jsonl")
  return dir
end

local function calls(r, sub)
  local f = fake_dir .. "/" .. vim.fn.fnamemodify(r, ":t") .. ".calls"
  if vim.fn.filereadable(f) == 0 then
    return 0
  end
  local n = 0
  for _, line in ipairs(vim.fn.readfile(f)) do
    if line:find(sub, 1, true) then
      n = n + 1
    end
  end
  return n
end

local function list_calls(r)
  return calls(r, " list ")
end

-- versions: id -> n; bead updated_at moves with n.
local function write_list(r, versions)
  local beads = {}
  for _, id in ipairs(IDS) do
    local n = versions[id] or 0
    beads[#beads + 1] = {
      id = id,
      title = id .. " v" .. n,
      status = "open",
      priority = 2,
      issue_type = "task",
      created_at = "2026-11-17T10:00:00Z",
      updated_at = ("2026-11-17T10:%02d:00Z"):format(n),
    }
  end
  vim.fn.writefile({ vim.json.encode(beads) }, fake_dir .. "/" .. vim.fn.fnamemodify(r, ":t") .. ".list.json")
end

local function touch(path, i)
  vim.fn.writefile({ "w" .. tostring(i or vim.uv.hrtime()) }, path)
end

-- What a real `bd update <id>` does: the data changes, then last-touched and the manifest.
local function external_update(r, versions, id, i)
  versions[id] = (versions[id] or 0) + 1
  write_list(r, versions)
  touch(r .. "/.beads/last-touched", i)
  touch(r .. "/.beads/embeddeddolt/db/.dolt/noms/manifest", i)
end

-- A fresh root with the store populated and the watcher running and settled.
local function watched_root()
  local r = new_root()
  local versions = {}
  write_list(r, versions)
  local done = false
  store.refresh(r, function()
    done = true
  end)
  assert(vim.wait(3000, function()
    return done
  end, 10), "initial store.refresh never completed")
  local rel = watch.acquire(r)
  table.insert(releases, rel)
  assert(vim.wait(3000, function()
    return calls(r, "context") > 0
  end, 10), "bd context --json was never called")
  sleep(600)
  return r, versions
end

local function change_notes()
  local out = {}
  for _, n in ipairs(notes) do
    for _, id in ipairs(IDS) do
      if n.msg:find(id, 1, true) then
        out[#out + 1] = n
        break
      end
    end
  end
  return out
end

local function dump(list)
  local t = {}
  for _, n in ipairs(list) do
    t[#t + 1] = n.msg
  end
  return table.concat(t, "\n---\n")
end

-- Three external updates (ids 1..3), spaced past the 200ms debounce so each one is its own refresh.
local function three_updates(r, versions)
  local base = list_calls(r)
  for i = 1, 3 do
    external_update(r, versions, IDS[i], i)
    sleep(350)
  end
  assert(vim.wait(2000, function()
    return list_calls(r) >= base + 3
  end, 10), "expected 3 watcher refreshes, got " .. (list_calls(r) - base))
end

describe("beads.watch grouped notifications", function()
  before_each(function()
    releases, notes = {}, {}
    orig_path = vim.env.PATH
    orig_notify = vim.notify
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    bin_dir = vim.fn.tempname()
    vim.fn.mkdir(bin_dir, "p")
    vim.fn.writefile(vim.split(FAKE_BD, "\n"), bin_dir .. "/bd")
    vim.fn.setfperm(bin_dir .. "/bd", "rwxr-xr-x")
    fake_dir = vim.fn.tempname()
    vim.fn.mkdir(fake_dir, "p")
    vim.env.FAKE_DIR = fake_dir
    vim.env.PATH = bin_dir .. ":" .. orig_path
    package.loaded["beads.watch"] = nil
    watch = require("beads.watch")
    require("beads").setup({})
  end)

  after_each(function()
    for _, rel in ipairs(releases or {}) do
      pcall(rel)
    end
    sleep(300)
    vim.notify = orig_notify
    vim.env.PATH = orig_path
    vim.fn.delete(bin_dir, "rf")
    vim.fn.delete(fake_dir, "rf")
    require("beads").setup({})
  end)

  it("defaults: notify_group_ms is 1500 and notifications are on", function()
    local cfg = require("beads").config
    assert.are.equal(1500, cfg.notify_group_ms)
    assert.are_not.equal(false, cfg.notify)
  end)

  it("three external changes within the window produce exactly one notification naming them", function()
    local r, versions = watched_root()
    three_updates(r, versions)
    -- the window (1500ms) closes, plus margin
    sleep(2500)
    local got = change_notes()
    assert.are.equal(1, #got, "expected one grouped notification, got " .. #got .. ":\n" .. dump(got))
    local msg = got[1].msg
    assert.is_truthy(vim.startswith(msg, "Beads: "), "notification lacks the 'Beads: ' prefix: " .. msg)
    for i = 1, 3 do
      assert.is_truthy(msg:find(IDS[i], 1, true), "notification does not name " .. IDS[i] .. ": " .. msg)
    end
    assert.is_falsy(msg:find(IDS[4], 1, true), "notification names unchanged " .. IDS[4] .. ": " .. msg)
  end)

  it("changes in separate windows produce separate notifications (notify_group_ms honoured)", function()
    require("beads").setup({ notify_group_ms = 300 })
    local r, versions = watched_root()
    external_update(r, versions, IDS[1], 1)
    assert(vim.wait(2000, function()
      return #change_notes() >= 1
    end, 10), "no notification for the first change")
    sleep(800)
    external_update(r, versions, IDS[2], 2)
    assert(vim.wait(2000, function()
      return #change_notes() >= 2
    end, 10), "no second notification for a change after the window; got:\n" .. dump(change_notes()))
    sleep(500)
    local got = change_notes()
    assert.are.equal(2, #got, dump(got))
    assert.is_truthy(got[1].msg:find(IDS[1], 1, true))
    assert.is_truthy(got[2].msg:find(IDS[2], 1, true))
    assert.is_falsy(got[2].msg:find(IDS[1], 1, true), "second notification repeats " .. IDS[1])
  end)

  it("notify = false produces no notification, but still refreshes", function()
    require("beads").setup({ notify = false })
    local r, versions = watched_root()
    three_updates(r, versions)
    sleep(2500)
    local got = change_notes()
    assert.are.equal(0, #got, "notify = false still notified:\n" .. dump(got))
    assert.are.equal("ng-c3 v1", store.get(r).by_id["ng-c3"].title, "store was not refreshed")
  end)
end)
