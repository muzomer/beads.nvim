-- Bead beads_nvim-alz: the shared line formatter (lua/beads/ui/format.lua) pads the status glyph
-- and the type icon to a fixed display width (the widest of the configured set, minimum 1), so the
-- id column starts at the same display column on every row whatever glyphs the user configures.
-- Nothing is truncated; the BeadsId range covers exactly the id; picker lines use the same format.
-- assumption: types absent from type_icons and beads whose status has no glyph keep their current
--   form (guarded by tests/type_icons_lines_spec.lua and tests/format_no_glyph_findings_spec.lua),
--   so they are left out of the alignment sets here.
-- assumption: the side the padding goes on (before or after the glyph) is not pinned; only the id
--   column and the exact id range are.
-- assumption: the README "## Highlights and glyphs" section mentions that glyph widths are padded
--   (case-insensitive "pad").

local F = require("beads.ui.format")

local WIDE = "🐛" -- 2 display cells (emoji, independent of 'ambiwidth')

local function bead(id, status, typ)
  return { id = id, title = "Title " .. id, status = status, priority = 2, type = typ, labels = {}, metadata = {} }
end

-- Byte range of BeadsId in text, and the display column where it starts.
local function id_info(text, ranges)
  for _, r in ipairs(ranges) do
    if r.group == "BeadsId" then
      return text:sub(r.col + 1, r.end_col), vim.fn.strdisplaywidth(text:sub(1, r.col))
    end
  end
  error("no BeadsId range in " .. vim.inspect(text), 0)
end

-- Format every bead; assert the id range is exact and the id column equal on all rows.
local function assert_aligned(beads, fmt)
  fmt = fmt or F.format
  local col0, first
  local lines = {}
  for _, b in ipairs(beads) do
    local text, ranges = fmt(b)
    lines[#lines + 1] = text
    local id, col = id_info(text, ranges)
    assert.are.equal(b.id, id, "BeadsId range of " .. vim.inspect(text))
    if col0 == nil then
      col0, first = col, text
    else
      assert.are.equal(
        col0,
        col,
        ("id column differs:\n%s\n%s"):format(first, text)
      )
    end
  end
  return lines
end

local STATUSES = { "open", "in_progress", "blocked", "closed", "deferred" }

describe("glyph width padding in the shared line format", function()
  after_each(function()
    require("beads").setup({})
  end)

  it("type icons of different widths: the id starts at the same display column on every row", function()
    require("beads").setup({ type_icons = { bug = WIDE, task = "T", epic = "E" } })
    local lines = assert_aligned({
      bead("ab-1", "open", "task"),
      bead("ab-2", "open", "bug"),
      bead("ab-3", "open", "epic"),
    })
    -- nothing truncated
    assert.is_truthy(lines[1]:find("T", 1, true), lines[1])
    assert.is_truthy(lines[2]:find(WIDE, 1, true), lines[2])
    assert.is_truthy(lines[3]:find("E", 1, true), lines[3])
  end)

  it("custom status glyphs of different widths: the id starts at the same display column on every row", function()
    require("beads").setup({ glyphs = { open = WIDE, closed = "x" } })
    local beads = {}
    for i, s in ipairs(STATUSES) do
      beads[#beads + 1] = bead("st-" .. i, s, "task")
    end
    local lines = assert_aligned(beads)
    assert.is_truthy(lines[1]:find(WIDE, 1, true), lines[1])
    assert.is_truthy(lines[4]:find("x", 1, true), lines[4])
  end)

  it("a wide status glyph and a wide type icon together still align and keep the id range exact", function()
    require("beads").setup({ glyphs = { blocked = WIDE }, type_icons = { bug = WIDE, task = "T" } })
    assert_aligned({
      bead("cd-1", "open", "task"),
      bead("cd-2", "blocked", "task"),
      bead("cd-3", "open", "bug"),
      bead("cd-4", "blocked", "bug"),
      bead("cd-5", "closed", "bug"),
    })
  end)

  it("picker lines use the same padded formatting", function()
    require("beads").setup({ glyphs = { open = WIDE }, type_icons = { bug = WIDE, task = "T" } })
    local picker = require("beads.views.picker")
    local beads = { bead("pk-1", "open", "task"), bead("pk-2", "closed", "bug"), bead("pk-3", "closed", "task") }
    for _, b in ipairs(beads) do
      assert.are.equal((F.format(b)), picker.format(b))
    end
    assert_aligned(beads, function(b)
      local text = picker.format(b)
      local _, ranges = F.format(b)
      return text, ranges
    end)
  end)

  it("passes already: picker id_of_line still finds the id on a padded status-glyph line", function()
    require("beads").setup({ glyphs = { open = WIDE } })
    local picker = require("beads.views.picker")
    assert.are.equal("ab-9", picker.id_of_line(picker.format(bead("ab-9", "closed", "task"))))
    assert.are.equal("ab-8", picker.id_of_line(picker.format(bead("ab-8", "open", "task"))))
  end)

  it("passes already: default glyphs and no type icons give unchanged output", function()
    require("beads").setup({})
    local want = {
      open = "○ ab-1 P2 Title ab-1",
      in_progress = "◐ ab-1 P2 Title ab-1",
      blocked = "● ab-1 P2 Title ab-1",
      closed = "✓ ab-1 P2 Title ab-1",
      deferred = "❄ ab-1 P2 Title ab-1",
    }
    for _, s in ipairs(STATUSES) do
      assert.are.equal(want[s], (F.format(bead("ab-1", s, "task"))))
    end
  end)

  it("passes already: equal-width type icons give unchanged output", function()
    require("beads").setup({ type_icons = { epic = "[E]", task = "[T]" } })
    assert.are.equal("○ [T] ab-1 P2 Title ab-1", (F.format(bead("ab-1", "open", "task"))))
  end)
end)

describe("README on glyph widths", function()
  it("the Highlights and glyphs section notes that glyph widths are padded automatically", function()
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
    local in_section, text = false, {}
    for _, line in ipairs(vim.fn.readfile(root .. "/README.md")) do
      if line:match("^##%s+Highlights and glyphs") then
        in_section = true
      elseif line:match("^##%s") then
        in_section = false
      elseif in_section then
        text[#text + 1] = line
      end
    end
    local body = table.concat(text, "\n"):lower()
    assert.is_truthy(body:find("pad", 1, true), "README Highlights and glyphs section does not mention padding")
  end)
end)
