-- Bead beads_nvim-4gx.6: the 💬 workflow badge.
-- Interface under test (black box): a bead with an open thread whose needs == "user" (a stored
-- thread from beads.questions.store, or a human thread from beads.questions.human.list) shows the
-- literal glyph 💬 on its tree line (:Beads tree) and in picker lines (:Beads list / :Beads needs,
-- read through vim.ui.select's format_item). Closed beads never show it. Answering removes it
-- once the store is refreshed (require("beads.store").refresh(root), what the tree's R does).
-- bd is a fake on PATH; fixture in tests/questions_waiting_fake.lua.

local fake = require("tests.questions_waiting_fake")
local qstore = require("beads.questions.store")
local bstore = require("beads.store")

local GLYPH = "💬"

local function tree_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "beads-tree" then
      return w
    end
  end
end

local function open_tree()
  vim.cmd("Beads tree")
  local w
  fake.wait_for(function()
    w = tree_win()
    return w ~= nil
  end, "the tree window")
  return w
end

local function tree_line(w, id)
  for _, l in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)) do
    if l:match("^%s*" .. vim.pesc(id) .. "%s") then
      return l
    end
  end
end

local function wait_badge(w, id, want)
  local ok = vim.wait(3000, function()
    local l = tree_line(w, id)
    return l ~= nil and (l:find(GLYPH, 1, true) ~= nil) == want
  end, 10)
  assert(ok, ("timed out waiting for the tree line of %s %s %s (line: %s)"):format(
    id,
    want and "to show" or "to drop",
    GLYPH,
    tostring((tree_line(w, id)))
  ))
end

local function assert_no_badge(w, id)
  local l = tree_line(w, id)
  assert.is_not_nil(l, "no tree line for " .. id)
  assert.is_nil(l:find(GLYPH, 1, true), id .. " shows " .. GLYPH .. ": " .. l)
end

describe("beads 💬 badge", function()
  local ids

  before_each(function()
    fake.setup()
    ids = fake.write_threads()
  end)

  after_each(function()
    fake.teardown()
  end)

  it("tree: beads with a thread waiting on the user show 💬, human threads included", function()
    local w = open_tree()
    wait_badge(w, "qa-1", true)
    wait_badge(w, "hu-4", true)
    assert.truthy(tree_line(w, "hu-4"):find("👤", 1, true), "human badge lost")
    assert_no_badge(w, "ag-2") -- needs=agent
    assert_no_badge(w, "rs-3") -- resolved
    assert_no_badge(w, "pl-7") -- no thread
  end)

  it("tree: a closed bead's open thread gives no 💬 (also with closed beads shown)", function()
    local w = open_tree()
    wait_badge(w, "qa-1", true)
    vim.api.nvim_set_current_win(w)
    fake.press("H")
    fake.wait_for(function()
      return tree_line(w, "cl-5") ~= nil and tree_line(w, "hc-6") ~= nil
    end, "closed beads shown after H")
    wait_badge(w, "hu-4", true)
    assert_no_badge(w, "cl-5")
    assert_no_badge(w, "hc-6")
  end)

  it("tree: answering a stored thread removes 💬 after refresh", function()
    local w = open_tree()
    wait_badge(w, "qa-1", true)
    qstore.reply(fake.dir(), ids.a, "user", "answer a")
    qstore.reply(fake.dir(), ids.b, "user", "answer b")
    bstore.refresh(fake.dir())
    wait_badge(w, "qa-1", false)
  end)

  it("tree: answering one of two waiting threads keeps 💬", function()
    local w = open_tree()
    wait_badge(w, "qa-1", true)
    qstore.reply(fake.dir(), ids.a, "user", "answer a")
    local done = false
    bstore.refresh(fake.dir(), function()
      done = true
    end)
    fake.wait_for(function()
      return done
    end, "store refresh")
    vim.wait(200, function()
      return false
    end, 10)
    wait_badge(w, "qa-1", true)
  end)

  it("tree: answering a human thread (label removed) removes 💬 after refresh", function()
    local w = open_tree()
    wait_badge(w, "hu-4", true)
    fake.write_beads(fake.beads({ hu_answered = true }))
    bstore.refresh(fake.dir())
    wait_badge(w, "hu-4", false)
  end)

  it("pickers: :Beads list shows 💬 on a bead waiting on the user, not on others", function()
    local get = fake.capture_select()
    vim.cmd("Beads list")
    local c = get(":Beads list picker")
    local qa = fake.find(c.lines, "qa-1")
    assert.is_not_nil(qa, "qa-1 missing from list picker:\n" .. table.concat(c.lines, "\n"))
    assert.truthy(c.lines[qa]:find(GLYPH, 1, true), "no " .. GLYPH .. " in: " .. c.lines[qa])
    for _, id in ipairs({ "ag-2", "rs-3", "pl-7" }) do
      local i = fake.find(c.lines, id)
      assert.is_not_nil(i, id .. " missing from list picker")
      assert.is_nil(c.lines[i]:find(GLYPH, 1, true), id .. " shows " .. GLYPH .. ": " .. c.lines[i])
    end
  end)

  it("pickers: :Beads needs shows 💬 on a human-labelled bead with a human thread", function()
    local get = fake.capture_select()
    vim.cmd("Beads needs")
    local c = get(":Beads needs picker")
    local hu = fake.find(c.lines, "hu-4")
    assert.is_not_nil(hu, "hu-4 missing from needs picker:\n" .. table.concat(c.lines, "\n"))
    assert.truthy(c.lines[hu]:find(GLYPH, 1, true), "no " .. GLYPH .. " in: " .. c.lines[hu])
  end)
end)
