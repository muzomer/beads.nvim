-- Bead beads_nvim-eco: dead code and duplicated helpers from the group actions epic are gone.
-- Structural checks on the source; behaviour is guarded by the existing specs.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function src(rel)
  return table.concat(vim.fn.readfile(root .. "/lua/beads/" .. rel), "\n")
end

local function count(s, needle)
  local n, i = 0, 1
  while true do
    local a, b = s:find(needle, i, true)
    if not a then
      return n
    end
    n, i = n + 1, b + 1
  end
end

describe("group actions cleanup", function()
  it("tree.lua has no in_root helper", function()
    assert.is_nil(src("views/tree.lua"):find("in_root", 1, true), "tree.lua still defines in_root")
  end)

  it("tree.lua has no unused workflow local", function()
    local s = src("views/tree.lua")
    if s:find('local workflow = require("beads.workflow")', 1, true) then
      -- Declared: it must be used somewhere other than its own require line.
      local uses = 0
      for _ in s:gmatch("[^%w_%.]workflow[%.:]") do
        uses = uses + 1
      end
      assert.is_true(uses > 0, "tree.lua declares local workflow but never uses it")
    end
  end)

  it("group_actions.lua has no quote_val of its own", function()
    assert.is_nil(src("group_actions.lua"):find("quote_val", 1, true), "group_actions.lua still defines quote_val")
  end)

  it("the quote escaping exists once across group.lua and group_actions.lua", function()
    local esc = [[:gsub('"', '\\"')]]
    local n = count(src("group.lua"), esc) + count(src("group_actions.lua"), esc)
    assert.equals(1, n, "quote escaping should live in one helper")
  end)

  it("the root swap exists once across group.lua and tree.lua", function()
    local swap = "cli.get_root_override()"
    local n = count(src("group.lua"), swap) + count(src("views/tree.lua"), swap)
    assert.equals(1, n, "root helper should exist once")
  end)

  it("the VERB comment does not call imperatives past participles", function()
    local s = src("group.lua")
    assert.is_truthy(s:find("local VERB", 1, true), "VERB table missing")
    assert.is_nil(s:lower():find("past participle", 1, true), "VERB comment says past participle")
  end)
end)
