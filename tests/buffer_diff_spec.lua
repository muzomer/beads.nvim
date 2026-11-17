-- Interface under test (bead beads_nvim-ge7.7): lua/beads/buffer/diff.lua
--   local diff = require("beads.buffer.diff")
--
--   diff.compute(bead, lines) -> result
--       bead  = loaded snapshot, a normalized Bead (require("beads.model").normalize)
--       lines = current buffer lines (layout of beads.buffer.render)
--       result = {
--         update   = nil | { args = { "update", <id>, <flag>, <value>, ... },
--                            files = { ["--body-file"] = <description>, ["--design-file"] = <design> } },
--                    only changed fields; nil when no editable field changed.
--                    Flags: --title, --status, --priority, --type, --assignee, --set-labels (or
--                    --remove-label/--add-label for labels), --parent, --acceptance;
--                    description/design only via files (never inline in args).
--         deps     = list of bd batch lines for blocked_by changes:
--                    "dep add <id> <other> blocks" / "dep remove <id> <other>"; {} when none.
--         warnings = list of strings, one per edited read-only region (id, Workflow, Notes,
--                    Comments), each naming the region; those edits are discarded. {} when none.
--       }
--   diff.create(lines) -> { args = { "create", ... }, files = { ["--body-file"]=..., ... } }
--       lines = buffer from render.template, edited. Includes -t, -p, --parent, -l and
--       --deps blocks:<id> only when the field is set.
--   Args never contain --json or -C (beads.cli adds those); every value is a string.

local helpers = require("tests.helpers")
local model = require("beads.model")
local render = require("beads.buffer.render")
local diff = require("beads.buffer.diff")

local function fixture_beads()
  local out = {}
  out[#out + 1] = model.normalize(helpers.load_fixture("model_show_child")[1])
  out[#out + 1] = model.normalize(helpers.load_fixture("model_show_epic")[1])
  for _, b in ipairs(model.normalize_all(helpers.load_fixture("model_list"))) do
    out[#out + 1] = b
  end
  return out
end

local function child()
  return model.normalize(helpers.load_fixture("model_show_child")[1])
end

local function bead(raw)
  raw.id = raw.id or "x-1"
  raw.title = raw.title or "A title"
  raw.status = raw.status or "open"
  raw.priority = raw.priority or 2
  raw.issue_type = raw.issue_type or "task"
  return model.normalize(raw)
end

local function index_of(lines, pred)
  for i, l in ipairs(lines) do
    if pred(l) then
      return i
    end
  end
  return nil
end

-- Replace the first line starting with `prefix` by `new`.
local function replace(lines, prefix, new)
  local out = vim.deepcopy(lines)
  local i = index_of(out, function(l)
    return vim.startswith(l, prefix)
  end)
  assert(i, "no line starting with " .. prefix)
  out[i] = new
  return out
end

local function insert_after(lines, exact, new)
  local out = vim.deepcopy(lines)
  local i = index_of(out, function(l)
    return l == exact
  end)
  assert(i, "no line " .. exact)
  table.insert(out, i + 1, new)
  return out
end

local function empty(t)
  return t == nil or next(t) == nil
end

-- Flags of an arg list after the leading positional words ("update", id).
local function flags_after(args, n)
  local out = {}
  for i = n + 1, #args do
    out[#out + 1] = args[i]
  end
  return out
end

local function any_warning(warnings, word)
  for _, w in ipairs(warnings or {}) do
    assert.equals("string", type(w))
    if w:lower():find(word, 1, true) then
      return true
    end
  end
  return false
end

local function has_arg(args, flag)
  for _, a in ipairs(args) do
    if a == flag then
      return true
    end
  end
  return false
end

-- All values following any of the given flags, split on commas.
local function flag_values(args, names)
  local set = {}
  for _, n in ipairs(names) do
    set[n] = true
  end
  local out = {}
  for i, a in ipairs(args) do
    local eq_flag, eq_val = a:match("^(%-%-?[%w-]+)=(.*)$")
    if eq_flag and set[eq_flag] then
      for v in eq_val:gmatch("[^,]+") do
        out[#out + 1] = vim.trim(v)
      end
    elseif set[a] and args[i + 1] then
      for v in args[i + 1]:gmatch("[^,]+") do
        out[#out + 1] = vim.trim(v)
      end
    end
  end
  table.sort(out)
  return out
end

local function has_any(args, names)
  for _, n in ipairs(names) do
    for _, a in ipairs(args) do
      if a == n or vim.startswith(a, n .. "=") then
        return true
      end
    end
  end
  return false
end

describe("beads.buffer.diff compute", function()
  it("unchanged buffer -> no update, no dep ops, no warnings (every fixture bead)", function()
    local beads = fixture_beads()
    assert.is_true(#beads >= 6)
    for _, b in ipairs(beads) do
      local r = diff.compute(b, (render.render(b)))
      assert.is_nil(r.update, "unexpected update for " .. tostring(b.id))
      assert.same({}, r.deps)
      assert.same({}, r.warnings)
    end
  end)

  it("changing only priority -> update args contain only --priority", function()
    local b = child()
    local lines = replace(render.render(b), "priority:", "priority: 1")
    local r = diff.compute(b, lines)
    assert.is_not_nil(r.update)
    assert.same({ "update", "fx-cfa.1", "--priority", "1" }, r.update.args)
    assert.is_true(empty(r.update.files))
    assert.same({}, r.deps)
    assert.same({}, r.warnings)
  end)

  it("changing title and status -> one update with exactly those flags", function()
    local b = child()
    local lines = replace(render.render(b), "status:", "status: in_progress")
    lines = replace(lines, "# Child task", "# New title")
    local r = diff.compute(b, lines)
    assert.equals("update", r.update.args[1])
    assert.equals("fx-cfa.1", r.update.args[2])
    local f = flags_after(r.update.args, 2)
    assert.equals(4, #f)
    local m = {}
    for i = 1, #f, 2 do
      m[f[i]] = f[i + 1]
    end
    assert.same({ ["--title"] = "New title", ["--status"] = "in_progress" }, m)
  end)

  it("adding and removing a blocked_by id -> one dep add and one dep remove, no update", function()
    local b = bead({ id = "x-1", dependencies = { { id = "x-2", dependency_type = "blocks" } } })
    local lines = replace(render.render(b), "blocked_by:", "blocked_by: [x-3]")
    local r = diff.compute(b, lines)
    assert.is_nil(r.update)
    assert.equals(2, #r.deps)
    assert.is_true(vim.tbl_contains(r.deps, "dep add x-1 x-3 blocks"), vim.inspect(r.deps))
    assert.is_true(vim.tbl_contains(r.deps, "dep remove x-1 x-2"), vim.inspect(r.deps))
    assert.same({}, r.warnings)
  end)

  it("removing all labels -> an update that only touches labels", function()
    local b = child()
    assert.same({ "alpha", "beta" }, b.labels)
    local lines = replace(render.render(b), "labels:", "labels: []")
    local r = diff.compute(b, lines)
    assert.is_not_nil(r.update)
    assert.equals("update", r.update.args[1])
    assert.equals("fx-cfa.1", r.update.args[2])
    local f = flags_after(r.update.args, 2)
    assert.is_true(#f >= 1)
    for _, a in ipairs(f) do
      local is_flag = a:match("^%-%-")
      if is_flag then
        local name = a:match("^(%-%-[%w-]+)")
        assert.is_true(
          name == "--set-labels" or name == "--remove-label" or name == "--add-label",
          "non-label flag in labels update: " .. vim.inspect(r.update.args)
        )
      end
    end
    assert.is_true(empty(r.update.files))
    assert.same({}, r.deps)
  end)

  it("changing description and design -> passed via files, not inline args", function()
    local b = child()
    local lines = replace(render.render(b), "desc text", "new desc")
    lines = replace(lines, "design text", "new design")
    local r = diff.compute(b, lines)
    assert.same({ "update", "fx-cfa.1" }, r.update.args)
    assert.same({ ["--body-file"] = "new desc", ["--design-file"] = "new design" }, r.update.files)
  end)

  it("changing acceptance -> --acceptance with the new text", function()
    local b = child()
    local lines = replace(render.render(b), "ac text", "new ac")
    local r = diff.compute(b, lines)
    assert.same({ "update", "fx-cfa.1", "--acceptance", "new ac" }, r.update.args)
    assert.is_true(empty(r.update.files))
  end)

  it("editing Notes in place -> warning naming notes, no update", function()
    local b = child()
    local lines = replace(render.render(b), "some notes", "edited notes")
    local r = diff.compute(b, lines)
    assert.is_nil(r.update)
    assert.same({}, r.deps)
    assert.is_true(any_warning(r.warnings, "notes"), vim.inspect(r.warnings))
  end)

  it("inserting a line in Notes -> warning naming notes, no update", function()
    local b = child()
    local lines = insert_after(render.render(b), "## Notes", "a new note line")
    local r = diff.compute(b, lines)
    assert.is_nil(r.update)
    assert.is_true(any_warning(r.warnings, "notes"), vim.inspect(r.warnings))
    assert.is_false(any_warning(r.warnings, "comments"), vim.inspect(r.warnings))
  end)

  it("editing Comments -> warning naming comments, no update", function()
    local b = child()
    local lines = replace(render.render(b), "first comment", "rewritten comment")
    local r = diff.compute(b, lines)
    assert.is_nil(r.update)
    assert.is_true(any_warning(r.warnings, "comments"), vim.inspect(r.warnings))
    assert.is_false(any_warning(r.warnings, "notes"), vim.inspect(r.warnings))
  end)

  it("editing Workflow -> warning naming workflow, no update", function()
    local b = child()
    local lines = insert_after(render.render(b), "## Workflow", "verdict: CLEAN")
    local r = diff.compute(b, lines)
    assert.is_nil(r.update)
    assert.is_true(any_warning(r.warnings, "workflow"), vim.inspect(r.warnings))
  end)

  it("Notes edit plus a priority change -> warning and only --priority", function()
    local b = child()
    local lines = replace(render.render(b), "some notes", "edited notes")
    lines = replace(lines, "priority:", "priority: 3")
    local r = diff.compute(b, lines)
    assert.same({ "update", "fx-cfa.1", "--priority", "3" }, r.update.args)
    assert.is_true(any_warning(r.warnings, "notes"))
  end)

  it("changing id in frontmatter -> warning, ignored (update targets the original id)", function()
    local b = child()
    local lines = replace(render.render(b), "id:", "id: fx-other")
    local r = diff.compute(b, lines)
    assert.is_nil(r.update)
    assert.is_true(any_warning(r.warnings, "id"), vim.inspect(r.warnings))

    lines = replace(lines, "priority:", "priority: 1")
    r = diff.compute(b, lines)
    assert.same({ "update", "fx-cfa.1", "--priority", "1" }, r.update.args)
    assert.is_true(any_warning(r.warnings, "id"), vim.inspect(r.warnings))
  end)
end)

describe("beads.buffer.diff create", function()
  local T = { "-t", "--type" }
  local P = { "-p", "--priority" }
  local L = { "-l", "--labels" }

  it("includes -t, -p, --parent, -l and --deps blocks:<id> when set", function()
    local lines = render.template({ parent = "x-7" })
    lines = replace(lines, "type:", "type: bug")
    lines = replace(lines, "priority:", "priority: 1")
    lines = replace(lines, "labels:", "labels: [a, b]")
    lines = replace(lines, "blocked_by:", "blocked_by: [x-2, x-3]")
    lines = replace(lines, "# ", "# My new bead")
    local c = diff.create(lines)
    assert.equals("create", c.args[1])
    assert.same({ "bug" }, flag_values(c.args, T))
    assert.same({ "1" }, flag_values(c.args, P))
    assert.same({ "x-7" }, flag_values(c.args, { "--parent" }))
    assert.same({ "a", "b" }, flag_values(c.args, L))
    assert.same({ "blocks:x-2", "blocks:x-3" }, flag_values(c.args, { "--deps" }))
    assert.is_true(has_arg(c.args, "My new bead") or vim.tbl_contains(flag_values(c.args, { "--title" }), "My new bead"))
    assert.is_false(has_arg(c.args, "--json"))
  end)

  it("omits --parent, -l and --deps when not set", function()
    local lines = render.template({})
    lines = replace(lines, "# ", "# Plain bead")
    local c = diff.create(lines)
    assert.equals("create", c.args[1])
    assert.is_false(has_any(c.args, { "--parent" }), vim.inspect(c.args))
    assert.is_false(has_any(c.args, L), vim.inspect(c.args))
    assert.is_false(has_any(c.args, { "--deps" }), vim.inspect(c.args))
    assert.is_false(has_arg(c.args, "--json"))
  end)

  it("passes description and design via files, acceptance via --acceptance", function()
    local lines = render.template({})
    lines = replace(lines, "# ", "# Text bead")
    lines = insert_after(lines, "## Description", "the desc")
    lines = insert_after(lines, "## Design", "the design")
    lines = insert_after(lines, "## Acceptance", "the ac")
    local c = diff.create(lines)
    assert.equals("the desc", c.files["--body-file"])
    assert.equals("the design", c.files["--design-file"])
    assert.same({ "the ac" }, { c.args[vim.fn.index(c.args, "--acceptance") + 2] })
  end)
end)
