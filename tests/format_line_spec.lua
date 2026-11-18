-- Bead beads_nvim-4u9.2: shared bead line formatter (unit tests on fixtures).
-- Interface under test (lua/beads/ui/format.lua):
--   local F = require("beads.ui.format")
--   local text, ranges = F.format(bead, opts)
--     bead: a normalized bead (beads.model.normalize)
--     text: "<status glyph> <id padded> <P#> <title> <badges>"
--     ranges: list of { group = "Beads...", col = <0-based byte>, end_col = <exclusive byte> }
--     opts.id_width: pad the id to this display width (padding is not part of the id range)
--   F.sort(list) -> list sorted in place: priority ascending (nil last), ties by id
-- assumption: range shape { group, col, end_col } in bytes (maps onto nvim_buf_set_extmark).
-- assumption: badges that need the user (👤 human, 💬 waiting, 👀 needs-review) use
--   BeadsBadgeUser; agent/workflow badges (✓/✗ verdict, ●/○ gate, ⏸ parked) use BeadsBadgeAgent.

local model = require("beads.model")
local workflow = require("beads.workflow")

local function fresh()
  for name in pairs(package.loaded) do
    if name == "beads" or name:match("^beads%.") then
      package.loaded[name] = nil
    end
  end
  require("beads").setup({})
  model = require("beads.model")
  workflow = require("beads.workflow")
  return require("beads.ui.format")
end

local function raw(id, title, extra)
  local b = {
    id = id,
    title = title,
    status = "open",
    priority = 2,
    issue_type = "task",
    updated_at = "2026-11-17T10:00:00Z",
  }
  for k, v in pairs(extra or {}) do
    b[k] = v
  end
  return b
end

local function bead(id, title, extra)
  return model.normalize(raw(id, title, extra))
end

local function slice(text, r)
  return text:sub(r.col + 1, r.end_col)
end

local function ranges_sorted(ranges)
  local c = vim.list_extend({}, ranges or {})
  table.sort(c, function(a, b)
    return a.col < b.col
  end)
  return c
end

local function dump(text, ranges)
  local out = { "text: " .. text }
  for _, r in ipairs(ranges_sorted(ranges)) do
    out[#out + 1] = ("  %s [%d,%d) %q"):format(tostring(r.group), r.col, r.end_col, slice(text, r))
  end
  return table.concat(out, "\n")
end

-- The range of `group` whose text is exactly `want` (nil if none).
local function range_for(text, ranges, group, want)
  for _, r in ipairs(ranges or {}) do
    if r.group == group and slice(text, r) == want then
      return r
    end
  end
end

local STATUS_GROUPS = {
  open = "BeadsStatusOpen",
  in_progress = "BeadsStatusInProgress",
  blocked = "BeadsStatusBlocked",
  closed = "BeadsStatusClosed",
  deferred = "BeadsStatusDeferred",
}

describe("beads.ui.format", function()
  local F
  before_each(function()
    F = fresh()
  end)

  it("lays out '<glyph> <id> <P#> <title> <badges>' in that order", function()
    local b = bead("op-a", "Open alpha", { priority = 1, labels = { "human" }, metadata = { verdict = "CLEAN" } })
    local text = F.format(b)
    assert.are.equal("string", type(text))
    local glyph = require("beads.glyphs").status("open")
    assert.are.equal(glyph .. " ", text:sub(1, #glyph + 1), "line must start with the status glyph: " .. text)
    local p_id = text:find("op-a", 1, true)
    local p_prio = text:find("P1", 1, true)
    local p_title = text:find("Open alpha", 1, true)
    local p_human = text:find("👤", 1, true)
    assert.is_not_nil(p_id, text)
    assert.is_not_nil(p_prio, text)
    assert.is_not_nil(p_title, text)
    assert.is_not_nil(p_human, text)
    assert.is_true(#glyph < p_id and p_id < p_prio and p_prio < p_title and p_title < p_human, "out of order: " .. text)
  end)

  it("ranges cover glyph, id, priority and title with the Beads* groups", function()
    local b = bead("op-a", "Open alpha", { priority = 1 })
    local text, ranges = F.format(b)
    assert.are.equal("table", type(ranges), "format must return highlight ranges")
    local d = dump(text, ranges)
    local glyph = require("beads.glyphs").status("open")
    local g = range_for(text, ranges, "BeadsStatusOpen", glyph)
    local id = range_for(text, ranges, "BeadsId", "op-a")
    local pr = range_for(text, ranges, "BeadsPriority1", "P1")
    local ti = range_for(text, ranges, "BeadsTitle", "Open alpha")
    assert.is_not_nil(g, "no BeadsStatusOpen range on the glyph\n" .. d)
    assert.are.equal(0, g.col, "glyph range must start the line\n" .. d)
    assert.is_not_nil(id, "no BeadsId range on the id\n" .. d)
    assert.is_not_nil(pr, "no BeadsPriority1 range on P1\n" .. d)
    assert.is_not_nil(ti, "no BeadsTitle range on the title\n" .. d)
    assert.is_true(g.end_col <= id.col and id.end_col <= pr.col and pr.end_col <= ti.col, "ranges out of order\n" .. d)
  end)

  it("the status glyph uses the status group for every status", function()
    for status, group in pairs(STATUS_GROUPS) do
      local text, ranges = F.format(bead("st-1", "Status " .. status, { status = status }))
      local glyph = require("beads.glyphs").status(status)
      local r = range_for(text, ranges, group, glyph)
      assert.is_not_nil(r, status .. ": no " .. group .. " range on " .. glyph .. "\n" .. dump(text, ranges))
      assert.are.equal(0, r.col, status .. ": glyph range must start the line\n" .. dump(text, ranges))
    end
  end)

  it("the priority uses BeadsPriority0..4", function()
    for p = 0, 4 do
      local text, ranges = F.format(bead("pr-1", "Prio", { priority = p }))
      local r = range_for(text, ranges, "BeadsPriority" .. p, "P" .. p)
      assert.is_not_nil(r, "P" .. p .. ": no BeadsPriority" .. p .. " range\n" .. dump(text, ranges))
    end
  end)

  it("each badge gets its own range with the user or agent badge group", function()
    local b = bead("bg-1", "Badged", {
      labels = { "human", "needs-review" },
      metadata = { verdict = "ISSUES", review_round = 2, gate = "pass", parked = "x" },
    })
    b.waiting_user = true
    local badges = workflow.badges(b)
    assert.is_true(#badges >= 6, "fixture must produce badges: " .. vim.inspect(badges))
    local text, ranges = F.format(b)
    local d = dump(text, ranges)
    local ti = range_for(text, ranges, "BeadsTitle", "Badged")
    assert.is_not_nil(ti, "no title range\n" .. d)
    -- badge glyphs may equal status glyphs (✓, ●, ○), so take only the ranges after the title
    local after = {}
    for _, r in ipairs(ranges_sorted(ranges)) do
      if r.col >= ti.end_col then
        after[#after + 1] = r
      end
    end
    local user = { [workflow.default_glyphs.human] = true, [workflow.default_glyphs.waiting] = true,
      [workflow.default_glyphs.needs_review] = true }
    assert.are.equal(#badges, #after, "want one range per badge " .. vim.inspect(badges) .. "\n" .. d)
    for i, badge in ipairs(badges) do
      local r = after[i]
      assert.are.equal(badge, slice(text, r), "badge " .. i .. " range\n" .. d)
      local want = user[badge] and "BeadsBadgeUser" or "BeadsBadgeAgent"
      assert.are.equal(want, r.group, "badge " .. badge .. " group\n" .. d)
    end
  end)

  it("ranges are byte ranges inside the text", function()
    local b = bead("op-a", "Ünïcode title ✓", { labels = { "human" } })
    local text, ranges = F.format(b)
    for _, r in ipairs(ranges) do
      assert.is_true(r.col >= 0 and r.end_col > r.col and r.end_col <= #text, "bad range\n" .. dump(text, ranges))
      assert.is_true(r.group:match("^Beads") ~= nil, "non-Beads group\n" .. dump(text, ranges))
    end
    assert.is_not_nil(range_for(text, ranges, "BeadsTitle", "Ünïcode title ✓"), dump(text, ranges))
  end)

  it("opts.id_width pads the id so the following columns line up", function()
    local short_text, short_ranges = F.format(bead("ab-1", "Short"), { id_width = 10 })
    local long_text, long_ranges = F.format(bead("abcdef-123", "Long"), { id_width = 10 })
    local ps = range_for(short_text, short_ranges, "BeadsPriority2", "P2")
    local pl = range_for(long_text, long_ranges, "BeadsPriority2", "P2")
    assert.is_not_nil(ps, dump(short_text, short_ranges))
    assert.is_not_nil(pl, dump(long_text, long_ranges))
    assert.are.equal(pl.col, ps.col, "P# not aligned:\n" .. short_text .. "\n" .. long_text)
    assert.is_not_nil(range_for(short_text, short_ranges, "BeadsId", "ab-1"), "id range must exclude padding\n"
      .. dump(short_text, short_ranges))
  end)

  it("sort orders by priority, then id, with no priority last", function()
    local list = {
      bead("zz-1", "z", { priority = 2 }),
      bead("aa-1", "a", { priority = 2 }),
      bead("np-1", "none", { priority = vim.NIL }),
      bead("hi-1", "high", { priority = 0 }),
      bead("mm-1", "mid", { priority = 1 }),
    }
    list[3].priority = nil
    local out = F.sort(list)
    local ids = {}
    for _, b in ipairs(out) do
      ids[#ids + 1] = b.id
    end
    assert.are.same({ "hi-1", "mm-1", "aa-1", "zz-1", "np-1" }, ids)
  end)
end)
