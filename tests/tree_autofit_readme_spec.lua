-- Bead beads_nvim-4u9.13: README documents the tree auto-fit options: tree.width / tree.height
-- accept "auto" (the default), and tree.max_width / tree.max_height cap the auto size.
-- assumption: documented means the README text names "auto", max_width and max_height.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

describe("README tree auto-fit", function()
  local text = table.concat(vim.fn.readfile(root .. "/README.md"), "\n")

  it('documents "auto" for tree width/height', function()
    assert.is_truthy(text:find('"auto"', 1, true), 'README does not mention "auto"')
  end)

  it("documents max_width and max_height", function()
    assert.is_truthy(text:find("max_width", 1, true), "README does not mention max_width")
    assert.is_truthy(text:find("max_height", 1, true), "README does not mention max_height")
  end)
end)
