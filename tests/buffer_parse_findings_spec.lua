-- Regression tests for review findings on bead beads_nvim-ge7.6 (lua/beads/buffer/parse.lua).
local model = require("beads.model")
local render = require("beads.buffer.render")
local parse = require("beads.buffer.parse")

local function bead(raw)
  raw.id = raw.id or "x-1"
  raw.title = raw.title or "A title"
  raw.status = raw.status or "open"
  raw.priority = raw.priority or 2
  raw.issue_type = raw.issue_type or "task"
  return model.normalize(raw)
end

describe("beads.buffer.parse review findings", function()
  it("keeps unfenced '## <other>' headings in Description/Design/Acceptance as content", function()
    local b = bead({
      description = "Intro\n## Context\nmore",
      design = "Plan\n## Approach\nsteps",
      acceptance_criteria = "## Checks\n- one",
      notes = "a note",
    })
    local parsed = parse.parse((render.render(b)))
    assert.equals("Intro\n## Context\nmore", parsed.description)
    assert.equals("Plan\n## Approach\nsteps", parsed.design)
    assert.equals("## Checks\n- one", parsed.acceptance)
  end)

  it("an unclosed ``` fence in Description does not swallow the following sections", function()
    local b = bead({
      description = "a\n```lua\ncode",
      design = "the design",
      acceptance_criteria = "the acceptance",
      notes = "NOTE-TEXT",
      comments = { { id = 1, author = "bob", text = "COMMENT-TEXT", created_at = "2026-01-02T03:04:05Z" } },
    })
    local parsed = parse.parse((render.render(b)))
    assert.equals("a\n```lua\ncode", parsed.description)
    assert.equals("the design", parsed.design)
    assert.equals("the acceptance", parsed.acceptance)
    assert.is_nil(parsed.description:find("NOTE-TEXT", 1, true))
    assert.is_nil(parsed.description:find("COMMENT-TEXT", 1, true))
  end)
end)
