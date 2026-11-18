-- Bead beads_nvim-4gx.4: '## Questions' section in the detail buffer (render / parse / diff).
-- Interface under test:
--   * Question threads travel on the bead snapshot as bead.threads: a list of threads as returned
--     by beads.questions.store.list and beads.questions.human.list
--     ({ id, bead, status, needs, messages = { { author, body, proposal? }, ... }, human? }).
--   * render.render(bead) appends a read-only '## Questions' section after '## Comments' when
--     bead.threads is non-empty: one line per thread showing a needs-who marker and the first line
--     of the message text. regions gains { name = "questions", first = <heading>, last = #lines }
--     and the comments region ends just before the Questions heading.
--     With no threads nothing changes (the four-region layout pinned by
--     tests/buffer_render_parse_spec.lua stays).
--   * parse.parse ignores the section; diff.compute(bead, render(bead)) is empty.
--   * Editing a Questions line yields a warning naming Questions, no update, no Comments warning.

local model = require("beads.model")
local render = require("beads.buffer.render")
local parse = require("beads.buffer.parse")
local diff = require("beads.buffer.diff")

local function bead()
  local b = model.normalize({
    id = "fx-1",
    title = "Questions test",
    description = "desc text",
    design = "design text",
    acceptance_criteria = "ac text",
    notes = "some notes",
    status = "open",
    priority = 2,
    issue_type = "task",
    labels = { "a" },
    comments = { { author = "me", text = "a comment", created_at = "2026-11-17T16:01:12Z" } },
    created_at = "2026-11-17T16:01:12Z",
    updated_at = "2026-11-17T16:01:12Z",
  })
  b.threads = {
    {
      id = "t1",
      bead = "fx-1",
      status = "open",
      needs = "user",
      messages = { { id = "m1", author = "agent", body = "Which database should we use?\nsecond line" } },
    },
    {
      id = "human:fx-1",
      bead = "fx-1",
      status = "open",
      needs = "user",
      readonly = true,
      human = true,
      messages = { { author = "agent", body = "Should the agent continue?" } },
    },
  }
  return b
end

local function index_of(lines, l)
  for i, x in ipairs(lines) do
    if x == l then
      return i
    end
  end
end

local function region(regions, name)
  for _, r in ipairs(regions) do
    if r.name == name then
      return r
    end
  end
end

local function line_with(lines, from, text)
  for i = from, #lines do
    if lines[i]:find(text, 1, true) then
      return i
    end
  end
end

local function any_warning(warnings, word)
  for _, w in ipairs(warnings or {}) do
    if tostring(w):lower():find(word, 1, true) then
      return true
    end
  end
  return false
end

describe("beads detail Questions section", function()
  it("renders '## Questions' after '## Comments' with one line per thread, human threads included", function()
    local lines = render.render(bead())
    local comments = index_of(lines, "## Comments")
    local q = index_of(lines, "## Questions")
    assert.is_not_nil(q, "no '## Questions' heading:\n" .. table.concat(lines, "\n"))
    assert.is_true(q > comments, "Questions is not after Comments")
    local l1 = line_with(lines, q + 1, "Which database should we use?")
    local l2 = line_with(lines, q + 1, "Should the agent continue?")
    assert.is_not_nil(l1, "stored thread preview missing")
    assert.is_not_nil(l2, "human thread preview missing")
    assert.are_not.equal(l1, l2, "threads must be on separate lines")
    assert.is_nil(line_with(lines, q + 1, "second line"), "preview must be the first line only")
  end)

  it("marks the Questions section as a read-only region after the comments region", function()
    local lines, regions = render.render(bead())
    local q = index_of(lines, "## Questions")
    assert.is_not_nil(q)
    assert.same({ name = "questions", first = q, last = #lines }, region(regions, "questions"))
    local c = region(regions, "comments")
    assert.equals(index_of(lines, "## Comments"), c.first)
    assert.equals(q - 1, c.last)
  end)

  it("parse(render(bead)) is unaffected by the section and diff.compute is empty", function()
    local b = bead()
    local lines = render.render(b)
    assert.is_not_nil(index_of(lines, "## Questions"), "no '## Questions' heading to round-trip")
    local f = parse.parse(lines)
    assert.equals("Questions test", f.title)
    assert.equals("desc text", f.description)
    assert.equals("design text", f.design)
    assert.equals("ac text", f.acceptance)
    local r = diff.compute(b, lines)
    assert.is_nil(r.update, vim.inspect(r.update))
    assert.same({}, r.deps)
    assert.same({}, r.warnings)
  end)

  it("an edit inside Questions is discarded with a warning naming Questions (not Comments)", function()
    local b = bead()
    local lines = render.render(b)
    local q = index_of(lines, "## Questions")
    assert.is_not_nil(q)
    local i = line_with(lines, q + 1, "Which database should we use?")
    lines[i] = lines[i] .. " EDITED"
    local r = diff.compute(b, lines)
    assert.is_nil(r.update, vim.inspect(r.update))
    assert.is_true(any_warning(r.warnings, "question"), vim.inspect(r.warnings))
    assert.is_false(any_warning(r.warnings, "comments"), vim.inspect(r.warnings))
  end)
end)
