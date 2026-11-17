-- Regression tests for review finding on bead beads_nvim-ge7.6:
-- fence pairing in lua/beads/buffer/parse.lua must not pair fences across sections.
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

describe("beads.buffer.parse fence scope per section", function()
  it("an unclosed fence in Description is not closed by fences in Notes", function()
    local b = bead({
      description = "a\n```lua\ncode",
      design = "the design",
      acceptance_criteria = "the acceptance",
      notes = "```\nx\n```",
    })
    local parsed = parse.parse((render.render(b)))
    assert.equals("a\n```lua\ncode", parsed.description)
    assert.equals("the design", parsed.design)
    assert.equals("the acceptance", parsed.acceptance)
  end)

  it("unclosed fences in Description and Design are not paired with each other", function()
    local b = bead({
      description = "a\n```lua\ncode",
      design = "b\n```\nmore",
      acceptance_criteria = "the acceptance",
    })
    local parsed = parse.parse((render.render(b)))
    assert.equals("a\n```lua\ncode", parsed.description)
    assert.equals("b\n```\nmore", parsed.design)
    assert.equals("the acceptance", parsed.acceptance)
  end)
end)
