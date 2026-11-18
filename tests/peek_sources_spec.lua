-- Bead beads_nvim-4u9.15: where gd peeks, and its fallback to Vim's own gd.
-- Interface under test (key presses only):
--   * gd works on parent:, on an id in Description text (cursor anywhere inside the id, ids with
--     .<n> suffixes and ids followed by punctuation included), in the tree, and in a thread float.
--   * gd on a word that is not an existing bead id runs Vim's built-in gd (no float, no error).
-- Fixture and fake bd: tests/peek_fake.lua.
-- assumption: in the tree, gd with the cursor on a row's id peeks that row's bead.
-- assumption: <CR> in a peek float opened from the tree opens the bead in the main (non-tree,
--   non-float) window, not in the tree window.

local fake = require("tests.peek_fake")

local function origin()
  local win = vim.api.nvim_get_current_win()
  local buf = fake.edit_in(win, "pk-b2y")
  return win, buf
end

-- Expected landing of Vim's own gd from the current cursor (computed, then the cursor restored).
local function builtin_gd(win)
  local cur = vim.api.nvim_win_get_cursor(win)
  vim.api.nvim_set_current_win(win)
  vim.cmd("normal! gd")
  local want = vim.api.nvim_win_get_cursor(win)
  vim.api.nvim_win_set_cursor(win, cur)
  return want, cur
end

local function assert_fallback(win, text, from_row)
  fake.cursor_on(win, text, 1, from_row)
  local want, cur = builtin_gd(win)
  assert.are_not.same(cur, want, "setup: Vim's gd would not move the cursor from " .. vim.inspect(cur))
  local nfloats = #fake.floats()
  vim.v.errmsg = ""
  fake.notes = {}
  local ok, err = pcall(fake.press, win, "gd")
  vim.wait(200, function()
    return false
  end, 10)
  assert.is_true(ok, "gd raised an error: " .. tostring(err))
  assert.are.equal("", vim.v.errmsg, "gd set an error message")
  assert.are.equal(nfloats, #fake.floats(), "gd on " .. text .. " opened a float: " .. fake.describe_floats())
  assert.are.equal(win, vim.api.nvim_get_current_win())
  assert.are.same(want, vim.api.nvim_win_get_cursor(win), "gd on " .. text .. " did not act like Vim's gd")
  for _, n in ipairs(fake.notes) do
    assert.is_falsy(n:lower():find("error", 1, true), "gd notified an error: " .. n)
  end
end

describe("gd peek sources", function()
  before_each(function()
    fake.setup({})
  end)

  after_each(function()
    fake.teardown()
  end)

  it("works on parent:", function()
    local win = origin()
    local row = fake.cursor_on(win, "parent: pk-a1x")
    vim.api.nvim_win_set_cursor(win, { row, #"parent: pk-a" + 1 })
    local f = fake.peek(win, "gd", "pk-a1x")
    assert.is_truthy(fake.text_of(f):find("# Alpha epic", 1, true), fake.text_of(f))
  end)

  it("works on an id in Description text followed by punctuation", function()
    local win = origin()
    fake.cursor_on(win, "pk-d4w,", 4)
    local f = fake.peek(win, "gd", "pk-d4w")
    assert.is_truthy(fake.text_of(f):find("# Delta notes", 1, true), fake.text_of(f))
  end)

  it("works on an id with a .<n> suffix, cursor on the suffix", function()
    local win = origin()
    fake.cursor_on(win, "pk-a1x.1", #"pk-a1x.")
    local f = fake.peek(win, "gd", "pk-a1x.1")
    assert.is_truthy(fake.text_of(f):find("# Dotted child", 1, true), fake.text_of(f))
  end)

  it("works in the tree, and <CR> then opens the bead in the main window", function()
    local tree = fake.open_tree()
    local main = fake.main_win(tree)
    assert.is_not_nil(main, "setup: no main window beside the tree")
    vim.api.nvim_set_current_win(tree)
    fake.cursor_on(tree, "pk-c3z", 3)
    local f = fake.peek(tree, "gd", "pk-c3z")
    assert.is_false(vim.bo[vim.api.nvim_win_get_buf(f)].modifiable, "peek float from the tree is modifiable")
    fake.press(f, "<CR>")
    assert(vim.wait(3000, function()
      return fake.shown_id(main) == "pk-c3z" and fake.detail_loaded(vim.api.nvim_win_get_buf(main), "pk-c3z")
    end, 10), "<CR> did not open beads://pk-c3z in the main window; it shows " .. tostring(fake.shown_id(main)))
    assert.are.equal(0, #fake.peeks(), "<CR> left peek floats open")
    assert.are.equal("beads-tree", vim.bo[vim.api.nvim_win_get_buf(tree)].filetype, "the tree window changed")
    assert.are.equal("view", vim.b[vim.api.nvim_win_get_buf(main)].beads_mode)
  end)

  it("works in a thread float", function()
    require("beads.questions.store").add(fake.root(), {
      bead = "pk-b2y",
      messages = { { author = "agent", body = "Should this wait for pk-c3z first?" } },
    })
    local win, buf = origin()
    assert(vim.wait(3000, function()
      return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("Should this wait", 1, true) ~= nil
    end, 10), "setup: the thread is not listed in the detail")
    fake.cursor_on(win, "Should this wait")
    local before = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      before[w] = true
    end
    fake.press(win, "<CR>")
    local tf
    vim.wait(2000, function()
      for _, w in ipairs(fake.floats()) do
        if not before[w] then
          tf = w
          return true
        end
      end
      return false
    end, 10)
    assert.is_not_nil(tf, "setup: <CR> opened no thread float")
    fake.cursor_on(tf, "pk-c3z", 2)
    local f = fake.peek(tf, "gd", "pk-c3z")
    assert.is_truthy(fake.text_of(f):find("# Charlie blocker", 1, true), fake.text_of(f))
  end)

  it("falls back to Vim's gd on a plain word", function()
    local win = origin()
    local first = fake.cursor_on(win, "zebra first")
    assert_fallback(win, "zebra second", first + 1)
  end)

  it("falls back to Vim's gd on an id-shaped word that is no bead", function()
    local win = origin()
    local first = fake.cursor_on(win, "Unknown pk-zz9")
    assert_fallback(win, "pk-zz9 again", first + 1)
  end)
end)
