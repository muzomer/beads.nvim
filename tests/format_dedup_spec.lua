-- Bead beads_nvim-4u9.2: no sorting or line-formatting code stays duplicated between
-- lua/beads/views/tree.lua and lua/beads/views/picker.lua; both use lua/beads/ui/format.lua.
-- Static source check (like tests/highlights_usage_spec.lua).

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function source(rel)
  local path = root .. "/" .. rel
  assert.are.equal(1, vim.fn.filereadable(path), rel .. " missing")
  return table.concat(vim.fn.readfile(path), "\n")
end

local function code_only(src)
  -- drop comments so a remark about sorting does not count
  local out = {}
  for _, l in ipairs(vim.split(src, "\n", { plain = true })) do
    out[#out + 1] = (l:gsub("%-%-.*$", ""))
  end
  return table.concat(out, "\n")
end

local FILES = { "lua/beads/views/tree.lua", "lua/beads/views/picker.lua" }

describe("tree and picker share the formatter", function()
  it("the shared formatter module exists", function()
    assert.are.equal(1, vim.fn.filereadable(root .. "/lua/beads/ui/format.lua"), "lua/beads/ui/format.lua missing")
  end)

  for _, rel in ipairs(FILES) do
    it(rel .. " uses beads.ui.format", function()
      local src = code_only(source(rel))
      assert.is_truthy(src:find("beads.ui.format", 1, true), rel .. " does not require beads.ui.format")
    end)

    it(rel .. " has no own sort or line-formatting code", function()
      local src = code_only(source(rel))
      assert.is_nil(src:find("table.sort(", 1, true), rel .. " still sorts beads itself")
      assert.is_nil(src:find("workflow.badges(", 1, true), rel .. " still builds badges itself")
      assert.is_nil(src:find("[\"']P[\"']%s*%.%."), rel .. " still builds the P<n> column itself")
      assert.is_nil(src:find("priority or 99", 1, true), rel .. " still has its own priority ordering")
    end)
  end

  it("picker.lua no longer defines its own sort_beads", function()
    local src = code_only(source("lua/beads/views/picker.lua"))
    assert.is_nil(src:find("sort_beads", 1, true), "sort_beads still in picker.lua")
  end)

  it("tree.lua no longer defines its own sorted helper", function()
    local src = code_only(source("lua/beads/views/tree.lua"))
    assert.is_nil(src:find("function sorted", 1, true), "sorted() still in tree.lua")
  end)
end)
