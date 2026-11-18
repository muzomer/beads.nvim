-- Bead beads_nvim-4u9.1: status glyphs and optional type icons.
-- Interface under test:
--   require("beads.glyphs").status(status) -> string
--     defaults like bd's CLI: open ○, in_progress ◐, blocked ●, closed ✓, deferred ❄
--   setup({ glyphs = { <status> = "..." } }) overrides single glyphs (others stay default)
--   setup({ glyphs = "ascii" }) uses plain ASCII glyphs (documented in README)
--   require("beads.glyphs").type(issue_type) -> "" or nil while type icons are off (default)

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local STATUSES = { "open", "in_progress", "blocked", "closed", "deferred" }

local function fresh_beads()
  for name in pairs(package.loaded) do
    if name == "beads" or name:match("^beads%.") then
      package.loaded[name] = nil
    end
  end
  return require("beads")
end

describe("glyphs", function()
  it("defaults to bd's status glyphs", function()
    fresh_beads().setup()
    local g = require("beads.glyphs")
    assert.are.equal("○", g.status("open"))
    assert.are.equal("◐", g.status("in_progress"))
    assert.are.equal("●", g.status("blocked"))
    assert.are.equal("✓", g.status("closed"))
    assert.are.equal("❄", g.status("deferred"))
  end)

  it("glyphs config overrides single status glyphs and keeps the rest", function()
    fresh_beads().setup({ glyphs = { open = "O", closed = "C" } })
    local g = require("beads.glyphs")
    assert.are.equal("O", g.status("open"))
    assert.are.equal("C", g.status("closed"))
    assert.are.equal("◐", g.status("in_progress"))
    assert.are.equal("●", g.status("blocked"))
    assert.are.equal("❄", g.status("deferred"))
  end)

  it("glyphs = 'ascii' uses distinct plain ASCII status glyphs", function()
    fresh_beads().setup({ glyphs = "ascii" })
    local g = require("beads.glyphs")
    local seen = {}
    for _, s in ipairs(STATUSES) do
      local glyph = g.status(s)
      assert.are.equal("string", type(glyph), s)
      assert.is_true(#glyph > 0, s .. " glyph is empty")
      assert.is_nil(glyph:find("[\128-\255]"), s .. " glyph is not ASCII: " .. glyph)
      assert.is_nil(seen[glyph], s .. " glyph duplicates " .. tostring(seen[glyph]))
      seen[glyph] = s
    end
  end)

  it("type icons are off by default", function()
    fresh_beads().setup()
    local g = require("beads.glyphs")
    for _, t in ipairs({ "epic", "bug", "feature", "task", "chore" }) do
      local icon = g.type(t)
      assert.is_true(icon == nil or icon == "", t .. " has an icon by default: " .. tostring(icon))
    end
  end)

  it("README documents the glyphs option and its 'ascii' fallback", function()
    local text = table.concat(vim.fn.readfile(root .. "/README.md"), "\n")
    assert.is_truthy(text:find("glyphs", 1, true), "README does not mention glyphs")
    assert.is_truthy(text:find("ascii", 1, true), "README does not mention the ascii glyphs fallback")
  end)
end)
