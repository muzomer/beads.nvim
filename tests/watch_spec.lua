-- Interface under test (bead beads_nvim-ge7.14): lua/beads/watch.lua
--   local watch = require("beads.watch")
--   local release = watch.acquire(root)
--     Reference-counted per root: a beads view calls acquire() when it opens and the
--     returned release() when it closes. The first acquire for a root runs
--     `bd -C <root> context --json`:
--       dolt_mode == "embedded" -> uv.fs_event watcher(s) on <root>/.beads/, reacting to
--         'last-touched' and 'embeddeddolt/<db>/.dolt/noms/manifest'; events are debounced
--         (200ms) into ONE store.refresh(root); a refresh inside the store's self-write
--         window (store.mark_self_write / consume_self_write) is skipped.
--       otherwise -> no fs_event; refresh on FocusGained (and BufEnter of beads buffers);
--         one notice via vim.notify.
--     The last release() for a root stops the watcher (fs_event handles closed).
--
-- `bd` is replaced by a generated shell script on PATH (test double for the external binary).
--   context: prints JSON shaped like real `bd context --json`; dolt_mode from $FAKE_DIR/mode.
--   list:    logs the call, prints [] and rewrites the manifest with the same content
--            (real bd 1.2.2 does this on every read, so a naive watcher would loop).
-- Every call is logged to $FAKE_DIR/<basename of -C>.calls.

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
local releases, notices

local function new_root()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/.beads/embeddeddolt/db/.dolt/noms", "p")
  vim.fn.writefile({ "x" }, dir .. "/.beads/last-touched")
  vim.fn.writefile({ "manifest-v1" }, dir .. "/.beads/embeddeddolt/db/.dolt/noms/manifest")
  vim.fn.writefile({ "" }, dir .. "/.beads/issues.jsonl")
  return dir
end

local function set_mode(mode)
  vim.fn.writefile({ mode }, fake_dir .. "/mode")
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

-- Number of live (not closing) fs_event handles in the loop.
local function live_fs_events()
  local n = 0
  vim.uv.walk(function(h)
    if h:get_type() == "fs_event" and not h:is_closing() then
      n = n + 1
    end
  end)
  return n
end

local function acquire(r)
  local rel = watch.acquire(r)
  assert.is_function(rel, "watch.acquire must return a release function")
  table.insert(releases, rel)
  return rel
end

-- Acquire and wait until `bd context` ran and startup has settled; returns the
-- list-call baseline.
local function acquire_settled(r)
  local rel = acquire(r)
  assert(vim.wait(3000, function()
    return calls(r, "context") > 0
  end, 10), "bd context --json was never called")
  sleep(400)
  return rel, list_calls(r)
end

local function touch(path, i)
  vim.fn.writefile({ "w" .. tostring(i or vim.uv.hrtime()) }, path)
end

describe("beads.watch", function()
  before_each(function()
    releases = {}
    notices = {}
    orig_path = vim.env.PATH
    orig_notify = vim.notify
    vim.notify = function(msg, level, opts)
      table.insert(notices, { msg = msg, level = level })
    end
    bin_dir = vim.fn.tempname()
    vim.fn.mkdir(bin_dir, "p")
    vim.fn.writefile(vim.split(FAKE_BD, "\n"), bin_dir .. "/bd")
    vim.fn.setfperm(bin_dir .. "/bd", "rwxr-xr-x")
    fake_dir = vim.fn.tempname()
    vim.fn.mkdir(fake_dir, "p")
    vim.env.FAKE_DIR = fake_dir
    vim.env.PATH = bin_dir .. ":" .. orig_path
    set_mode("embedded")
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

  describe("embedded backend", function()
    it("runs bd context --json for the root on first acquire", function()
      local r = new_root()
      acquire_settled(r)
      assert.is_true(calls(r, "-C " .. r) > 0, "bd must be called with -C <root>")
      assert.are.equal(1, calls(r, "context --json"))
    end)

    it("opens an fs_event watcher", function()
      local before = live_fs_events()
      local r = new_root()
      acquire_settled(r)
      assert.is_true(live_fs_events() > before, "expected at least one live fs_event handle")
    end)

    it("a write to last-touched causes exactly one refresh", function()
      local r = new_root()
      local _, base = acquire_settled(r)
      touch(r .. "/.beads/last-touched", 1)
      assert(vim.wait(1500, function()
        return list_calls(r) > base
      end, 10), "no store refresh after last-touched changed")
      -- wait well past the first refresh: its manifest rewrite must not loop
      sleep(2000)
      assert.are.equal(base + 1, list_calls(r))
    end)

    it("a write to the dolt manifest causes exactly one refresh", function()
      local r = new_root()
      local _, base = acquire_settled(r)
      touch(r .. "/.beads/embeddeddolt/db/.dolt/noms/manifest", 1)
      assert(vim.wait(1500, function()
        return list_calls(r) > base
      end, 10), "no store refresh after the manifest changed")
      sleep(2000)
      assert.are.equal(base + 1, list_calls(r))
    end)

    it("ten rapid writes produce one refresh (debounce)", function()
      local r = new_root()
      local _, base = acquire_settled(r)
      for i = 1, 10 do
        touch(r .. "/.beads/last-touched", i)
        if i % 2 == 0 then
          touch(r .. "/.beads/embeddeddolt/db/.dolt/noms/manifest", i)
        end
        sleep(15)
      end
      assert(vim.wait(1500, function()
        return list_calls(r) > base
      end, 10), "no store refresh after rapid writes")
      sleep(2000)
      assert.are.equal(base + 1, list_calls(r))
    end)

    it("does not refresh before the 200ms debounce has passed", function()
      local r = new_root()
      local _, base = acquire_settled(r)
      touch(r .. "/.beads/last-touched", 1)
      sleep(100)
      assert.are.equal(base, list_calls(r))
    end)

    it("ignores writes to other files in .beads/", function()
      local r = new_root()
      local _, base = acquire_settled(r)
      touch(r .. "/.beads/issues.jsonl", 1)
      sleep(800)
      assert.are.equal(base, list_calls(r))
    end)

    it("a write made through the plugin (self-write window) does not refresh again", function()
      local r = new_root()
      local _, base = acquire_settled(r)
      store.mark_self_write(r)
      touch(r .. "/.beads/last-touched", 1)
      touch(r .. "/.beads/embeddeddolt/db/.dolt/noms/manifest", 1)
      sleep(800)
      assert.are.equal(base, list_calls(r))
    end)

    it("a second view does not start a second watcher or a second bd context", function()
      local before = live_fs_events()
      local r = new_root()
      acquire_settled(r)
      local one = live_fs_events() - before
      acquire(r)
      sleep(400)
      assert.are.equal(one, live_fs_events() - before)
      assert.are.equal(1, calls(r, "context"))
    end)

    it("closing one of two views keeps the watcher running", function()
      local before = live_fs_events()
      local r = new_root()
      local rel1 = acquire_settled(r)
      acquire(r)
      sleep(100)
      rel1()
      sleep(100)
      assert.is_true(live_fs_events() > before, "watcher stopped while a view is still open")
      local base = list_calls(r)
      touch(r .. "/.beads/last-touched", 1)
      assert(vim.wait(1500, function()
        return list_calls(r) > base
      end, 10), "no refresh while one view is still open")
    end)

    it("closing the last view stops the watcher (handles closed)", function()
      local before = live_fs_events()
      local r = new_root()
      local rel1 = acquire_settled(r)
      local rel2 = acquire(r)
      sleep(100)
      rel1()
      rel2()
      sleep(100)
      assert.are.equal(before, live_fs_events())
      local base = list_calls(r)
      touch(r .. "/.beads/last-touched", 1)
      touch(r .. "/.beads/embeddeddolt/db/.dolt/noms/manifest", 1)
      sleep(800)
      assert.are.equal(base, list_calls(r))
    end)

    it("does not react to FocusGained", function()
      local r = new_root()
      local _, base = acquire_settled(r)
      vim.api.nvim_exec_autocmds("FocusGained", {})
      sleep(500)
      assert.are.equal(base, list_calls(r))
    end)
  end)

  describe("non-embedded backend", function()
    before_each(function()
      set_mode("server")
    end)

    it("opens no fs_event watcher on .beads (only the questions watcher on .beads-nvim)", function()
      local before = live_fs_events()
      local r = new_root()
      acquire_settled(r)
      assert.are.equal(before + 1, live_fs_events())
      local base = list_calls(r)
      touch(r .. "/.beads/last-touched", 1)
      sleep(800)
      assert.are.equal(base, list_calls(r))
    end)

    it("refreshes the store on FocusGained", function()
      local r = new_root()
      local _, base = acquire_settled(r)
      local buf = vim.api.nvim_create_buf(true, true)
      vim.api.nvim_buf_set_name(buf, "beads://watch-focus-" .. vim.fn.fnamemodify(r, ":t"))
      local prev = vim.api.nvim_get_current_buf()
      vim.api.nvim_set_current_buf(buf)
      local after_enter = list_calls(r)
      vim.api.nvim_exec_autocmds("FocusGained", {})
      local ok = vim.wait(1500, function()
        return list_calls(r) > after_enter
      end, 10)
      vim.api.nvim_set_current_buf(prev)
      vim.api.nvim_buf_delete(buf, { force = true })
      assert.is_true(ok, "no store refresh after FocusGained")
      assert.is_true(base <= after_enter)
    end)

    it("shows a single notice for several views and focus events", function()
      local r = new_root()
      acquire_settled(r)
      acquire(r)
      vim.api.nvim_exec_autocmds("FocusGained", {})
      sleep(200)
      vim.api.nvim_exec_autocmds("FocusGained", {})
      sleep(300)
      assert.are.equal(1, #notices, "notices: " .. vim.inspect(notices))
    end)

    it("stops refreshing on FocusGained after the last view closes", function()
      local r = new_root()
      local rel = acquire_settled(r)
      rel()
      sleep(100)
      local base = list_calls(r)
      vim.api.nvim_exec_autocmds("FocusGained", {})
      sleep(500)
      assert.are.equal(base, list_calls(r))
    end)
  end)
end)
