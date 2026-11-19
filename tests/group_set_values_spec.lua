-- Bead beads_nvim-qvs.3: remove dependency targets only the selected beads that depend on X;
-- the move-under-epic picker offers only open epics that are neither selected nor descendants of
-- a selected bead. Interface under test: the tree's A menu on marked beads (see
-- tests/tree_group_fields_spec.lua for the prompt conventions; same fake bd on PATH).
--
-- assumption: "open epic" means an epic whose status is not closed (in_progress counts as open).
-- assumption: installed bd batch treats a single quote as a literal character; the single-quote
--   integration tests (group_set_values_integration_spec.lua) guard that it keeps working.
-- assumption: "nothing runs and a one-line message" is checked when none of the selected beads
--   has any blocking dependency (the picker only lists blockers of the selection).

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

local function child_of(id, parent, extra)
  extra = extra or {}
  extra.parent = parent
  local deps = extra.dependencies or {}
  table.insert(deps, 1, { issue_id = id, depends_on_id = parent, type = "parent-child" })
  extra.dependencies = deps
  return extra
end

-- ep-1 > { t-1, t-2 > ep-4, ep-3 }; ep-2 (open epic), ep-5 (closed epic), ep-6 (in_progress
-- epic); t-3, t-4. t-1 and t-3 are blocked by t-4; t-2 is blocked by nothing.
local function items()
  return {
    bead("ep-1", "Epic one", { issue_type = "epic", priority = 1 }),
    bead("t-1", "Task one", child_of("t-1", "ep-1", {
      dependencies = { { issue_id = "t-1", depends_on_id = "t-4", type = "blocks" } },
    })),
    bead("t-2", "Task two", child_of("t-2", "ep-1")),
    bead("ep-3", "Epic three (child of one)", child_of("ep-3", "ep-1", { issue_type = "epic" })),
    bead("ep-4", "Epic four (grandchild of one)", child_of("ep-4", "t-2", { issue_type = "epic" })),
    bead("ep-2", "Epic two", { issue_type = "epic", priority = 1 }),
    bead("ep-5", "Epic five closed", { issue_type = "epic", status = "closed", closed_at = "2026-11-17T11:00:00Z" }),
    bead("ep-6", "Epic six in progress", { issue_type = "epic", status = "in_progress" }),
    bead("t-3", "Task three", {
      dependencies = { { issue_id = "t-3", depends_on_id = "t-4", type = "blocks" } },
    }),
    bead("t-4", "Task four", { priority = 3 }),
  }
end

local ALL_IDS = { "ep-1", "t-1", "t-2", "ep-3", "ep-4", "ep-2", "ep-5", "ep-6", "t-3", "t-4" }

local function log()
  local p = dir .. "/calls.log"
  return vim.fn.filereadable(p) == 1 and vim.fn.readfile(p) or {}
end

local function log_dump()
  return table.concat(log(), "\n")
end

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

-- `dep remove <from> <to>` targets, from batch lines and from direct `bd dep remove` calls.
local function removed_deps()
  local out = {}
  for _, l in ipairs(batch_lines()) do
    local from, to = l:match("^dep%s+remove%s+(%S+)%s+(%S+)")
    if from then
      out[#out + 1] = from .. ">" .. to
    end
  end
  for _, a in ipairs(calls()) do
    local i = vim.fn.index(a, "dep")
    if i >= 0 and a[i + 2] == "remove" and a[i + 3] and a[i + 4] then
      out[#out + 1] = a[i + 3] .. ">" .. a[i + 4]
    end
  end
  table.sort(out)
  return out
end

describe("group set values: remove-dependency targets and epic picker choices", function()
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
    require("beads").setup({ tree = { layout = "split" }, fzf = false })
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

  it("remove dependency on X writes dep remove only for the selected beads that depend on X", function()
    H.mark({ "t-1", "t-2", "t-3" })
    H.act({ name = "remove dependency", menu = H.menu.remove_dep, value = { input = "t-4", pick = H.pick_id("t-4") } })
    H.wait_for(function()
      return count_verb("batch") + count_verb("dep") >= 1
    end, "the dependency removal; bd log:\n" .. log_dump())
    H.sleep(300)
    assert.are.same({ "t-1>t-4", "t-3>t-4" }, removed_deps(), "dep remove lines:\n" .. log_dump())
  end)

  it("remove dependency on X with one dependent among the selection removes only that one", function()
    H.mark({ "t-2", "t-3", "ep-2" })
    H.act({ name = "remove dependency", menu = H.menu.remove_dep, value = { input = "t-4", pick = H.pick_id("t-4") } })
    H.wait_for(function()
      return count_verb("batch") + count_verb("dep") >= 1
    end, "the dependency removal; bd log:\n" .. log_dump())
    H.sleep(300)
    assert.are.same({ "t-3>t-4" }, removed_deps(), "dep remove lines:\n" .. log_dump())
  end)

  it("remove dependency when no selected bead depends on anything runs nothing and says so in one line", function()
    -- passes already: guards the no-target case (nothing runs, a one-line message)
    H.mark({ "t-2", "ep-2" })
    local before = #H.notes
    H.act({ name = "remove dependency", menu = H.menu.remove_dep, value = { input = "t-4", pick = H.pick_id("t-4") } })
    H.sleep(500)
    assert.are.same({}, write_calls(), "remove dependency ran with no dependent selected:\n" .. log_dump())
    assert.are.equal(before + 1, #H.notes, "expected exactly one message")
    local msg = H.notes[#H.notes].msg
    assert.is_nil(msg:find("\n", 1, true), "message is not one line: " .. msg)
  end)

  local function offered(list)
    local out = {}
    for _, t in ipairs(list) do
      for _, id in ipairs(ALL_IDS) do
        if H.has_id(t, id) then
          out[#out + 1] = id
        end
      end
    end
    table.sort(out)
    return out
  end

  it("move under epic offers only open epics that are neither selected nor below a selected bead", function()
    H.mark({ "ep-1", "t-3" })
    local st = H.act({ name = "move under epic", menu = H.menu.epic, value = nil })
    assert.are.equal(1, #st.value_lists, "the epic was not chosen from a vim.ui.select list")
    assert.are.same({ "ep-2", "ep-6" }, offered(st.value_lists[1]),
      "epic picker items:\n  " .. table.concat(st.value_lists[1], "\n  "))
  end)

  it("move under epic does not offer a closed epic", function()
    H.mark({ "t-3", "t-4" })
    local st = H.act({ name = "move under epic", menu = H.menu.epic, value = nil })
    assert.are.equal(1, #st.value_lists, "the epic was not chosen from a vim.ui.select list")
    local got = offered(st.value_lists[1])
    assert.is_false(vim.tbl_contains(got, "ep-5"), "closed epic ep-5 offered:\n  " .. table.concat(st.value_lists[1], "\n  "))
    assert.are.same({ "ep-1", "ep-2", "ep-3", "ep-4", "ep-6" }, got)
  end)

  it("move under epic excludes an epic below a selected non-epic bead", function()
    H.mark({ "t-2", "t-3" })
    local st = H.act({ name = "move under epic", menu = H.menu.epic, value = nil })
    assert.are.equal(1, #st.value_lists, "the epic was not chosen from a vim.ui.select list")
    assert.are.same({ "ep-1", "ep-2", "ep-3", "ep-6" }, offered(st.value_lists[1]),
      "epic picker items:\n  " .. table.concat(st.value_lists[1], "\n  "))
  end)
end)
