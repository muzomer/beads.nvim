-- Reviewer findings for bead beads_nvim-ge7.14 (lua/beads/watch.lua). Same interface and
-- fake `bd` as tests/watch_spec.lua, plus an optional delay for `bd list`
-- ($FAKE_DIR/list_delay, seconds) so a refresh can be kept in flight.
--
-- 1. Refreshes not started by the watcher (plugin follow-up after a self-write, view open,
--    manual refresh) run `bd list`, which rewrites the manifest; that must not cause an
--    extra watcher refresh.
-- 2. An external update that lands while a refresh is in flight, or just after it, must
--    not be lost: it must lead to one more refresh.

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
case " $* " in
  *" context "*)
    mode=$(cat "$FAKE_DIR/mode" 2>/dev/null || echo embedded)
    printf '{"backend":"dolt","beads_dir":"%s/.beads","database":"db","dolt_mode":"%s","repo_root":"%s","is_redirected":false,"is_worktree":false,"schema_version":1}\n' "$r" "$mode" "$r"
    ;;
  *" list "*)
    d=$(cat "$FAKE_DIR/list_delay" 2>/dev/null || echo 0)
    if [ "$d" != "0" ]; then sleep "$d"; fi
    m="$r/.beads/embeddeddolt/db/.dolt/noms/manifest"
    if [ -f "$m" ]; then
      cp "$m" "$m.tmp" && mv "$m.tmp" "$m"
    fi
    printf '[]\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
]]

local orig_path, orig_notify, bin_dir, fake_dir, watch
local releases

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

local function sleep(ms)
  vim.wait(ms, function()
    return false
  end, 10)
end

local function acquire_settled(r)
  local rel = watch.acquire(r)
  assert.is_function(rel, "watch.acquire must return a release function")
  table.insert(releases, rel)
  assert(vim.wait(3000, function()
    return calls(r, "context") > 0
  end, 10), "bd context --json was never called")
  sleep(400)
  return rel, list_calls(r)
end

local function touch(path, i)
  vim.fn.writefile({ "w" .. tostring(i or vim.uv.hrtime()) }, path)
end

-- What a real `bd update` does to the watched files.
local function external_write(r, i)
  touch(r .. "/.beads/last-touched", i)
  touch(r .. "/.beads/embeddeddolt/db/.dolt/noms/manifest", i)
end

describe("beads.watch findings", function()
  before_each(function()
    releases = {}
    orig_path = vim.env.PATH
    orig_notify = vim.notify
    vim.notify = function() end
    bin_dir = vim.fn.tempname()
    vim.fn.mkdir(bin_dir, "p")
    vim.fn.writefile(vim.split(FAKE_BD, "\n"), bin_dir .. "/bd")
    vim.fn.setfperm(bin_dir .. "/bd", "rwxr-xr-x")
    fake_dir = vim.fn.tempname()
    vim.fn.mkdir(fake_dir, "p")
    vim.fn.writefile({ "embedded" }, fake_dir .. "/mode")
    vim.env.FAKE_DIR = fake_dir
    vim.env.PATH = bin_dir .. ":" .. orig_path
    package.loaded["beads.watch"] = nil
    watch = require("beads.watch")
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
  end)

  describe("refreshes not started by the watcher", function()
    it("a plugin write followed (>200ms later) by the plugin's own refresh refreshes once", function()
      local r = new_root()
      local _, base = acquire_settled(r)
      store.mark_self_write(r)
      external_write(r, 1)
      -- debounce fires and consumes the self-write marker
      sleep(350)
      assert.are.equal(base, list_calls(r))
      -- the plugin's follow-up refresh; its bd list rewrites the manifest
      local done = false
      store.refresh(r, function()
        done = true
      end)
      assert(vim.wait(1500, function()
        return done
      end, 10), "store.refresh never completed")
      sleep(2000)
      assert.are.equal(base + 1, list_calls(r))
    end)

    it("a store.refresh from a view (no external change) does not trigger a watcher refresh", function()
      local r = new_root()
      local _, base = acquire_settled(r)
      local done = false
      store.refresh(r, function()
        done = true
      end)
      assert(vim.wait(1500, function()
        return done
      end, 10), "store.refresh never completed")
      sleep(2000)
      assert.are.equal(base + 1, list_calls(r))
    end)
  end)

  describe("external updates close together", function()
    it("an update landing just after a watcher refresh finished is not lost", function()
      local r = new_root()
      local _, base = acquire_settled(r)
      external_write(r, 1)
      assert(vim.wait(1500, function()
        return list_calls(r) > base
      end, 10), "no refresh after the first external update")
      -- let the fake bd list finish, then a second external update lands shortly after
      sleep(150)
      external_write(r, 2)
      assert(vim.wait(2000, function()
        return list_calls(r) >= base + 2
      end, 10), "second external update was dropped: no second refresh")
      sleep(2000)
      assert.are.equal(base + 2, list_calls(r))
    end)

    it("an update landing while a watcher refresh is in flight is not lost", function()
      local r = new_root()
      local _, base = acquire_settled(r)
      vim.fn.writefile({ "0.6" }, fake_dir .. "/list_delay")
      external_write(r, 1)
      assert(vim.wait(1500, function()
        return list_calls(r) > base
      end, 10), "no refresh after the first external update")
      -- bd list is now running (sleeping 0.6s); a second external update lands
      sleep(100)
      external_write(r, 2)
      assert(vim.wait(4000, function()
        return list_calls(r) >= base + 2
      end, 10), "update during an in-flight refresh was dropped: no second refresh")
      sleep(2500)
      assert.are.equal(base + 2, list_calls(r))
    end)
  end)
end)
