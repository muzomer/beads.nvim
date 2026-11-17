-- Interface under test (bead beads_nvim-ge7.14): see tests/watch_spec.lua.
-- Integration: with a real embedded bd repo and a view open (watch.acquire), running
-- `bd update` from a shell causes exactly one store refresh shortly after it exits.

local helpers = require("tests.helpers")
local store = require("beads.store")

local function sleep(ms)
  vim.wait(ms, function()
    return false
  end, 10)
end

local function live_fs_events()
  local n = 0
  vim.uv.walk(function(h)
    if h:get_type() == "fs_event" and not h:is_closing() then
      n = n + 1
    end
  end)
  return n
end

describe("beads.watch integration", function()
  if not helpers.has_bd() then
    pending("bd executable not found")
    return
  end

  it("bd update from a shell causes exactly one store refresh", function()
    package.loaded["beads.watch"] = nil
    local watch = require("beads.watch")
    helpers.with_bd_repo(function(dir)
      local c = vim.system({ "bd", "-C", dir, "create", "watched", "--json" }, { text = true }):wait()
      assert.are.equal(0, c.code, "bd create failed: " .. tostring(c.stderr))
      local id = vim.json.decode(c.stdout).id

      local refreshes, last_at = 0, nil
      local unsub = store.subscribe(dir, function()
        refreshes = refreshes + 1
        last_at = vim.uv.now()
      end)
      local before = live_fs_events()
      local release = watch.acquire(dir)
      local ok, err = pcall(function()
        assert(vim.wait(10000, function()
          return live_fs_events() > before
        end, 20), "watcher never started")
        sleep(2000)
        local base = refreshes

        local u = vim.system({ "bd", "-C", dir, "update", id, "--priority", "1" }, { text = true }):wait()
        assert.are.equal(0, u.code, "bd update failed: " .. tostring(u.stderr))
        local t0 = vim.uv.now()
        assert(vim.wait(5000, function()
          return refreshes > base
        end, 10), "no store refresh after bd update")
        local first_at = last_at
        assert.is_true(first_at - t0 <= 1500, "refresh took " .. (first_at - t0) .. "ms after bd update exited")
        -- wait well past the first refresh: bd list rewrites the manifest, which must not loop
        sleep(2500)
        assert.are.equal(base + 1, refreshes)
      end)
      release()
      unsub()
      sleep(200)
      if not ok then
        error(err, 0)
      end
    end)
  end)
end)
