-- Interface under test (bead beads_nvim-ge7.6): lua/beads/buffer/render.lua, lua/beads/buffer/parse.lua
--   local render = require("beads.buffer.render")
--   local parse  = require("beads.buffer.parse")
--
--   render.render(bead) -> lines, regions
--       bead  = normalized Bead (require("beads.model").normalize)
--       lines = list of strings in the agreed layout:
--                 ---
--                 id: <id>
--                 status: / priority: / type: / assignee: / labels: [a, b] / parent: / blocked_by: [x, y]
--                 ---
--                 # <title>
--                 ## Description
--                 ## Design
--                 ## Acceptance
--                 ## Workflow   (workflow.fields(bead))
--                 ## Notes
--                 ## Comments   (author, time, body of each comment)
--       regions = list of read-only regions, each { name = <string>, first = <int>, last = <int> }
--                 names exactly "id", "workflow", "notes", "comments";
--                 first/last are 1-based, inclusive line numbers into `lines`;
--                 "id" covers exactly the `id: <id>` line;
--                 a section region spans its "## <Section>" heading through the line before the
--                 next "## " heading, or through the last line of the buffer.
--   render.template(opts) -> lines, regions
--       Template for a new bead: no id, type task, priority 2, opts.parent prefilled when given.
--
--   parse.parse(lines) -> fields
--       fields = { title, status, priority (number), type, assignee, labels (list), parent,
--                  blocked_by (list), description, design, acceptance, ... }
--       description/design/acceptance are always strings ("" when empty);
--       labels/blocked_by are always lists ({} when empty), in the rendered order;
--       assignee/parent are nil when empty. Extra keys (e.g. id) are allowed.
--   '## ' lines inside fenced code blocks (```) are content, not section headings.

local helpers = require("tests.helpers")
local model = require("beads.model")
local workflow = require("beads.workflow")
local render = require("beads.buffer.render")
local parse = require("beads.buffer.parse")

local function editable(bead)
  local function text(v)
    if v == nil then
      return ""
    end
    return v
  end
  return {
    title = bead.title,
    status = bead.status,
    priority = bead.priority,
    type = bead.type,
    assignee = bead.assignee,
    labels = bead.labels or {},
    parent = bead.parent,
    blocked_by = bead.blocked_by or {},
    description = text(bead.description),
    design = text(bead.design),
    acceptance = text(bead.acceptance),
  }
end

local KEYS = {
  "title",
  "status",
  "priority",
  "type",
  "assignee",
  "labels",
  "parent",
  "blocked_by",
  "description",
  "design",
  "acceptance",
}

local function project(fields)
  local out = {}
  for _, k in ipairs(KEYS) do
    out[k] = fields[k]
  end
  return out
end

local function assert_roundtrip(bead)
  local lines = render.render(bead)
  assert.is_table(lines)
  local parsed = parse.parse(lines)
  assert.same(editable(bead), project(parsed))
end

local function fixture_beads()
  local out = {}
  out[#out + 1] = model.normalize(helpers.load_fixture("model_show_child")[1])
  out[#out + 1] = model.normalize(helpers.load_fixture("model_show_epic")[1])
  for _, b in ipairs(model.normalize_all(helpers.load_fixture("model_list"))) do
    out[#out + 1] = b
  end
  return out
end

local function bead(raw)
  raw.id = raw.id or "x-1"
  raw.title = raw.title or "A title"
  raw.status = raw.status or "open"
  raw.priority = raw.priority or 2
  raw.issue_type = raw.issue_type or "task"
  return model.normalize(raw)
end

local function index_of(lines, line)
  for i, l in ipairs(lines) do
    if l == line then
      return i
    end
  end
  return nil
end

local function region(regions, name)
  for _, r in ipairs(regions) do
    if r.name == name then
      return r
    end
  end
  return nil
end

local function region_text(lines, r)
  local out = {}
  for i = r.first, r.last do
    out[#out + 1] = lines[i]
  end
  return table.concat(out, "\n")
end

local function has(text, needle)
  return text:find(needle, 1, true) ~= nil
end

describe("beads.buffer round-trip", function()
  it("parse(render(bead)) equals the editable fields for every fixture bead", function()
    local beads = fixture_beads()
    assert.is_true(#beads >= 6)
    for _, b in ipairs(beads) do
      assert_roundtrip(b)
    end
  end)

  it("keeps priority 0 as the number 0", function()
    local b = model.normalize(helpers.load_fixture("model_show_child")[1])
    assert.equals(0, b.priority)
    local parsed = parse.parse((render.render(b)))
    assert.equals(0, parsed.priority)
    assert.equals("number", type(parsed.priority))
  end)

  it("keeps lists in order and empty lists as {}", function()
    local b = bead({
      labels = { "zeta", "alpha", "needs-review" },
      dependencies = {
        { id = "x-9", dependency_type = "blocks" },
        { id = "x-2", dependency_type = "blocks" },
        { id = "x-5", dependency_type = "blocks" },
      },
    })
    local parsed = parse.parse((render.render(b)))
    assert.same({ "zeta", "alpha", "needs-review" }, parsed.labels)
    assert.same({ "x-9", "x-2", "x-5" }, parsed.blocked_by)

    local empty = parse.parse((render.render(bead({ id = "x-3" }))))
    assert.same({}, empty.labels)
    assert.same({}, empty.blocked_by)
    assert.is_nil(empty.parent)
    assert.is_nil(empty.assignee)
  end)

  it("round-trips multi-line text with blank lines, lists and subheadings", function()
    assert_roundtrip(bead({
      description = "First paragraph\nsecond line\n\n- item one\n- item two\n\n### Sub heading\nmore text",
      design = "line a\n\n\nline b after two blanks",
      acceptance_criteria = "- crit one\n- crit two",
      assignee = "alice",
      labels = { "a" },
      parent = "x-0",
      notes = "note line 1\nnote line 2",
    }))
  end)

  it("keeps '## ' lines inside a fenced code block in Description", function()
    local desc = table.concat({
      "Intro text",
      "```markdown",
      "## Design",
      "## Notes",
      "## Comments",
      "---",
      "# not a title",
      "id: fake",
      "```",
    }, "\n")
    local b = bead({ description = desc, design = "real design", acceptance_criteria = "real ac" })
    local parsed = parse.parse((render.render(b)))
    assert.equals(desc, parsed.description)
    assert.equals("real design", parsed.design)
    assert.equals("real ac", parsed.acceptance)
    assert.equals("A title", parsed.title)
    assert_roundtrip(b)
  end)

  it("round-trips nil Description/Design/Acceptance as empty strings", function()
    local b = bead({})
    assert.is_nil(b.description)
    local parsed = parse.parse((render.render(b)))
    assert.equals("", parsed.description)
    assert.equals("", parsed.design)
    assert.equals("", parsed.acceptance)
    assert_roundtrip(b)
  end)

  it("round-trips explicit '' Description/Design/Acceptance as empty strings", function()
    local b = bead({ description = "", design = "", acceptance_criteria = "" })
    local parsed = parse.parse((render.render(b)))
    assert.equals("", parsed.description)
    assert.equals("", parsed.design)
    assert.equals("", parsed.acceptance)
    assert_roundtrip(b)
  end)

  it("does not let an empty section swallow the next one", function()
    local b = bead({ description = "", design = "only design", acceptance_criteria = "" })
    local parsed = parse.parse((render.render(b)))
    assert.equals("", parsed.description)
    assert.equals("only design", parsed.design)
    assert.equals("", parsed.acceptance)
  end)
end)

describe("beads.buffer read-only regions", function()
  local function check_regions(b)
    local lines, regions = render.render(b)
    assert.is_table(regions)

    local names = {}
    for _, r in ipairs(regions) do
      names[#names + 1] = r.name
    end
    table.sort(names)
    assert.same({ "comments", "id", "notes", "workflow" }, names)

    local id_line = index_of(lines, "id: " .. b.id)
    local wf = index_of(lines, "## Workflow")
    local notes = index_of(lines, "## Notes")
    local comments = index_of(lines, "## Comments")
    assert.is_not_nil(id_line)
    assert.is_not_nil(wf)
    assert.is_not_nil(notes)
    assert.is_not_nil(comments)
    assert.is_true(wf < notes and notes < comments)

    assert.same({ name = "id", first = id_line, last = id_line }, region(regions, "id"))
    assert.same({ name = "workflow", first = wf, last = notes - 1 }, region(regions, "workflow"))
    assert.same({ name = "notes", first = notes, last = comments - 1 }, region(regions, "notes"))
    assert.same({ name = "comments", first = comments, last = #lines }, region(regions, "comments"))

    -- Nothing editable is inside a region.
    local editable_lines = {
      index_of(lines, "# " .. b.title),
      index_of(lines, "## Description"),
      index_of(lines, "## Design"),
      index_of(lines, "## Acceptance"),
    }
    for i, l in ipairs(lines) do
      if l:match("^status:") or l:match("^priority:") or l:match("^type:") or l:match("^labels:")
        or l:match("^parent:") or l:match("^blocked_by:") or l:match("^assignee:") then
        editable_lines[#editable_lines + 1] = i
      end
    end
    assert.is_true(#editable_lines >= 11)
    for _, i in ipairs(editable_lines) do
      for _, r in ipairs(regions) do
        assert.is_false(i >= r.first and i <= r.last, "line " .. i .. " is inside region " .. r.name)
      end
    end
  end

  it("covers id, Workflow, Notes, Comments exactly for a bead with notes and comments", function()
    check_regions(model.normalize(helpers.load_fixture("model_show_child")[1]))
  end)

  it("covers id, Workflow, Notes, Comments exactly for an epic with empty notes and comments", function()
    check_regions(model.normalize(helpers.load_fixture("model_show_epic")[1]))
  end)
end)

describe("beads.buffer Workflow and Comments sections", function()
  it("Workflow lists every workflow.fields entry of a task", function()
    local b = bead({
      metadata = {
        verdict = "ISSUES",
        review_round = 2,
        findings = "blocker x",
        gate = "pass",
        tdd = "t1: failed",
        bookmark = "bead-x-1",
        change = "abc123",
        rounds = 3,
        parked = "waiting",
      },
    })
    local lines, regions = render.render(b)
    local text = region_text(lines, region(regions, "workflow"))
    local fields = workflow.fields(b)
    assert.equals(9, #fields)
    for _, f in ipairs(fields) do
      assert.is_true(has(text, f.name), "missing " .. f.name)
      assert.is_true(has(text, tostring(f.value)), "missing value of " .. f.name)
    end
  end)

  it("Workflow lists full_suite fields for an epic", function()
    local b = bead({
      issue_type = "epic",
      metadata = { verdict = "CLEAN", full_suite = "fail", full_suite_culprit = "x-1.4" },
    })
    local lines, regions = render.render(b)
    local text = region_text(lines, region(regions, "workflow"))
    for _, f in ipairs(workflow.fields(b)) do
      assert.is_true(has(text, f.name), "missing " .. f.name)
      assert.is_true(has(text, tostring(f.value)), "missing value of " .. f.name)
    end
    assert.is_true(has(text, "full_suite_culprit"))
    assert.is_true(has(text, "x-1.4"))
  end)

  it("Comments show author, time and body of each comment", function()
    local b = bead({
      comments = {
        { author = "Test User", text = "first comment", created_at = "2026-11-17T16:01:13Z" },
        { author = "Other Person", text = "line one\nline two", created_at = "2026-11-18T09:45:00Z" },
      },
    })
    local lines, regions = render.render(b)
    local text = region_text(lines, region(regions, "comments"))
    assert.is_true(has(text, "Test User"))
    assert.is_true(has(text, "first comment"))
    assert.is_true(has(text, "2026-11-17"))
    assert.is_true(has(text, "16:01"))
    assert.is_true(has(text, "Other Person"))
    assert.is_true(has(text, "line one"))
    assert.is_true(has(text, "line two"))
    assert.is_true(has(text, "2026-11-18"))
    assert.is_true(has(text, "09:45"))
  end)

  it("Comments from the show fixture appear in the Comments region", function()
    local b = model.normalize(helpers.load_fixture("model_show_child")[1])
    local lines, regions = render.render(b)
    local text = region_text(lines, region(regions, "comments"))
    assert.is_true(has(text, "Test User"))
    assert.is_true(has(text, "first comment"))
    assert.is_true(has(text, "2026-11-17"))
  end)
end)

describe("beads.buffer template", function()
  it("new bead with parent parses back to type task, priority 2, that parent", function()
    local lines = render.template({ parent = "x-7" })
    local parsed = parse.parse(lines)
    assert.equals("task", parsed.type)
    assert.equals(2, parsed.priority)
    assert.equals("x-7", parsed.parent)
    assert.is_nil(parsed.id)
    assert.same({}, parsed.labels)
    assert.same({}, parsed.blocked_by)
    assert.equals("", parsed.description)
  end)

  it("new bead without parent parses back with parent nil", function()
    local parsed = parse.parse((render.template({})))
    assert.equals("task", parsed.type)
    assert.equals(2, parsed.priority)
    assert.is_nil(parsed.parent)
    assert.is_nil(parsed.id)
  end)
end)
