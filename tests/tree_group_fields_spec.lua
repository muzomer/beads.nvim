-- Bead beads_nvim-2qo.2: group actions set status / priority / assignee / type, add / remove a
-- label, move under an epic (or remove the parent), blocked by X / remove that dependency.
-- Interface under test: the tree's A menu (keymaps.tree_view.actions) on marked beads.
--
-- `bd` is replaced by a shell script on PATH (test double for the external binary). Every call is
-- logged to $FAKE_DIR/calls.log as one line of bracketed args ("[-C][<dir>][update][t-1]...") so
-- empty args stay visible; for `batch -f <file>` the file's lines are logged too, prefixed with
-- "BATCH: ". Write verbs bump .beads/last-touched and the Dolt manifest like real bd.
--
-- assumption: A is a vim.ui.select whose entries' text names the action: "priority", "status",
--   "assignee", "type", "label" (+ "add" / "remove"), "epic" or "parent" for move under epic,
--   "block" for blocked by, and "remove"/"unblock" + "block"/"dep" for removing the dependency.
-- assumption: the value is asked once, by vim.ui.select (item text holds the value / bead id) or
--   by vim.ui.input (answer typed); the >1-bead confirmation is a vim.ui.input "[y/N]" prompt.
-- assumption: remove parent is either its own A entry (text with "parent" + "remove"/"clear") or
--   an item of the epic picker whose text contains "remove", "clear", "none" or "no parent";
--   it runs `bd update <id> --parent ""` (or --parent=) per bead.
-- assumption: the blocker picker (or id input) lets the user choose a selected bead; that choice
--   is refused with a notification and runs nothing.
-- assumption: batch lines use the bd batch grammar: `update <id> priority=1`,
--   `dep add <selected> <X> [blocks]`, `dep remove <selected> <X>` (selected depends on X).

local cli = require("beads.cli")
local H = require("tests.group_actions_harness")

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local FAKE_BD = [[#!/bin/sh
d="$FAKE_DIR"
line=""
for a in "$@"; do line="$line[$a]"; done
printf '%s\n' "$line" >> "$d/calls.log"
m="$d/.beads/embeddeddolt/db/.dolt/noms/manifest"
wrote() {
  echo "w$$-$(date +%s%N)" > "$d/.beads/last-touched"
  echo "w$$-$(date +%s%N)" > "$m"
}
case " $* " in
  *" context "*)
    printf '{"backend":"dolt","beads_dir":"%s/.beads","database":"db","dolt_mode":"embedded","repo_root":"%s","is_redirected":false,"is_worktree":false,"schema_version":1}\n' "$d" "$d"
    ;;
  *" list "*)
    cat "$d/list.json"
    ;;
  *" ready "*)
    printf '[]\n'
    ;;
  *" batch "*)
    prev=""
    for a in "$@"; do
      if [ "$prev" = "-f" ] || [ "$prev" = "--file" ]; then sed 's/^/BATCH: /' "$a" >> "$d/calls.log"; fi
      prev="$a"
    done
    wrote
    printf 'ok\n'
    ;;
  *" update "*|*" close "*|*" reopen "*|*" dep "*|*" label "*)
    wrote
    printf '{}\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
]]

local dir, orig_path

local function bead(id, title, extra)
  local b = {
    id = id,
    title = title,
    status = "open",
    priority = 2,
    issue_type = "task",
    created_at = "2026-11-17T10:00:00Z",
    updated_at = "2026-11-17T10:00:00Z",
  }
  for k, v in pairs(extra or {}) do
    b[k] = v
  end
  return b
end

-- ep-1 > { t-1, t-2 }; ep-2 (epic, no children); t-3, t-4. t-1 and t-3 carry label "old" and
-- are blocked by t-4.
local function items()
  return {
    bead("ep-1", "Epic one", { issue_type = "epic", priority = 1 }),
    bead("t-1", "Task one", {
      parent = "ep-1",
      labels = { "old", "keep" },
      dependencies = {
        { issue_id = "t-1", depends_on_id = "ep-1", type = "parent-child" },
        { issue_id = "t-1", depends_on_id = "t-4", type = "blocks" },
      },
    }),
    bead("t-2", "Task two", {
      parent = "ep-1",
      dependencies = { { issue_id = "t-2", depends_on_id = "ep-1", type = "parent-child" } },
    }),
    bead("ep-2", "Epic two", { issue_type = "epic", priority = 1 }),
    bead("t-3", "Task three", {
      priority = 3,
      labels = { "old" },
      dependencies = { { issue_id = "t-3", depends_on_id = "t-4", type = "blocks" } },
    }),
    bead("t-4", "Task four", { priority = 3 }),
  }
end

local ALL_IDS = { "ep-1", "t-1", "t-2", "ep-2", "t-3", "t-4" }

local function log()
  local p = dir .. "/calls.log"
  return vim.fn.filereadable(p) == 1 and vim.fn.readfile(p) or {}
end

local function log_dump()
  return table.concat(log(), "\n")
end

-- argv lists of every bd call (without the leading -C <dir>).
local function calls()
  local out = {}
  for _, l in ipairs(log()) do
    if not vim.startswith(l, "BATCH: ") then
      local args = {}
      for a in l:gmatch("%[(.-)%]") do
        args[#args + 1] = a
      end
      if args[1] == "-C" then
        args = vim.list_slice(args, 3)
      end
      out[#out + 1] = args
    end
  end
  return out
end

local function batch_lines()
  local out = {}
  for _, l in ipairs(log()) do
    if vim.startswith(l, "BATCH: ") then
      local s = vim.trim(l:sub(8))
      if s ~= "" and not vim.startswith(s, "#") then
        out[#out + 1] = s
      end
    end
  end
  return out
end

local function verb(args)
  for _, a in ipairs(args) do
    if a:sub(1, 1) ~= "-" then
      return a
    end
  end
end

local WRITE = { batch = true, update = true, close = true, reopen = true, dep = true, label = true, create = true }

local function write_calls()
  local out = {}
  for _, a in ipairs(calls()) do
    if WRITE[verb(a) or ""] then
      out[#out + 1] = table.concat(a, " ")
    end
  end
  return out
end

local function count_verb(v)
  local n = 0
  for _, a in ipairs(calls()) do
    if verb(a) == v then
      n = n + 1
    end
  end
  return n
end

-- `bd update` argv lists naming id.
local function updates_of(id)
  local out = {}
  for _, a in ipairs(calls()) do
    if verb(a) == "update" and vim.tbl_contains(a, id) then
      out[#out + 1] = a
    end
  end
  return out
end

-- value of flag in argv (--flag v, --flag=v, or short alias), or nil.
local function flag(args, names)
  for i, a in ipairs(args) do
    for _, n in ipairs(names) do
      if a == n then
        return args[i + 1]
      end
      if vim.startswith(a, n .. "=") then
        return a:sub(#n + 2)
      end
    end
  end
end

local function unquote(s)
  return (s or ""):gsub('^"(.*)"$', "%1")
end

-- batch lines `update <id> <key>=<value>`: { [id] = value }; count of update lines.
local function batch_updates(key)
  local got, n = {}, 0
  for _, l in ipairs(batch_lines()) do
    local id, rest = l:match("^update%s+(%S+)%s+(.*)$")
    if id then
      n = n + 1
      local v = rest:match(key .. '=("[^"]*")') or rest:match(key .. "=(%S+)")
      if v then
        got[id] = unquote(v)
      end
    end
  end
  return got, n
end

-- batch lines `dep <op> <from> <to> [type]` -> list of "from>to" (type ignored when blocks).
local function batch_deps(op)
  local out = {}
  for _, l in ipairs(batch_lines()) do
    local from, to, ty = l:match("^dep%s+" .. op .. "%s+(%S+)%s+(%S+)%s*(%S*)")
    if from then
      assert(ty == "" or ty == "blocks", "unexpected dep type: " .. l)
      out[#out + 1] = from .. ">" .. to
    end
  end
  table.sort(out)
  return out
end

local function wait_writes(pred, what)
  H.wait_for(pred, what .. "; bd log:\n" .. log_dump())
  H.sleep(300)
end

describe("tree group actions: fields, labels, parent, dependencies", function()
  before_each(function()
    orig_path = vim.env.PATH
    H.install()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d .. "/.beads/embeddeddolt/db/.dolt/noms", "p")
    dir = vim.fn.resolve(d)
    vim.fn.writefile({ "x" }, dir .. "/.beads/last-touched")
    vim.fn.writefile({ "manifest-v1" }, dir .. "/.beads/embeddeddolt/db/.dolt/noms/manifest")
    vim.fn.writefile({ "" }, dir .. "/.beads/issues.jsonl")
    vim.fn.writefile(vim.split(FAKE_BD, "\n"), dir .. "/bd")
    vim.fn.setfperm(dir .. "/bd", "rwxr-xr-x")
    vim.fn.writefile({ vim.json.encode(items()) }, dir .. "/list.json")
    vim.env.FAKE_DIR = dir
    vim.env.PATH = dir .. ":" .. orig_path
    vim.cmd.cd(vim.fn.fnameescape(dir))
    cli.set_root(dir)
    if vim.fn.exists(":Beads") == 0 then
      vim.cmd.source(plugin_root .. "/plugin/beads.lua")
    end
    require("beads").setup({ fzf = false })
    H.open_tree("t-4")
  end)

  after_each(function()
    H.close_all()
    H.sleep(300)
    H.restore()
    vim.env.PATH = orig_path
    cli.set_root(nil)
    vim.cmd.cd(vim.fn.fnameescape(plugin_root))
    vim.fn.delete(dir, "rf")
    require("beads").setup({})
  end)

  -- ── batch: priority / status / assignee ──────────────────────────────────────────────────────
  it("set priority on 4 marked beads asks once, confirms, and runs one bd batch with 4 update lines", function()
    H.mark({ "t-1", "t-2", "t-3", "t-4" })
    local st = H.act({
      name = "priority",
      menu = H.menu.priority,
      value = {
        input = "1",
        pick = function(t)
          return t:find("p1", 1, true) ~= nil or t:match("^%s*1%f[%D]") ~= nil or t:find("priority 1", 1, true) ~= nil
        end,
      },
    })
    wait_writes(function()
      return count_verb("batch") >= 1
    end, "the priority batch")
    assert.are.equal(1, st.value_prompts, "priority value asked " .. st.value_prompts .. " times")
    assert.are.equal(1, #st.confirms, "expected one [y/N] confirmation")
    assert.is_truthy(st.confirms[1]:find("4", 1, true), "confirmation does not name 4 beads: " .. st.confirms[1])
    assert.are.equal(1, count_verb("batch"), "expected one bd batch:\n" .. log_dump())
    assert.are.equal(0, count_verb("update"), "beads updated outside the batch:\n" .. log_dump())
    local got, n = batch_updates("priority")
    assert.are.equal(4, n, "expected 4 update lines:\n" .. log_dump())
    for _, id in ipairs({ "t-1", "t-2", "t-3", "t-4" }) do
      assert.is_truthy(got[id] == "1" or got[id] == "P1", id .. " priority line wrong:\n" .. log_dump())
    end
  end)

  it("set status on 3 marked beads runs one bd batch with status=in_progress for each", function()
    H.mark({ "t-1", "t-3", "t-4" })
    local st = H.act({
      name = "status",
      menu = H.menu.status,
      value = {
        input = "in_progress",
        pick = function(t)
          return t:find("in_progress", 1, true) ~= nil or t:find("in progress", 1, true) ~= nil
        end,
      },
    })
    wait_writes(function()
      return count_verb("batch") >= 1
    end, "the status batch")
    assert.are.equal(1, st.value_prompts)
    assert.are.equal(1, count_verb("batch"), log_dump())
    assert.are.equal(0, count_verb("update"), log_dump())
    local got, n = batch_updates("status")
    assert.are.equal(3, n, log_dump())
    assert.are.same({ ["t-1"] = "in_progress", ["t-3"] = "in_progress", ["t-4"] = "in_progress" }, got)
  end)

  it("set assignee on 2 marked beads runs one bd batch with assignee=alice for each", function()
    H.mark({ "t-2", "t-3" })
    local st = H.act({
      name = "assignee",
      menu = H.menu.assignee,
      value = {
        input = "alice",
        pick = function(t)
          return t:find("alice", 1, true) ~= nil
        end,
      },
    })
    wait_writes(function()
      return count_verb("batch") >= 1
    end, "the assignee batch")
    assert.are.equal(1, st.value_prompts)
    assert.are.equal(1, count_verb("batch"), log_dump())
    assert.are.equal(0, count_verb("update"), log_dump())
    local got, n = batch_updates("assignee")
    assert.are.equal(2, n, log_dump())
    assert.are.same({ ["t-2"] = "alice", ["t-3"] = "alice" }, got)
  end)

  -- ── per bead: type / labels / parent ─────────────────────────────────────────────────────────
  local function assert_per_bead(ids, names, want)
    assert.are.equal(0, count_verb("batch"), "per-bead action went through bd batch:\n" .. log_dump())
    for _, id in ipairs(ids) do
      local ups = updates_of(id)
      assert.are.equal(1, #ups, id .. ": expected one bd update:\n" .. log_dump())
      assert.are.equal(want, flag(ups[1], names), id .. ": wrong " .. names[1] .. ":\n" .. log_dump())
    end
  end

  it("set type runs one bd update --type per marked bead", function()
    local ids = { "t-1", "t-3", "t-4" }
    H.mark(ids)
    local st = H.act({
      name = "type",
      menu = H.menu.type,
      value = {
        input = "bug",
        pick = function(t)
          return t:find("bug", 1, true) ~= nil
        end,
      },
    })
    wait_writes(function()
      return count_verb("update") >= 3
    end, "three updates")
    assert.are.equal(1, st.value_prompts)
    assert_per_bead(ids, { "--type", "-t" }, "bug")
  end)

  it("add label runs one bd update --add-label per marked bead", function()
    local ids = { "t-2", "t-3" }
    H.mark(ids)
    H.act({
      name = "add label",
      menu = H.menu.add_label,
      value = {
        input = "urgent",
        pick = function(t)
          return t:find("urgent", 1, true) ~= nil
        end,
      },
    })
    wait_writes(function()
      return count_verb("update") >= 2
    end, "two updates")
    assert_per_bead(ids, { "--add-label", "-l" }, "urgent")
  end)

  it("remove label runs one bd update --remove-label per marked bead", function()
    local ids = { "t-1", "t-3" }
    H.mark(ids)
    H.act({
      name = "remove label",
      menu = H.menu.remove_label,
      value = {
        input = "old",
        pick = function(t)
          return t:match("%f[%w]old%f[%W]") ~= nil
        end,
      },
    })
    wait_writes(function()
      return count_verb("update") >= 2
    end, "two updates")
    assert_per_bead(ids, { "--remove-label" }, "old")
  end)

  it("move under epic runs one bd update --parent <epic> per marked bead", function()
    local ids = { "t-1", "t-3", "t-4" }
    H.mark(ids)
    H.act({ name = "move under epic", menu = H.menu.epic, value = { input = "ep-2", pick = H.pick_id("ep-2") } })
    wait_writes(function()
      return count_verb("update") >= 3
    end, "three updates")
    assert_per_bead(ids, { "--parent" }, "ep-2")
  end)

  it("move under epic offers only epics, excluding the selected beads", function()
    H.mark({ "ep-1", "t-3", "t-4" })
    local st = H.act({ name = "move under epic", menu = H.menu.epic, value = nil })
    assert.are.equal(1, #st.value_lists, "the epic was not chosen from a vim.ui.select list")
    local offered = {}
    for _, t in ipairs(st.value_lists[1]) do
      for _, id in ipairs(ALL_IDS) do
        if H.has_id(t, id) then
          offered[#offered + 1] = id
        end
      end
    end
    assert.are.same({ "ep-2" }, offered, "epic picker items:\n  " .. table.concat(st.value_lists[1], "\n  "))
  end)

  it("remove parent runs one bd update --parent \"\" per marked bead", function()
    local ids = { "t-1", "t-2" }
    H.mark(ids)
    H.act({
      name = "remove parent (or move under epic)",
      menu = H.menu.remove_parent,
      value = { input = "", pick = H.pick_remove_parent },
    })
    wait_writes(function()
      return count_verb("update") >= 2
    end, "two updates")
    assert_per_bead(ids, { "--parent" }, "")
  end)

  -- ── dependencies ─────────────────────────────────────────────────────────────────────────────
  it("blocked by X adds X as a blocks dependency to every selected bead in one bd batch", function()
    H.mark({ "t-2", "t-3" })
    local st = H.act({ name = "blocked by", menu = H.menu.blocked_by, value = { input = "t-4", pick = H.pick_id("t-4") } })
    wait_writes(function()
      return count_verb("batch") >= 1
    end, "the dependency batch")
    assert.are.equal(1, st.value_prompts)
    assert.are.equal(1, count_verb("batch"), log_dump())
    assert.are.equal(0, count_verb("dep"), "dependency added outside the batch:\n" .. log_dump())
    assert.are.same({ "t-2>t-4", "t-3>t-4" }, batch_deps("add"), log_dump())
  end)

  it("blocked by one of the selected beads is refused with a message and runs nothing", function()
    H.mark({ "t-1", "t-3", "t-4" })
    local before = #H.notes
    H.act({ name = "blocked by", menu = H.menu.blocked_by, value = { input = "t-4", pick = H.pick_id("t-4") } })
    H.sleep(500)
    assert.are.same({}, write_calls(), "a refused blocked-by wrote")
    assert.is_true(#H.notes > before, "no message for the refused blocked-by")
  end)

  it("remove dependency on X removes it from every selected bead in one bd batch", function()
    H.mark({ "t-1", "t-3" })
    H.act({ name = "remove dependency", menu = H.menu.remove_dep, value = { input = "t-4", pick = H.pick_id("t-4") } })
    wait_writes(function()
      return count_verb("batch") >= 1
    end, "the dependency batch")
    assert.are.equal(1, count_verb("batch"), log_dump())
    assert.are.equal(0, count_verb("dep"), log_dump())
    assert.are.same({ "t-1>t-4", "t-3>t-4" }, batch_deps("remove"), log_dump())
  end)

  -- ── cancelling ───────────────────────────────────────────────────────────────────────────────
  local ACTIONS = {
    { "priority", H.menu.priority, { input = "1", pick = function(t) return t:find("1", 1, true) ~= nil end } },
    { "status", H.menu.status, { input = "in_progress", pick = function(t) return t:find("in", 1, true) ~= nil end } },
    { "assignee", H.menu.assignee, { input = "alice", pick = function(t) return t:find("alice", 1, true) ~= nil end } },
    { "type", H.menu.type, { input = "bug", pick = function(t) return t:find("bug", 1, true) ~= nil end } },
    { "add label", H.menu.add_label, { input = "urgent", pick = function(t) return t:find("urgent", 1, true) ~= nil end } },
    { "remove label", H.menu.remove_label, { input = "old", pick = function(t) return t:find("old", 1, true) ~= nil end } },
    { "move under epic", H.menu.epic, { input = "ep-2", pick = H.pick_id("ep-2") } },
    { "blocked by", H.menu.blocked_by, { input = "t-2", pick = H.pick_id("t-2") } },
    { "remove dependency", H.menu.remove_dep, { input = "t-4", pick = H.pick_id("t-4") } },
  }

  for _, a in ipairs(ACTIONS) do
    it("cancelling the " .. a[1] .. " value prompt runs nothing", function()
      H.mark({ "t-1", "t-3" })
      H.act({ name = a[1], menu = a[2], value = nil })
      H.sleep(500)
      assert.are.same({}, write_calls(), a[1] .. " ran after a cancelled prompt")
    end)

    it("answering no to the " .. a[1] .. " confirmation runs nothing", function()
      H.mark({ "t-1", "t-3" })
      local st = H.act({ name = a[1], menu = a[2], value = a[3], confirm = "n" })
      H.sleep(500)
      assert.are.equal(1, #st.confirms, a[1] .. " on 2 beads asked no [y/N] confirmation")
      assert.are.same({}, write_calls(), a[1] .. " ran after the confirmation was declined")
    end)
  end

  it("cancelling the A menu runs nothing", function()
    -- passes already: guards that a dismissed menu stays a no-op
    H.mark({ "t-1", "t-3" })
    H.reset_state({ name = "none", menu = {} })
    vim.api.nvim_set_current_win(H.tree_win)
    H.press("A")
    H.sleep(500)
    assert.are.same({}, write_calls())
  end)
end)
