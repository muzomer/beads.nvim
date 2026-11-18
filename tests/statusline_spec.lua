-- Bead beads_nvim-4u9.10: statusline component.
-- Interface under test:
--   require("beads").status() -> short string built from the store of cli.get_root():
--     "<in_progress glyph> <n>  <open glyph> <m> ready  💬 <k>" (epic design: "◐ 2  ○ 5 ready  💬 1"),
--     n = every in_progress bead (same as `bd list --status in_progress`), m = store ready_n,
--     k = beads waiting on the user (waiting_user). A bead that is in_progress AND waiting on
--     the user counts in both n and k (owner decision, review round 1, option (a)).
--   require("beads").lualine -> lualine component table whose [1] is a function rendering status().
-- status() must never spawn bd: a fake bd on PATH (test double) appends its argv to args.log.

local cli = require("beads.cli")
local store = require("beads.store")

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local FAKE_BD = [[#!/bin/sh
echo "$*" >> "$FAKE_DIR/args.log"
for a in "$@"; do
  case "$a" in
    ready) cat "$FAKE_DIR/ready.json"; exit 0 ;;
    list) cat "$FAKE_DIR/list.json"; exit 0 ;;
  esac
done
echo '[]'
]]

local function bead(id, extra)
  local b = {
    id = id,
    title = "Title " .. id,
    status = "open",
    priority = 2,
    issue_type = "task",
    updated_at = "2026-11-17T10:00:00Z",
    created_at = "2026-11-17T10:00:00Z",
  }
  for k, v in pairs(extra or {}) do
    b[k] = v
  end
  return b
end

local function waiting(id, extra)
  local b = bead(id, { labels = { "human" }, notes = "Agent: please decide X" })
  for k, v in pairs(extra or {}) do
    b[k] = v
  end
  return b
end

-- State A: 2 in progress, 3 ready, 1 waiting on the user (a closed human bead does not count).
local LIST_A = {
  bead("a-1", { status = "in_progress" }),
  bead("a-2", { status = "in_progress" }),
  bead("a-3"),
  waiting("a-4"),
  waiting("a-5", { status = "closed" }),
}
local READY_A = { bead("r-1"), bead("r-2"), bead("r-3") }

-- State B: 2 in progress (a-6 is also waiting on the user), 5 ready, 2 waiting on the user.
local LIST_B = {
  bead("a-1", { status = "in_progress" }),
  bead("a-2", { status = "closed" }),
  bead("a-3"),
  waiting("a-4"),
  waiting("a-6", { status = "in_progress" }),
}
local READY_B = { bead("r-1"), bead("r-2"), bead("r-3"), bead("r-4"), bead("r-5") }

local S = {}

local function write(name, data)
  vim.fn.writefile({ vim.json.encode(data) }, S.fake_dir .. "/" .. name)
end

local function log_count()
  local path = S.fake_dir .. "/args.log"
  if vim.fn.filereadable(path) == 0 then
    return 0
  end
  return #vim.fn.readfile(path)
end

local function refresh()
  local done, err = false, nil
  store.refresh(S.root, function(_, e)
    done, err = true, e
  end)
  assert(vim.wait(3000, function()
    return done
  end, 10), "store refresh never completed")
  assert.is_nil(err, "store refresh failed: " .. tostring(err))
end

local function count_waiting()
  local n = 0
  for _, b in pairs(store.get(S.root).by_id) do
    if b.waiting_user then
      n = n + 1
    end
  end
  return n
end

local function has(s, pat)
  return s:find(pat) ~= nil
end

local function assert_counts(s, ip, ready, wait)
  local g = vim.pesc(require("beads.glyphs").status("in_progress"))
  assert.is_true(has(s, g .. "%s*" .. ip .. "%f[%D]"), "in-progress count " .. ip .. " missing in '" .. s .. "'")
  assert.is_true(has(s, "%f[%d]" .. ready .. "%s+ready"), "'" .. ready .. " ready' missing in '" .. s .. "'")
  assert.is_true(has(s, "💬%s*" .. wait .. "%f[%D]"), "waiting count " .. wait .. " missing in '" .. s .. "'")
end

-- Calls fn many times, then waits so an async bd spawn would show up in the log.
local function assert_no_spawn(fn)
  local before = log_count()
  for _ = 1, 50 do
    fn()
  end
  vim.wait(300, function()
    return false
  end, 10)
  assert.are.equal(before, log_count(), "bd was spawned while rendering the status line")
end

describe("statusline", function()
  before_each(function()
    S.orig_path = vim.env.PATH
    S.bin_dir = vim.fn.tempname()
    vim.fn.mkdir(S.bin_dir, "p")
    vim.fn.writefile(vim.split(FAKE_BD, "\n"), S.bin_dir .. "/bd")
    vim.fn.setfperm(S.bin_dir .. "/bd", "rwxr-xr-x")
    S.fake_dir = vim.fn.tempname()
    vim.fn.mkdir(S.fake_dir, "p")
    write("list.json", LIST_A)
    write("ready.json", READY_A)
    vim.env.FAKE_DIR = S.fake_dir
    require("beads").setup({})
    vim.env.PATH = S.bin_dir .. ":" .. vim.env.PATH
    S.root = vim.fn.tempname()
    vim.fn.mkdir(S.root, "p")
    cli.set_root(S.root)
  end)

  after_each(function()
    vim.wait(100, function()
      return not store.is_refreshing(S.root)
    end, 10)
    cli.set_root(nil)
    vim.env.PATH = S.orig_path
    require("beads").setup({})
    vim.fn.delete(S.bin_dir, "rf")
    vim.fn.delete(S.fake_dir, "rf")
    vim.fn.delete(S.root, "rf")
  end)

  it("status() reflects the store counts", function()
    refresh()
    -- fixture sanity (not the behaviour under test)
    assert.are.equal(3, store.get(S.root).ready_n)
    assert.are.equal(1, count_waiting())
    local s = require("beads").status()
    assert.are.equal("string", type(s))
    assert_counts(s, 2, 3, 1)
  end)

  it("status() changes after a refresh", function()
    refresh()
    local before = require("beads").status()
    assert_counts(before, 2, 3, 1)
    write("list.json", LIST_B)
    write("ready.json", READY_B)
    refresh()
    assert.are.equal(5, store.get(S.root).ready_n)
    assert.are.equal(2, count_waiting())
    -- a-6 is in_progress AND waiting on the user: it counts in both the in-progress and the 💬 count.
    local a6 = store.get(S.root).by_id["a-6"]
    assert.are.equal("in_progress", a6.status)
    assert.is_truthy(a6.waiting_user, "fixture: a-6 should be waiting on the user")
    local after = require("beads").status()
    assert_counts(after, 2, 5, 2)
    assert.are_not.equal(before, after)
  end)

  it("status() never spawns bd, with an empty or a filled store", function()
    assert_no_spawn(function()
      assert.are.equal("string", type(require("beads").status()))
    end)
    refresh()
    assert_no_spawn(function()
      require("beads").status()
    end)
  end)

  it("lualine is a component table rendering the same text as status()", function()
    refresh()
    local c = require("beads").lualine
    assert.are.equal("table", type(c), "require('beads').lualine is not a table")
    assert.are.equal("function", type(c[1]), "lualine component [1] is not a function")
    assert.are.equal(require("beads").status(), c[1]())
    assert_no_spawn(function()
      c[1]()
    end)
  end)

  it("README documents lualine_x = { require('beads').lualine }", function()
    local text = table.concat(vim.fn.readfile(plugin_root .. "/README.md"), "\n")
    assert.is_truthy(
      text:find("lualine_x%s*=%s*{%s*require%s*%(?%s*[\"']beads[\"']%s*%)?%s*%.lualine"),
      "README lacks lualine_x = { require('beads').lualine }"
    )
  end)
end)
