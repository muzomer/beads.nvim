-- Bead beads_nvim-69z: setup({ type_icons = { <type> = <icon> } }) shows the type icon in tree and
-- picker lines (shared formatter lua/beads/ui/format.lua, glyphs.type); default (type_icons =
-- false) shows none.
-- Fixture and fake bd for the tree: tests/peek_fake.lua (pk-a1x epic, the rest tasks).
-- assumption: the icon sits between the status glyph and the id, separated by single spaces:
--   "<status> <icon> <id> P<n> <title> ...".
-- assumption: a type missing from the type_icons table gets no icon and no extra space.

local fake = require("tests.peek_fake")
local F = require("beads.ui.format")

local ICONS = { epic = "[E]", task = "[T]" }

local function bead(id, title, typ, extra)
  local b = { id = id, title = title, status = "open", priority = 2, type = typ, labels = {}, metadata = {} }
  for k, v in pairs(extra or {}) do
    b[k] = v
  end
  return b
end

local function row_with(win, needle)
  for _, l in ipairs(fake.lines_of(win)) do
    if l:find(needle, 1, true) then
      return l
    end
  end
  error(("no tree row contains %q:\n%s"):format(needle, fake.text_of(win)), 0)
end

describe("type icons in the shared line format", function()
  after_each(function()
    require("beads").setup({})
  end)

  it("golden: enabled icons appear between the status glyph and the id", function()
    require("beads").setup({ type_icons = ICONS })
    local text = F.format(bead("ab-1", "Alpha", "task"))
    assert.are.equal("○ [T] ab-1 P2 Alpha", text)
    local etext = F.format(bead("ab-2", "Big one", "epic", { priority = 1 }))
    assert.are.equal("○ [E] ab-2 P1 Big one", etext)
  end)

  it("the id range still covers exactly the id when an icon is shown", function()
    require("beads").setup({ type_icons = ICONS })
    local text, ranges = F.format(bead("ab-1", "Alpha", "task"))
    local found
    for _, r in ipairs(ranges) do
      if r.group == "BeadsId" then
        found = text:sub(r.col + 1, r.end_col)
      end
    end
    assert.are.equal("ab-1", found)
  end)

  it("passes already: default (disabled) shows no icon", function()
    require("beads").setup({})
    assert.are.equal("○ ab-1 P2 Alpha", (F.format(bead("ab-1", "Alpha", "task"))))
  end)

  it("passes already: a type without an icon in the table gets no icon and no extra space", function()
    require("beads").setup({ type_icons = ICONS })
    assert.are.equal("○ ab-3 P2 Bug here", (F.format(bead("ab-3", "Bug here", "bug"))))
  end)

  it("picker lines show the type icon", function()
    require("beads").setup({ type_icons = ICONS })
    local picker = require("beads.views.picker")
    assert.are.equal("○ [T] ab-1 P2 Alpha", picker.format(bead("ab-1", "Alpha", "task")))
  end)

  it("passes already: picker lines show no icon by default", function()
    require("beads").setup({})
    local picker = require("beads.views.picker")
    assert.are.equal("○ ab-1 P2 Alpha", picker.format(bead("ab-1", "Alpha", "task")))
  end)
end)

describe("type icons in the tree", function()
  after_each(function()
    fake.teardown()
  end)

  it("tree rows show the type icon when enabled", function()
    fake.setup({ type_icons = ICONS })
    local tree = fake.open_tree()
    assert.is_truthy(row_with(tree, "pk-d4w"):find("○ [T] pk-d4w P2 Delta notes", 1, true), row_with(tree, "pk-d4w"))
    assert.is_truthy(row_with(tree, "pk-a1x "):find("○ [E] pk-a1x P1 Alpha epic", 1, true), row_with(tree, "pk-a1x "))
  end)

  it("passes already: tree rows show no icon by default", function()
    fake.setup({})
    local tree = fake.open_tree()
    assert.is_truthy(row_with(tree, "pk-d4w"):find("○ pk-d4w P2 Delta notes", 1, true), row_with(tree, "pk-d4w"))
    assert.is_nil(fake.text_of(tree):find("[T]", 1, true))
  end)
end)
