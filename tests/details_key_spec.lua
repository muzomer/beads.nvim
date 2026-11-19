-- Bead beads_nvim-ezh: K ("show details of the bead here") in the detail VIEW buffer, the thread
-- float and the peek float opens the peek float for the bead id under the cursor (as gd); off a
-- bead id it does nothing (no error, no keywordprg / :Man lookup).
-- Interface under test:
--   * keymaps.detail.view.details, keymaps.thread.details, keymaps.peek.details (default "K";
--     a key, a list of keys or false = disabled).
--   * The detail ? help lists K; README.md has a detail-table row for `K` / `details` and the
--     peek paragraph names the new float keys.
-- Fixture and fake bd: tests/peek_fake.lua.
-- assumption: README.md's detail table gets a row starting "| `K` | `details` |".
-- assumption: README.md's peek paragraph names `]b` (one of the detail keys a float now has).

local fake = require("tests.peek_fake")
local qstore = require("beads.questions.store")

local function settle(ms)
  vim.wait(ms or 300, function()
    return false
  end, 10)
end

local function snapshot_wins()
  local t = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    t[w] = true
  end
  return t
end

local function wait_new_float(before, what)
  local w
  vim.wait(3000, function()
    for _, x in ipairs(fake.floats()) do
      if not before[x] then
        w = x
        return true
      end
    end
    return false
  end, 10)
  assert(w, what .. " opened no float; floats: " .. fake.describe_floats())
  return w
end

-- K off a bead id in win: no error, no window, focus kept, no notification, no Vim error.
local function assert_noop(win, keys)
  local notes_before = #fake.notes
  local wins_before = #vim.api.nvim_list_wins()
  local peeks_before = #fake.peeks()
  vim.v.errmsg = ""
  local ok, err = pcall(fake.press, win, keys)
  assert.is_true(ok, keys .. " off a bead id raised: " .. tostring(err))
  settle()
  assert.are.equal(peeks_before, #fake.peeks(), keys .. " off a bead id opened a peek: " .. fake.describe_floats())
  assert.are.equal(wins_before, #vim.api.nvim_list_wins(), keys .. " off a bead id opened a window")
  assert.are.equal(win, vim.api.nvim_get_current_win(), keys .. " off a bead id moved focus")
  assert.are.same({}, vim.list_slice(fake.notes, notes_before + 1), keys .. " off a bead id notified")
  assert.are.equal("", vim.v.errmsg, keys .. " off a bead id raised a Vim error (keywordprg?)")
end

-- Opens the detail of pk-b2y with a stored question mentioning pk-d4w, then its thread float.
local function open_thread()
  qstore.add(fake.root(), {
    bead = "pk-b2y",
    section = "description",
    messages = { { author = "agent", body = "Should pk-d4w be merged, zebra?" } },
  })
  local win = vim.api.nvim_get_current_win()
  local buf = fake.edit_in(win, "pk-b2y")
  assert(vim.wait(3000, function()
    return vim.list_contains(fake.lines_of(win), "## Questions")
  end, 10), "detail has no Questions section:\n" .. fake.text_of(win))
  local h
  for i, l in ipairs(fake.lines_of(win)) do
    if l == "## Questions" then
      h = i
    end
  end
  vim.api.nvim_win_set_cursor(win, { h + 1, 0 })
  local before = snapshot_wins()
  fake.press(win, "<CR>")
  local tf = wait_new_float(before, "<CR> on the question")
  assert(vim.wait(3000, function()
    return fake.text_of(tf):find("pk-d4w", 1, true) ~= nil
  end, 10), "thread float does not show the question:\n" .. fake.text_of(tf))
  return tf, buf
end

describe("K (details) in detail, thread and peek", function()
  before_each(function()
    fake.setup({})
  end)

  after_each(function()
    fake.teardown()
  end)

  it("detail VIEW maps K and K on a bead id opens its peek float", function()
    local win = vim.api.nvim_get_current_win()
    local buf = fake.edit_in(win, "pk-b2y")
    assert.is_not_nil(fake.buf_map(buf, "n", "K"), "K is not mapped in the VIEW detail buffer")
    fake.cursor_on(win, "pk-d4w", 1)
    local f = fake.peek(win, "K", "pk-d4w")
    assert.are.equal(f, vim.api.nvim_get_current_win(), "the peek float is not focused")
  end)

  it("detail VIEW: K off a bead id does nothing", function()
    local win = vim.api.nvim_get_current_win()
    fake.edit_in(win, "pk-b2y")
    fake.cursor_on(win, "zebra", 1)
    assert_noop(win, "K")
  end)

  it("thread float: K on a bead id opens its peek float, off an id does nothing", function()
    local tf = open_thread()
    assert.is_not_nil(fake.buf_map(vim.api.nvim_win_get_buf(tf), "n", "K"), "K is not mapped in the thread float")
    fake.cursor_on(tf, "zebra", 1)
    assert_noop(tf, "K")
    fake.cursor_on(tf, "pk-d4w", 1)
    fake.peek(tf, "K", "pk-d4w")
  end)

  it("peek float: K on a bead id stacks a peek float, off an id does nothing", function()
    local win = vim.api.nvim_get_current_win()
    fake.edit_in(win, "pk-b2y")
    fake.cursor_on(win, "pk-c3z", 2)
    local f1 = fake.peek(win, "gd", "pk-c3z")
    assert.is_not_nil(fake.buf_map(vim.api.nvim_win_get_buf(f1), "n", "K"), "K is not mapped in the peek float")
    fake.cursor_on(f1, "Charlie", 1)
    assert_noop(f1, "K")
    fake.cursor_on(f1, "pk-d4w", 1)
    local f2 = fake.peek(f1, "K", "pk-d4w")
    assert.are_not.equal(f1, f2)
    assert.are.equal(2, #fake.peeks(), "K did not stack a second float: " .. fake.describe_floats())
  end)

  it("keymaps.detail.view.details remaps K; false disables it", function()
    require("beads").setup({ tree = { layout = "split" }, keymaps = { detail = { view = { details = "<F9>" } } } })
    local win = vim.api.nvim_get_current_win()
    local buf = fake.edit_in(win, "pk-b2y")
    assert.is_nil(fake.buf_map(buf, "n", "K"), "K still mapped with detail.view.details = '<F9>'")
    fake.cursor_on(win, "pk-d4w", 1)
    fake.peek(win, "<F9>", "pk-d4w")
    fake.close_floats()
    require("beads").setup({ tree = { layout = "split" }, keymaps = { detail = { view = { details = false } } } })
    vim.cmd("enew!")
    local buf2 = fake.edit_in(win, "pk-c3z")
    assert.is_nil(fake.buf_map(buf2, "n", "K"), "K mapped in detail with details = false")
  end)

  it("keymaps.thread.details = false disables K in the thread float", function()
    require("beads").setup({ tree = { layout = "split" }, keymaps = { thread = { details = false } } })
    local tf = open_thread()
    assert.is_nil(fake.buf_map(vim.api.nvim_win_get_buf(tf), "n", "K"), "K mapped in thread with details = false")
  end)

  it("keymaps.peek.details remaps K in the peek float", function()
    require("beads").setup({ tree = { layout = "split" }, keymaps = { peek = { details = "<F9>" } } })
    local win = vim.api.nvim_get_current_win()
    fake.edit_in(win, "pk-b2y")
    fake.cursor_on(win, "pk-c3z", 2)
    local f1 = fake.peek(win, "gd", "pk-c3z")
    assert.is_nil(fake.buf_map(vim.api.nvim_win_get_buf(f1), "n", "K"), "K still mapped with peek.details = '<F9>'")
    fake.cursor_on(f1, "pk-d4w", 1)
    fake.peek(f1, "<F9>", "pk-d4w")
  end)

  it("the detail ? help lists K", function()
    local win = vim.api.nvim_get_current_win()
    fake.edit_in(win, "pk-b2y")
    local before = snapshot_wins()
    fake.press(win, "?")
    local hf = wait_new_float(before, "?")
    local found = false
    for _, l in ipairs(fake.lines_of(hf)) do
      if vim.split(vim.trim(l), "[%s,/]+")[1] == "K" then
        found = true
      end
    end
    assert.is_true(found, "detail help has no K line:\n" .. fake.text_of(hf))
  end)

  it("README.md documents K in the detail table and the peek float keys", function()
    local lines = vim.fn.readfile(fake.plugin_root .. "/README.md")
    local row, peek_para = false, false
    for _, l in ipairs(lines) do
      if l:find("^| `K` | `details` |") then
        row = true
      end
      if l:lower():find("peek", 1, true) and l:find("`]b`", 1, true) then
        peek_para = true
      end
    end
    assert.is_true(row, "README.md detail table has no `K` | `details` row")
    assert.is_true(peek_para, "README.md peek section does not name the float's detail keys (e.g. `]b`)")
  end)
end)
