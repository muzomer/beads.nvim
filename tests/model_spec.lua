-- Interface under test (bead beads_nvim-ge7.3): lua/beads/model.lua
--   local model = require("beads.model")
--   model.normalize(item) -> Bead
--       item = ONE decoded bead from either `bd show --json` (deps: {id, dependency_type,...})
--              or `bd list --json` (deps: {issue_id, depends_on_id, type,...}); the shape is
--              detected from the dependency entries.
--   model.normalize_all(items) -> list of Bead (same order as items)
--   Bead = {
--     id, title, status, priority, type (= issue_type), assignee, labels, parent,
--     description, design, acceptance (= acceptance_criteria), notes, comments,
--     metadata, updated_at,
--     blocked_by = list of ids of 'blocks' deps only,
--     children   = list of ids (from parent-child dependents when present, else {}),
--   }
--   List fields (labels, comments, blocked_by, children) and metadata are always tables;
--   missing scalars are nil. JSON null (vim.NIL) is treated as missing.
--
-- Fixtures tests/fixtures/model_*.json are real bd 1.2.2 output:
--   model_show_child.json : bd show fx-cfa.1 --json --include-comments
--   model_show_epic.json  : bd show fx-cfa --json --include-dependents
--   model_list.json       : bd list --all -n 0 --json
-- (owner / created_by / author values were replaced with neutral placeholders.)

local helpers = require("tests.helpers")
local model = require("beads.model")

local function find(items, id)
  for _, it in ipairs(items) do
    if it.id == id then
      return it
    end
  end
  error("no bead " .. id .. " in fixture")
end

local function contains(list, v)
  for _, x in ipairs(list) do
    if x == v then
      return true
    end
  end
  return false
end

local function show_child()
  return helpers.load_fixture("model_show_child")[1]
end

local function list_items()
  return helpers.load_fixture("model_list")
end

describe("beads.model fixtures", function()
  it("show fixture uses the show dependency shape", function()
    local raw = show_child()
    assert.equals("fx-cfa.1", raw.id)
    assert.is_not_nil(raw.dependencies[1].dependency_type)
    assert.is_not_nil(raw.dependencies[1].id)
    assert.is_nil(raw.dependencies[1].depends_on_id)
  end)

  it("list fixture uses the list dependency shape and has closed + epic beads", function()
    local items = list_items()
    local raw = find(items, "fx-cfa.1")
    assert.is_not_nil(raw.dependencies[1].depends_on_id)
    assert.is_not_nil(raw.dependencies[1].type)
    assert.equals("closed", find(items, "fx-17x").status)
    assert.equals("epic", find(items, "fx-cfa").issue_type)
  end)
end)

describe("beads.model.normalize", function()
  it("maps the show output to the Bead fields", function()
    local b = model.normalize(show_child())
    assert.equals("fx-cfa.1", b.id)
    assert.equals("Child task", b.title)
    assert.equals("open", b.status)
    assert.equals(0, b.priority)
    assert.equals("feature", b.type)
    assert.equals("bob", b.assignee)
    assert.same({ "alpha", "beta" }, b.labels)
    assert.equals("fx-cfa", b.parent)
    assert.equals("desc text", b.description)
    assert.equals("design text", b.design)
    assert.equals("ac text", b.acceptance)
    assert.equals("some notes", b.notes)
    assert.equals("2026-11-17T16:01:13Z", b.updated_at)
    assert.equals(1, #b.comments)
    assert.equals("first comment", b.comments[1].text)
  end)

  it("maps the list output to the Bead fields", function()
    local b = model.normalize(find(list_items(), "fx-cfa.1"))
    assert.equals("feature", b.type)
    assert.equals("ac text", b.acceptance)
    assert.same({ "alpha", "beta" }, b.labels)
    assert.same({}, b.comments)
  end)

  it("show and list of the same bead yield equal parent and blocked_by", function()
    local s = model.normalize(show_child())
    local l = model.normalize(find(list_items(), "fx-cfa.1"))
    assert.equals("fx-cfa", s.parent)
    assert.equals(s.parent, l.parent)
    assert.same({ "fx-80s" }, s.blocked_by)
    assert.same(s.blocked_by, l.blocked_by)
  end)

  it("parent-child deps never appear in blocked_by; blocks deps always do (show shape)", function()
    local b = model.normalize(show_child())
    assert.is_false(contains(b.blocked_by, "fx-cfa"))
    assert.is_true(contains(b.blocked_by, "fx-80s"))
  end)

  it("parent-child deps never appear in blocked_by; blocks deps always do (list shape)", function()
    local b = model.normalize(find(list_items(), "fx-cfa.1"))
    assert.is_false(contains(b.blocked_by, "fx-cfa"))
    assert.is_true(contains(b.blocked_by, "fx-80s"))
  end)

  it("derives parent from the parent-child dep when the top-level parent is absent", function()
    local s = vim.deepcopy(show_child())
    s.parent = nil
    local l = vim.deepcopy(find(list_items(), "fx-cfa.1"))
    l.parent = nil
    assert.equals("fx-cfa", model.normalize(s).parent)
    assert.equals("fx-cfa", model.normalize(l).parent)
  end)

  it("handles several blocks deps in both shapes", function()
    local s = {
      id = "a",
      dependencies = {
        { id = "p", dependency_type = "parent-child" },
        { id = "b1", dependency_type = "blocks" },
        { id = "r", dependency_type = "related" },
        { id = "b2", dependency_type = "blocks" },
      },
    }
    local l = {
      id = "a",
      dependencies = {
        { issue_id = "a", depends_on_id = "p", type = "parent-child" },
        { issue_id = "a", depends_on_id = "b1", type = "blocks" },
        { issue_id = "a", depends_on_id = "r", type = "related" },
        { issue_id = "a", depends_on_id = "b2", type = "blocks" },
      },
    }
    assert.same({ "b1", "b2" }, model.normalize(s).blocked_by)
    assert.same({ "b1", "b2" }, model.normalize(l).blocked_by)
  end)

  it("missing optional fields become nil or empty tables (closed bead and epic from list)", function()
    for _, id in ipairs({ "fx-17x", "fx-cfa", "fx-80s" }) do
      local b = model.normalize(find(list_items(), id))
      assert.equals(id, b.id)
      assert.same({}, b.labels)
      assert.same({}, b.blocked_by)
      assert.same({}, b.comments)
      assert.same({}, b.metadata)
      assert.is_nil(b.parent)
      assert.is_nil(b.assignee)
      assert.is_nil(b.design)
      assert.is_nil(b.acceptance)
      assert.is_nil(b.notes)
    end
    assert.equals("closed", model.normalize(find(list_items(), "fx-17x")).status)
    assert.equals("epic", model.normalize(find(list_items(), "fx-cfa")).type)
  end)

  it("a bare bead with only an id does not error", function()
    local b = model.normalize({ id = "x" })
    assert.equals("x", b.id)
    assert.same({}, b.labels)
    assert.same({}, b.blocked_by)
    assert.same({}, b.comments)
    assert.same({}, b.metadata)
    assert.same({}, b.children)
    assert.is_nil(b.parent)
    assert.is_nil(b.title)
    assert.is_nil(b.type)
  end)

  it("JSON nulls are treated as missing", function()
    local raw = vim.json.decode(
      '{"id":"y","labels":null,"dependencies":null,"metadata":null,"comments":null,'
        .. '"assignee":null,"design":null,"parent":null}'
    )
    local b = model.normalize(raw)
    assert.equals("y", b.id)
    assert.same({}, b.labels)
    assert.same({}, b.blocked_by)
    assert.same({}, b.comments)
    assert.same({}, b.metadata)
    assert.is_nil(b.assignee)
    assert.is_nil(b.design)
    assert.is_nil(b.parent)
  end)

  it("metadata numbers and strings are preserved", function()
    for _, raw in ipairs({ show_child(), find(list_items(), "fx-cfa.1") }) do
      local b = model.normalize(raw)
      assert.equals("number", type(b.metadata.review_round))
      assert.equals(2, b.metadata.review_round)
      assert.equals("string", type(b.metadata.owner_note))
      assert.equals("hello", b.metadata.owner_note)
    end
  end)

  it("derives children from parent-child dependents of a show --include-dependents", function()
    local b = model.normalize(helpers.load_fixture("model_show_epic")[1])
    assert.equals("fx-cfa", b.id)
    assert.equals("epic", b.type)
    assert.same({ "fx-cfa.1" }, b.children)
  end)
end)

describe("beads.model.normalize_all", function()
  it("normalizes every item in order", function()
    local items = list_items()
    local out = model.normalize_all(items)
    assert.equals(#items, #out)
    for i, it in ipairs(items) do
      assert.equals(it.id, out[i].id)
    end
    assert.equals("feature", out[1].type)
    assert.same({ "fx-80s" }, out[1].blocked_by)
  end)
end)
