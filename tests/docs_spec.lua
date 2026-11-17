-- Bead beads_nvim-ge7.1: CLAUDE.md has a "## Quality gates" section with a
-- table row naming the gate command `make test`.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

describe("CLAUDE.md", function()
  it("has a Quality gates table with 'make test'", function()
    local lines = vim.fn.readfile(root .. "/CLAUDE.md")
    local in_section, found_heading, found_row = false, false, false
    for _, line in ipairs(lines) do
      if line:match("^##%s+Quality gates%s*$") then
        in_section, found_heading = true, true
      elseif line:match("^##%s") then
        in_section = false
      elseif in_section and line:match("^%s*|") and line:find("make test", 1, true) then
        found_row = true
      end
    end
    assert.is_true(found_heading, "missing '## Quality gates' heading")
    assert.is_true(found_row, "missing table row with 'make test' under Quality gates")
  end)
end)
