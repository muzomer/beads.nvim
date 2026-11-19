-- Bead beads_nvim-69z (owner decision 2026-11-19): an open bead labelled human with no note has no
-- waiting thread, so its row shows 👤 and not 💬. The header counts it in the 👤 part of the split
-- "<total> need you (<n>💬 <m>👤)", not in the 💬 part.
-- Fixture: tests/peek_fake.lua plus (no bead shows both badges)
--   pk-q1  open, stored agent question (needs=user)  -> 💬 badge
--   pk-h3  open, labelled human, no notes             -> 👤 badge only
--   pk-h4  open, labelled human, no notes             -> 👤 badge only
--   pk-r1  labelled needs-review, no thread           -> 👀 badge only, not counted
-- Expected header part: "3 need you (1💬 2👤)".

local fake = require("tests.peek_fake")
local qstore = require("beads.questions.store")

local function header(tree)
  return fake.lines_of(tree)[1] or ""
end

local function rows_with(tree, glyph)
  local n = 0
  local lines = fake.lines_of(tree)
  for i = 2, #lines do
    if lines[i]:find(glyph, 1, true) then
      n = n + 1
    end
  end
  return n
end

local function item(id, title, extra)
  local b = {
    id = id,
    title = title,
    status = "open",
    priority = 2,
    issue_type = "task",
    description = "Body of " .. id,
    updated_at = "2026-11-17T10:00:00Z",
    created_at = "2026-11-17T10:00:00Z",
  }
  for k, v in pairs(extra or {}) do
    b[k] = v
  end
  return b
end

describe("tree header need-you split, human label without a note", function()
  before_each(function()
    fake.setup({})
    qstore.add(fake.root(), { bead = "pk-q1", messages = { { author = "agent", body = "Which option, a or b?" } } })
    local items = fake.items()
    items[#items + 1] = item("pk-q1", "Agent asks")
    items[#items + 1] = item("pk-h3", "Human no note", { labels = { "human" } })
    items[#items + 1] = item("pk-h4", "Human no note two", { labels = { "human" } })
    items[#items + 1] = item("pk-r1", "Review me", { labels = { "needs-review" } })
    fake.set_list(items)
    fake.prefill()
  end)

  after_each(function()
    fake.teardown()
  end)

  it("counts human-labelled beads without a note in the 👤 part", function()
    local tree = fake.open_tree()
    assert(vim.wait(5000, function()
      local t = fake.text_of(tree)
      return header(tree):find("need you", 1, true) ~= nil
        and t:find("pk-q1", 1, true) ~= nil
        and t:find("pk-h3", 1, true) ~= nil
        and t:find("pk-h4", 1, true) ~= nil
        and t:find("pk-r1", 1, true) ~= nil
    end, 10), "tree header never rendered:\n" .. fake.text_of(tree))
    for _, l in ipairs(fake.lines_of(tree)) do
      if l:find("pk-h3", 1, true) or l:find("pk-h4", 1, true) then
        assert.is_nil(l:find("💬", 1, true), "setup: human row without a note shows 💬: " .. l)
        assert.is_truthy(l:find("👤", 1, true), "setup: human row lacks 👤: " .. l)
      end
    end
    local chat, person = rows_with(tree, "💬"), rows_with(tree, "👤")
    assert.are.equal(1, chat, "setup: expected 1 row with 💬:\n" .. fake.text_of(tree))
    assert.are.equal(2, person, "setup: expected 2 rows with 👤:\n" .. fake.text_of(tree))
    assert.is_truthy(
      header(tree):find(" · 3 need you (1💬 2👤)", 1, true),
      "header lacks ' · 3 need you (1💬 2👤)': " .. header(tree)
    )
  end)
end)
