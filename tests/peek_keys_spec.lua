-- Bead beads_nvim-4u9.15: gd peek keys are configurable and documented.
-- Interface under test:
--   * keymaps.detail.view.peek (default "gd"), keymaps.tree_view.peek (default "gd") and
--     keymaps.peek.{peek = "gd", close = { "q", "<Esc>" }, close_all = "Q", open = "<CR>",
--     yank_id = "yy", yank_run = "yr", help = "?"}; a key, a list of keys or false (disabled).
--   * README.md lists `gd` and `Q`; the ? help of a VIEW detail and of the tree list gd as peek.
-- Fixture and fake bd: tests/peek_fake.lua.
-- assumption: the action names above (keymaps.peek.peek / close / close_all / open / yank_id /
--   yank_run / help) are the config contract.
-- assumption: the help line of the gd key contains "gd" and the word "peek".

local fake = require("tests.peek_fake")

local function help_lines(win, keys)
  local before = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    before[w] = true
  end
  fake.press(win, keys)
  local found
  vim.wait(1000, function()
    for _, w in ipairs(fake.floats()) do
      if not before[w] then
        found = w
        return true
      end
    end
    return false
  end, 10)
  assert.is_not_nil(found, keys .. " opened no help float")
  return fake.lines_of(found)
end

local function has_peek_line(lines)
  for _, l in ipairs(lines) do
    if vim.list_contains(vim.split(vim.trim(l), "%s+"), "gd") and l:lower():find("peek", 1, true) then
      return true
    end
  end
  return false
end

describe("gd peek keys", function()
  before_each(function()
    fake.setup({})
  end)

  after_each(function()
    fake.teardown()
  end)

  it("VIEW detail and tree map gd by default", function()
    local buf = fake.edit_in(vim.api.nvim_get_current_win(), "pk-b2y")
    local km = fake.buf_map(buf, "n", "gd")
    assert.is_not_nil(km, "gd is not mapped in the VIEW detail buffer")
    assert.is_truthy(km.desc and km.desc:lower():find("peek", 1, true), "desc of gd does not mention peek")
    local tree = fake.open_tree()
    assert.is_not_nil(fake.buf_map(vim.api.nvim_win_get_buf(tree), "n", "gd"), "gd is not mapped in the tree")
  end)

  it("keymaps.detail.view.peek remaps gd", function()
    require("beads").setup({ tree = { layout = "split" }, keymaps = { detail = { view = { peek = "<F9>" } } } })
    local win = vim.api.nvim_get_current_win()
    local buf = fake.edit_in(win, "pk-b2y")
    assert.is_nil(fake.buf_map(buf, "n", "gd"), "gd still buffer-mapped with detail.view.peek = '<F9>'")
    fake.cursor_on(win, "pk-d4w", 1)
    fake.peek(win, "<F9>", "pk-d4w")
  end)

  it("keymaps.tree_view.peek = false disables gd in the tree", function()
    require("beads").setup({ tree = { layout = "split" }, keymaps = { tree_view = { peek = false } } })
    local tree = fake.open_tree()
    assert.is_nil(fake.buf_map(vim.api.nvim_win_get_buf(tree), "n", "gd"), "gd mapped in the tree with peek = false")
  end)

  it("keymaps.peek.* remaps the float keys", function()
    require("beads").setup({ tree = { layout = "split" }, keymaps = { peek = { close = "<F5>", close_all = "<F6>", peek = "<F4>" } } })
    local win = vim.api.nvim_get_current_win()
    fake.edit_in(win, "pk-b2y")
    fake.cursor_on(win, "pk-c3z", 2)
    local f1 = fake.peek(win, "gd", "pk-c3z")
    local fbuf = vim.api.nvim_win_get_buf(f1)
    assert.is_nil(fake.buf_map(fbuf, "n", "q"), "q still mapped in the float with peek.close = '<F5>'")
    assert.is_nil(fake.buf_map(fbuf, "n", "Q"), "Q still mapped with peek.close_all = '<F6>'")
    fake.cursor_on(f1, "pk-d4w", 1)
    local f2 = fake.peek(f1, "<F4>", "pk-d4w")
    fake.press(f2, "<F5>")
    assert.is_false(vim.api.nvim_win_is_valid(f2), "<F5> (peek.close) did not close the top float")
    assert.is_true(vim.api.nvim_win_is_valid(f1))
    fake.cursor_on(f1, "pk-d4w", 1)
    fake.peek(f1, "<F4>", "pk-d4w")
    fake.press(vim.api.nvim_get_current_win(), "<F6>")
    assert.are.equal(0, #fake.peeks(), "<F6> (peek.close_all) did not close all floats")
  end)

  it("the VIEW detail ? help lists gd (peek)", function()
    local win = vim.api.nvim_get_current_win()
    fake.edit_in(win, "pk-b2y")
    local lines = help_lines(win, "?")
    assert.is_true(has_peek_line(lines), "detail help has no gd peek line:\n" .. table.concat(lines, "\n"))
  end)

  it("the tree ? help lists gd (peek)", function()
    local tree = fake.open_tree()
    local lines = help_lines(tree, "?")
    assert.is_true(has_peek_line(lines), "tree help has no gd peek line:\n" .. table.concat(lines, "\n"))
  end)

  it("README.md lists the peek keys", function()
    local text = table.concat(vim.fn.readfile(fake.plugin_root .. "/README.md"), "\n")
    assert.is_truthy(text:find("`gd`", 1, true), "README.md does not list `gd`")
    assert.is_truthy(text:find("`Q`", 1, true), "README.md does not list `Q`")
    assert.is_truthy(text:lower():find("peek", 1, true), "README.md does not mention peek")
  end)
end)
