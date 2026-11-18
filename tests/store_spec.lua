-- Interface under test (bead beads_nvim-ge7.5): lua/beads/store.lua
--   local store = require("beads.store")
--   One in-memory store per root, filled by `bd -C <root> list -n 0 --json --all`
--   (cli.list({ all = true })) and normalized with beads.model.
--
--   store.get(root) -> state
--     state.by_id            map id -> normalized bead
--     state.children_of(id)  list of beads whose parent is id (any order; closed included)
--     state.roots()          list of parentless beads (any order; closed included)
--   store.refresh(root, cb?)       cb(state, err) once the refresh completes
--   store.subscribe(root, fn) -> unsubscribe()
--     fn(state, err) is called once per completed refresh; err == nil on success,
--     err = message string on failure (state then still holds the previous data).
--   Concurrent refreshes coalesce: one bd call in flight plus at most one trailing call.
--
-- `bd` is replaced by a generated shell script on PATH (test double for the external binary).
-- Per root (keyed by basename of the -C value) it prints $FAKE_DIR/<name>.json, fails when
-- $FAKE_DIR/<name>.fail exists, and waits for $FAKE_DIR/release before answering.

local store = require("beads.store")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local FAKE_BD = [[#!/bin/sh
r=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-C" ]; then r="$a"; fi
  prev="$a"
done
name=$(basename "$r")
printf '%s\n' "$*" >> "$FAKE_DIR/$name.calls"
i=0
while [ ! -f "$FAKE_DIR/release" ] && [ $i -lt 250 ]; do
  sleep 0.02
  i=$((i + 1))
done
if [ -f "$FAKE_DIR/$name.fail" ]; then
  printf 'boom: database locked' >&2
  exit 1
fi
cat "$FAKE_DIR/$name.json"
]]

local orig_path, bin_dir, fake_dir

local function new_root()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

local function name_of(r)
  return vim.fn.fnamemodify(r, ":t")
end

local function set_data(r, json)
  vim.fn.writefile(vim.split(json, "\n", { plain = true }), fake_dir .. "/" .. name_of(r) .. ".json")
end

local function set_fail(r, on)
  local f = fake_dir .. "/" .. name_of(r) .. ".fail"
  if on then
    vim.fn.writefile({ "" }, f)
  else
    vim.fn.delete(f)
  end
end

local function calls(r)
  local f = fake_dir .. "/" .. name_of(r) .. ".calls"
  if vim.fn.filereadable(f) == 0 then
    return {}
  end
  -- the store also runs bd ready inside a refresh (header count); these tests are about bd list
  local out = {}
  for _, line in ipairs(vim.fn.readfile(f)) do
    if not (" " .. line .. " "):find(" ready ", 1, true) then
      out[#out + 1] = line
    end
  end
  return out
end

local function hold()
  vim.fn.delete(fake_dir .. "/release")
end

local function release()
  vim.fn.writefile({ "" }, fake_dir .. "/release")
end

local function settle()
  vim.wait(300, function()
    return false
  end, 10)
end

local function ids(beads)
  local out = {}
  for _, b in ipairs(beads or {}) do
    out[#out + 1] = b.id
  end
  table.sort(out)
  return out
end

local function keys(map)
  local out = vim.tbl_keys(map or {})
  table.sort(out)
  return out
end

-- Refreshes and waits for the completion callback; returns state, err.
local function refresh_wait(r)
  local done, st, e = false, nil, nil
  store.refresh(r, function(s, err)
    done, st, e = true, s, err
  end)
  assert(vim.wait(5000, function()
    return done
  end, 10), "refresh callback was never called")
  return st, e
end

local function fixture_json()
  return table.concat(vim.fn.readfile(root .. "/tests/fixtures/model_list.json"), "\n")
end

describe("beads.store", function()
  before_each(function()
    orig_path = vim.env.PATH
    bin_dir = vim.fn.tempname()
    vim.fn.mkdir(bin_dir, "p")
    vim.fn.writefile(vim.split(FAKE_BD, "\n"), bin_dir .. "/bd")
    vim.fn.setfperm(bin_dir .. "/bd", "rwxr-xr-x")
    fake_dir = vim.fn.tempname()
    vim.fn.mkdir(fake_dir, "p")
    vim.env.FAKE_DIR = fake_dir
    vim.env.PATH = bin_dir .. ":" .. orig_path
    release()
  end)

  after_each(function()
    release()
    settle()
    vim.env.PATH = orig_path
    vim.fn.delete(bin_dir, "rf")
    vim.fn.delete(fake_dir, "rf")
  end)

  describe("refresh", function()
    it("runs bd list --all -n 0 --json with -C <root> and fills by_id", function()
      local r = new_root()
      set_data(r, fixture_json())
      local st, err = refresh_wait(r)
      assert.is_nil(err)
      local c = calls(r)
      assert.are.equal(1, #c, vim.inspect(c))
      local args = vim.split(c[1], " ", { plain = true })
      assert.is_true(vim.tbl_contains(args, "list"), c[1])
      assert.is_true(vim.tbl_contains(args, "--all"), c[1])
      assert.is_true(vim.tbl_contains(args, "--json"), c[1])
      assert.is_truthy(c[1]:find("-n 0", 1, true), c[1])
      assert.are.same({ "fx-17x", "fx-80s", "fx-cfa", "fx-cfa.1" }, keys(st.by_id))
      assert.are.same({ "fx-17x", "fx-80s", "fx-cfa", "fx-cfa.1" }, keys(store.get(r).by_id))
      assert.are.equal("fx-cfa", store.get(r).by_id["fx-cfa.1"].parent)
    end)

    it("two refresh() calls while one is in flight produce at most two bd list invocations", function()
      local r = new_root()
      set_data(r, '[{"id":"a-1","title":"One","status":"open"}]')
      hold()
      local cbs = 0
      store.refresh(r, function()
        cbs = cbs + 1
      end)
      assert(vim.wait(5000, function()
        return #calls(r) >= 1
      end, 10), "first bd list never started")
      -- data changes while the first call is in flight
      set_data(r, '[{"id":"a-1","title":"One","status":"open"},{"id":"a-2","title":"Two","status":"open"}]')
      store.refresh(r, function()
        cbs = cbs + 1
      end)
      store.refresh(r, function()
        cbs = cbs + 1
      end)
      settle()
      assert.are.equal(1, #calls(r), "a second bd call started while one was in flight")
      release()
      assert(vim.wait(5000, function()
        return cbs == 3
      end, 10), "not every refresh callback was called, got " .. cbs)
      settle()
      local n = #calls(r)
      assert.is_true(n <= 2, "expected at most 2 bd list invocations, got " .. n)
      assert.are.equal(2, n, "expected one trailing call for requests made mid-flight")
      assert.are.same({ "a-1", "a-2" }, keys(store.get(r).by_id))
    end)
  end)

  describe("subscribers", function()
    it("are notified once per completed refresh with the new state; unsubscribe stops it", function()
      local r = new_root()
      set_data(r, '[{"id":"s-1","title":"One","status":"open"}]')
      local seen = {}
      local unsub = store.subscribe(r, function(st, err)
        seen[#seen + 1] = { ids = keys(st and st.by_id), err = err }
      end)
      assert.are.equal("function", type(unsub))

      refresh_wait(r)
      settle()
      assert.are.equal(1, #seen, vim.inspect(seen))
      assert.is_nil(seen[1].err)
      assert.are.same({ "s-1" }, seen[1].ids)

      set_data(r, '[{"id":"s-1","title":"One","status":"open"},{"id":"s-2","title":"Two","status":"open"}]')
      refresh_wait(r)
      settle()
      assert.are.equal(2, #seen, vim.inspect(seen))
      assert.are.same({ "s-1", "s-2" }, seen[2].ids)

      unsub()
      refresh_wait(r)
      settle()
      assert.are.equal(2, #seen, "subscriber called after unsubscribe")
    end)

    it("a failed refresh keeps the previous data and reports the error", function()
      local r = new_root()
      set_data(r, '[{"id":"f-1","title":"One","status":"open"}]')
      refresh_wait(r)
      local seen = {}
      store.subscribe(r, function(st, err)
        seen[#seen + 1] = { ids = keys(st and st.by_id), err = err }
      end)
      set_fail(r, true)
      local st, err = refresh_wait(r)
      settle()
      assert.are.equal("string", type(err))
      assert.are.equal(1, #seen, vim.inspect(seen))
      assert.are.equal("string", type(seen[1].err))
      assert.is_truthy(seen[1].err:find("boom", 1, true), seen[1].err)
      assert.are.same({ "f-1" }, seen[1].ids)
      assert.are.same({ "f-1" }, keys(st.by_id))
      assert.are.same({ "f-1" }, keys(store.get(r).by_id))
    end)
  end)

  describe("tree", function()
    it("children_of and roots reflect parent-child links, closed beads included", function()
      local r = new_root()
      set_data(r, fixture_json())
      refresh_wait(r)
      local st = store.get(r)
      assert.are.same({ "fx-cfa.1" }, ids(st.children_of("fx-cfa")))
      assert.are.same({}, ids(st.children_of("fx-80s")))
      assert.are.same({ "fx-17x", "fx-80s", "fx-cfa" }, ids(st.roots()))
    end)

    it("includes closed children", function()
      local r = new_root()
      set_data(
        r,
        vim.json.encode({
          { id = "p-1", title = "Epic", status = "open" },
          { id = "p-1.1", title = "Open child", status = "open", parent = "p-1" },
          {
            id = "p-1.2",
            title = "Closed child",
            status = "closed",
            dependencies = { { issue_id = "p-1.2", depends_on_id = "p-1", type = "parent-child" } },
          },
          { id = "p-2", title = "Closed root", status = "closed" },
        })
      )
      refresh_wait(r)
      local st = store.get(r)
      assert.are.same({ "p-1.1", "p-1.2" }, ids(st.children_of("p-1")))
      assert.are.same({ "p-1", "p-2" }, ids(st.roots()))
    end)
  end)

  describe("roots", function()
    it("stores for two different roots are independent", function()
      local a, b = new_root(), new_root()
      set_data(a, '[{"id":"a-1","title":"A","status":"open"}]')
      set_data(b, '[{"id":"b-1","title":"B","status":"open"}]')
      refresh_wait(a)
      refresh_wait(b)
      assert.are.same({ "a-1" }, keys(store.get(a).by_id))
      assert.are.same({ "b-1" }, keys(store.get(b).by_id))

      local b_seen = 0
      store.subscribe(b, function()
        b_seen = b_seen + 1
      end)
      set_data(a, '[{"id":"a-1","title":"A","status":"open"},{"id":"a-2","title":"A2","status":"open"}]')
      refresh_wait(a)
      settle()
      assert.are.same({ "a-1", "a-2" }, keys(store.get(a).by_id))
      assert.are.same({ "b-1" }, keys(store.get(b).by_id))
      assert.are.equal(0, b_seen, "subscriber of root b notified by refresh of root a")
      assert.are.equal(1, #calls(b), "refreshing root a ran bd for root b")
    end)
  end)
end)
