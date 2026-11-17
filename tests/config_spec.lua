-- Interface under test (bead beads_nvim-ge7.1):
--   require("beads").setup(opts?) deep-merges opts over the defaults.
--   The effective config is exposed as require("beads").config.
--   Defaults: config.tree.width == 50, config.keys is a non-empty table.

local function fresh_beads()
  for name in pairs(package.loaded) do
    if name == "beads" or name:match("^beads%.") then
      package.loaded[name] = nil
    end
  end
  return require("beads")
end

describe("beads.setup", function()
  it("works with no arguments and applies defaults", function()
    local beads = fresh_beads()
    assert.has_no.errors(function()
      beads.setup()
    end)
    assert.are.equal(50, beads.config.tree.width)
    assert.are.equal("table", type(beads.config.keys))
    assert.is_true(next(beads.config.keys) ~= nil, "default keys table is empty")
  end)

  it("accepts an empty table", function()
    local beads = fresh_beads()
    assert.has_no.errors(function()
      beads.setup({})
    end)
    assert.are.equal(50, beads.config.tree.width)
  end)

  it("deep-merges user options over defaults", function()
    local beads = fresh_beads()
    beads.setup()
    local default_keys = vim.deepcopy(beads.config.keys)

    beads = fresh_beads()
    beads.setup({ keys = { my_custom_action = "<leader>zz" }, tree = { width = 60 } })

    assert.are.equal(60, beads.config.tree.width)
    assert.are.equal("<leader>zz", beads.config.keys.my_custom_action)
    for name, value in pairs(default_keys) do
      assert.are.same(value, beads.config.keys[name], "default key lost: " .. tostring(name))
    end
  end)
end)
