-- Regression test for review finding on bead beads_nvim-ge7.6 (parse.lua:59):
-- an unclosed ``` fence in Acceptance must not pair with a fence in Notes
-- (fences opened in Acceptance may only close before ## Workflow).
local model = require("beads.model")
local render = require("beads.buffer.render")
local parse = require("beads.buffer.parse")

describe("beads.buffer.parse fence scope in Acceptance", function()
  it("an unclosed fence in Acceptance is not closed by a fenced block in Notes", function()
    local b = model.normalize({
      id = "x-1",
      title = "A title",
      status = "open",
      priority = 2,
      issue_type = "task",
      description = "the description",
      design = "the design",
      acceptance_criteria = "x\n```\ny",
      notes = "```\nz\n```",
    })
    local lines = render.render(b)
    assert.is_true(vim.tbl_contains(lines, "## Workflow"))
    assert.is_true(vim.tbl_contains(lines, "## Notes"))
    assert.is_true(vim.tbl_contains(lines, "## Comments"))
    local parsed = parse.parse(lines)
    assert.equals("the description", parsed.description)
    assert.equals("the design", parsed.design)
    assert.equals("x\n```\ny", parsed.acceptance)
  end)
end)
