-- Interface under test (bead beads_nvim-ge7.1):
--   plugin/beads.lua defines the :Beads user command and nothing else is
--   required at load time: no lua/beads/* module may be in package.loaded
--   until :Beads (or its completion) is used.
-- Kept in its own spec file so nothing else lazy-loads beads modules first.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function loaded_beads_modules()
  local found = {}
  for name in pairs(package.loaded) do
    if name == "beads" or name:match("^beads%.") then
      table.insert(found, name)
    end
  end
  return found
end

describe("plugin/beads.lua", function()
  it("defines :Beads without loading any beads module", function()
    vim.g.loaded_beads = nil
    for _, name in ipairs(loaded_beads_modules()) do
      package.loaded[name] = nil
    end
    pcall(vim.api.nvim_del_user_command, "Beads")

    vim.cmd.source(root .. "/plugin/beads.lua")

    assert.are.equal(2, vim.fn.exists(":Beads"))
    assert.are.same({}, loaded_beads_modules())
  end)
end)
