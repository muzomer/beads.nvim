-- Bead beads_nvim-69z (owner decision 2026-11-19): the tree header's need-you part shows the total
-- and the split, e.g. "3 need you (2💬 1👤)". The 💬 number equals the rows with a 💬 badge, the 👤
-- number the rows with a 👤 badge, and the total is their sum.
-- Fixture: tests/peek_fake.lua plus (the two kinds are kept disjoint: no bead shows both badges)
--   pk-q1  open, stored agent question (needs=user)  -> 💬 badge
--   pk-q2  open, stored agent question (needs=user)  -> 💬 badge
--   pk-h3  open, labelled human, no notes             -> 👤 badge only
--   pk-r1  labelled needs-review, no thread           -> 👀 badge only, not counted
--   pk-h2  labelled human with a note, closed         -> hidden, not counted
-- Expected header part: "3 need you (2💬 1👤)".

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

describe("tree header need-you split", function()
  before_each(function()
    fake.setup({})
    local root = fake.root()
    qstore.add(root, { bead = "pk-q1", messages = { { author = "agent", body = "Which option, a or b?" } } })
    qstore.add(root, { bead = "pk-q2", messages = { { author = "agent", body = "Rename or keep?" } } })
    local items = fake.items()
    items[#items + 1] = item("pk-q1", "Agent asks one")
    items[#items + 1] = item("pk-q2", "Agent asks two")
    items[#items + 1] = item("pk-h3", "Human no note", { labels = { "human" } })
    items[#items + 1] = item("pk-r1", "Review me", { labels = { "needs-review" } })
    items[#items + 1] = item("pk-h2", "Closed human", { status = "closed", labels = { "human" }, notes = "Old question?" })
    fake.set_list(items)
    fake.prefill()
  end)

  after_each(function()
    fake.teardown()
  end)

  it("shows the total and the 💬/👤 split matching the badges", function()
    local tree = fake.open_tree()
    assert(vim.wait(5000, function()
      local t = fake.text_of(tree)
      return header(tree):find("need you", 1, true) ~= nil
        and t:find("pk-q1", 1, true) ~= nil
        and t:find("pk-q2", 1, true) ~= nil
        and t:find("pk-h3", 1, true) ~= nil
        and t:find("pk-r1", 1, true) ~= nil
    end, 10), "tree header never rendered:\n" .. fake.text_of(tree))
    local chat, person = rows_with(tree, "💬"), rows_with(tree, "👤")
    assert.are.equal(2, chat, "setup: expected 2 rows with 💬:\n" .. fake.text_of(tree))
    assert.are.equal(1, person, "setup: expected 1 row with 👤:\n" .. fake.text_of(tree))
    assert.is_truthy(
      header(tree):find(" · 3 need you (2💬 1👤)", 1, true),
      "header lacks ' · 3 need you (2💬 1👤)': " .. header(tree)
    )
    local total, c, p = header(tree):match("(%d+) need you %((%d+)💬 (%d+)👤%)")
    assert.are.equal(chat, tonumber(c), "💬 part != 💬 rows; header: " .. header(tree))
    assert.are.equal(person, tonumber(p), "👤 part != 👤 rows; header: " .. header(tree))
    assert.are.equal(chat + person, tonumber(total), "total != sum; header: " .. header(tree))
  end)
end)
