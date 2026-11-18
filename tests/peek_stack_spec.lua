-- Bead beads_nvim-4u9.15: gd peeks a bead in a stacked, read-only floating detail view.
-- Interface under test (key presses only):
--   * gd (keymaps.detail.view.peek) on a bead id under the cursor in a VIEW detail opens a float
--     with that bead's detail rendering (frontmatter "id: <id>", sections, 4u9.8 highlighting);
--     the float buffer is not modifiable.
--   * gd inside a peek float (keymaps.peek.peek) opens another float on top, offset down/right;
--     gd on a bead already in the stack focuses its float instead of opening a duplicate.
--   * q / <Esc> (keymaps.peek.close) close the top float, focus goes to the float below;
--     Q (keymaps.peek.close_all) closes all peek floats;
--     <CR> (keymaps.peek.open) opens the float's bead in the main window in VIEW mode and closes
--     all peek floats; yy / yr / ? work inside.
-- A peek float is identified as a floating window whose buffer has an "id: <id>" line.
-- Fixture and fake bd: tests/peek_fake.lua.
-- assumption: after Q focus returns to the window gd was first pressed in.
-- assumption: "offset" means the screen position of the newer float is below and right of the older.

local fake = require("tests.peek_fake")

local function origin()
  local win = vim.api.nvim_get_current_win()
  local buf = fake.edit_in(win, "pk-b2y")
  assert.are.equal("view", vim.b[buf].beads_mode)
  return win, buf
end

-- gd on the blocked_by id of pk-b2y (cursor inside the id, on its hash part).
local function peek_blocker(win)
  local row = fake.cursor_on(win, "blocked_by:")
  local line = fake.lines_of(win)[row]
  local s = line:find("pk-c3z", 1, true)
  assert(s, "setup: blocked_by line does not list pk-c3z: " .. line)
  vim.api.nvim_win_set_cursor(win, { row, s - 1 + 4 })
  return fake.peek(win, "gd", "pk-c3z")
end

describe("gd peek float stack", function()
  before_each(function()
    fake.setup({})
  end)

  after_each(function()
    fake.teardown()
  end)

  it("gd on the blocked_by id opens a read-only float with that bead's rendered details", function()
    local win, buf = origin()
    local f = peek_blocker(win)
    assert.are.equal(f, vim.api.nvim_get_current_win(), "focus is not in the peek float")
    local fbuf = vim.api.nvim_win_get_buf(f)
    assert.is_false(vim.bo[fbuf].modifiable, "peek float buffer is modifiable")
    local text = fake.text_of(f)
    for _, want in ipairs({
      "id: pk-c3z",
      "status: open",
      "# Charlie blocker",
      "## Description",
      "Depends on pk-d4w for context.",
      "## Workflow",
      "## Notes",
      "## Comments",
    }) do
      assert.is_truthy(text:find(want, 1, true), "peek float lacks " .. want .. ":\n" .. text)
    end
    -- the detail highlighting (4u9.8) is applied too
    local lines = fake.lines_of(f)
    for i, l in ipairs(lines) do
      if l:match("^id: ") then
        assert.is_true(fake.hl_on_line(fbuf, i, "BeadsId"), "id line of the peek float has no BeadsId")
      elseif l:match("^status: ") then
        assert.is_true(fake.hl_on_line(fbuf, i, "BeadsStatusOpen"), "status line has no BeadsStatusOpen")
      end
    end
    -- the origin detail is untouched
    assert.are.equal(buf, vim.api.nvim_win_get_buf(win))
    assert.are.equal("pk-b2y", fake.shown_id(win))
  end)

  it("gd inside a peek float stacks a second float, offset, both visible", function()
    local win = origin()
    local f1 = peek_blocker(win)
    fake.cursor_on(f1, "pk-d4w", 3)
    local f2 = fake.peek(f1, "gd", "pk-d4w")
    assert.are_not.equal(f1, f2)
    assert.is_true(vim.api.nvim_win_is_valid(f1), "the first float closed when the second opened")
    assert.are.equal(f2, vim.api.nvim_get_current_win(), "focus is not in the second float")
    assert.are.equal(2, #fake.peeks(), "expected two peek floats: " .. fake.describe_floats())
    local p1, p2 = vim.api.nvim_win_get_position(f1), vim.api.nvim_win_get_position(f2)
    assert.is_true(p2[1] > p1[1], ("second float not below the first: %d <= %d"):format(p2[1], p1[1]))
    assert.is_true(p2[2] > p1[2], ("second float not right of the first: %d <= %d"):format(p2[2], p1[2]))
    assert.is_false(vim.bo[vim.api.nvim_win_get_buf(f2)].modifiable, "second float is modifiable")
  end)

  it("gd on a bead already in the stack focuses its float instead of opening a duplicate", function()
    local win = origin()
    local f1 = peek_blocker(win)
    fake.cursor_on(f1, "pk-d4w")
    local f2 = fake.peek(f1, "gd", "pk-d4w")
    -- pk-d4w's description mentions pk-c3z, which is already open in f1
    fake.cursor_on(f2, "pk-c3z", 2)
    fake.press(f2, "gd")
    vim.wait(300, function()
      return false
    end, 10)
    assert.are.equal(2, #fake.peeks(), "a duplicate float was opened: " .. fake.describe_floats())
    assert.are.equal(f1, vim.api.nvim_get_current_win(), "focus did not move to the existing pk-c3z float")
    assert.is_true(vim.api.nvim_win_is_valid(f2), "the pk-d4w float was closed")
  end)

  it("q closes only the top float and focus returns to the one below", function()
    local win = origin()
    local f1 = peek_blocker(win)
    fake.cursor_on(f1, "pk-d4w")
    local f2 = fake.peek(f1, "gd", "pk-d4w")
    fake.press(f2, "q")
    assert.is_false(vim.api.nvim_win_is_valid(f2), "q did not close the top float")
    assert.is_true(vim.api.nvim_win_is_valid(f1), "q closed the float below too")
    assert.are.equal(f1, vim.api.nvim_get_current_win(), "focus did not return to the float below")
    fake.press(f1, "q")
    assert.is_false(vim.api.nvim_win_is_valid(f1), "q did not close the last float")
    assert.are.equal(win, vim.api.nvim_get_current_win(), "focus did not return to the detail window")
  end)

  it("<Esc> closes only the top float", function()
    local win = origin()
    local f1 = peek_blocker(win)
    fake.cursor_on(f1, "pk-d4w")
    local f2 = fake.peek(f1, "gd", "pk-d4w")
    fake.press(f2, "<Esc>")
    assert.is_false(vim.api.nvim_win_is_valid(f2), "<Esc> did not close the top float")
    assert.is_true(vim.api.nvim_win_is_valid(f1), "<Esc> closed the float below too")
    assert.are.equal(f1, vim.api.nvim_get_current_win())
  end)

  it("Q closes all peek floats", function()
    local win = origin()
    local f1 = peek_blocker(win)
    fake.cursor_on(f1, "pk-d4w")
    local f2 = fake.peek(f1, "gd", "pk-d4w")
    fake.press(f2, "Q")
    assert.are.equal(0, #fake.peeks(), "Q left peek floats open: " .. fake.describe_floats())
    assert.are.equal(win, vim.api.nvim_get_current_win(), "focus did not return to the detail window")
    assert.are.equal("pk-b2y", fake.shown_id(win))
  end)

  it("<CR> opens the float's bead in the main window in VIEW mode and closes all peek floats", function()
    local win = origin()
    local f1 = peek_blocker(win)
    fake.cursor_on(f1, "pk-d4w")
    local f2 = fake.peek(f1, "gd", "pk-d4w")
    fake.press(f2, "<CR>")
    assert(vim.wait(3000, function()
      return fake.shown_id(win) == "pk-d4w" and fake.detail_loaded(vim.api.nvim_win_get_buf(win), "pk-d4w")
    end, 10), "<CR> did not open beads://pk-d4w in the main window; it shows " .. tostring(fake.shown_id(win)))
    assert.are.equal(0, #fake.peeks(), "<CR> left peek floats open: " .. fake.describe_floats())
    assert.are.equal(win, vim.api.nvim_get_current_win(), "focus is not in the main window")
    assert.are.equal("view", vim.b[vim.api.nvim_win_get_buf(win)].beads_mode, "not in VIEW mode after <CR>")
  end)

  it("yy in a peek float yanks the peeked bead's id, not the origin's", function()
    local win = origin()
    local f1 = peek_blocker(win)
    vim.fn.setreg('"', "")
    fake.press(f1, "yy")
    assert.are.equal("pk-c3z", vim.fn.getreg('"'), "yy in the peek float did not yank pk-c3z")
  end)

  it("yr in a peek float yanks the peeked bead's run command", function()
    local win = origin()
    local f1 = peek_blocker(win)
    vim.fn.setreg('"', "")
    fake.press(f1, "yr")
    local reg = vim.fn.getreg('"')
    assert.is_truthy(reg:find("pk-c3z", 1, true), "yr did not yank a run command for pk-c3z: " .. reg)
  end)

  it("? in a peek float shows help listing gd, q, Q and <CR>", function()
    local win = origin()
    local f1 = peek_blocker(win)
    local before = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      before[w] = true
    end
    fake.press(f1, "?")
    local help
    vim.wait(1000, function()
      for _, w in ipairs(fake.floats()) do
        if not before[w] then
          help = w
          return true
        end
      end
      return false
    end, 10)
    assert.is_not_nil(help, "? opened no help float")
    local lines = fake.lines_of(help)
    local function has(key)
      for _, l in ipairs(lines) do
        if vim.list_contains(vim.split(vim.trim(l), "%s+"), key) then
          return true
        end
      end
      return false
    end
    for _, k in ipairs({ "gd", "q", "Q", "<CR>" }) do
      assert.is_true(has(k), "help lacks " .. k .. ":\n" .. table.concat(lines, "\n"))
    end
  end)
end)
