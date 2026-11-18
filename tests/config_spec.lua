-- Interface under test (bead beads_nvim-ge7.1):
--   require("beads").setup(opts?) deep-merges opts over the defaults.
--   The effective config is exposed as require("beads").config.
--   Defaults: config.tree.width == nil (computed at open, beads_nvim-4u9.5), config.keymaps is a non-empty table.
--   (beads_nvim-4gx.8: setup({ keys }) renamed to setup({ keymaps }), no alias.)

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
    assert.is_nil(beads.config.tree.width)
    assert.are.equal("table", type(beads.config.keymaps))
    assert.is_true(next(beads.config.keymaps) ~= nil, "default keymaps table is empty")
  end)

  it("accepts an empty table", function()
    local beads = fresh_beads()
    assert.has_no.errors(function()
      beads.setup({})
    end)
    assert.is_nil(beads.config.tree.width)
  end)

  it("deep-merges user options over defaults", function()
    local beads = fresh_beads()
    beads.setup()
    local default_keys = vim.deepcopy(beads.config.keymaps)

    beads = fresh_beads()
    beads.setup({ keymaps = { tree = "<leader>zz" }, tree = { width = 60 } })

    assert.are.equal(60, beads.config.tree.width)
    assert.are.equal("<leader>zz", beads.config.keymaps.tree)
    for name, value in pairs(default_keys) do
      if name ~= "tree" then
        assert.are.same(value, beads.config.keymaps[name], "default key lost: " .. tostring(name))
      end
    end
  end)
end)
