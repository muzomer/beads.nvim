-- Bead beads_nvim-4u9.14: the ]b / [b keys of the detail VIEW mode.
-- Interface under test:
--   * keymaps.detail.view.next_bead (default "]b") / prev_bead (default "[b") are buffer-local
--     normal-mode maps of a detail buffer in VIEW mode; they can be remapped or set to false.
--   * In EDIT mode the plugin maps neither ]b nor [b in the buffer (Vim's own / global ]b [b stay).
--   * README.md lists `]b` and `[b`; the ? help float of a VIEW detail lists them.
-- Fixture and fake bd: tests/detail_jump_fake.lua.
-- assumption: the help line of each key contains the key text and "next" / "prev" (its desc).

local fake = require("tests.detail_jump_fake")

local function open_float(win, keys)
  local before = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    before[w] = true
  end
  fake.press(win, keys)
  local found
  vim.wait(1000, function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if not before[w] and vim.api.nvim_win_get_config(w).relative ~= "" then
        found = w
        return true
      end
    end
    return false
  end, 10)
  return found
end

describe("detail ]b / [b keys", function()
  before_each(function()
    fake.setup({})
  end)

  after_each(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    fake.teardown()
  end)

  it("VIEW mode maps ]b and [b in the detail buffer", function()
    local buf = fake.edit_in(vim.api.nvim_get_current_win(), "ep-s")
    assert.are.equal("view", vim.b[buf].beads_mode)
    local nxt, prv = fake.buf_map(buf, "n", "]b"), fake.buf_map(buf, "n", "[b")
    assert.is_not_nil(nxt, "]b is not mapped in the VIEW detail buffer")
    assert.is_not_nil(prv, "[b is not mapped in the VIEW detail buffer")
    assert.is_truthy(nxt.desc and nxt.desc:lower():find("next", 1, true), "desc of ]b does not mention next")
    assert.is_truthy(prv.desc and prv.desc:lower():find("prev", 1, true), "desc of [b does not mention previous")
  end)

  it("EDIT mode does not map ]b / [b in the buffer; back in VIEW they return", function()
    local win = vim.api.nvim_get_current_win()
    local buf = fake.edit_in(win, "ep-s")
    assert.is_not_nil(fake.buf_map(buf, "n", "]b"), "]b is not mapped in VIEW mode")
    fake.press(win, "e")
    pcall(vim.cmd, "stopinsert")
    assert.are.equal("edit", vim.b[buf].beads_mode, "e did not enter EDIT mode")
    assert.is_nil(fake.buf_map(buf, "n", "]b"), "]b is buffer-mapped in EDIT mode")
    assert.is_nil(fake.buf_map(buf, "n", "[b"), "[b is buffer-mapped in EDIT mode")
    require("beads.views.detail").enter_view(buf)
    assert.is_not_nil(fake.buf_map(buf, "n", "]b"), "]b not mapped again after returning to VIEW")
    assert.is_not_nil(fake.buf_map(buf, "n", "[b"), "[b not mapped again after returning to VIEW")
  end)

  it("next_bead can be remapped and prev_bead disabled", function()
    require("beads").setup({ keymaps = { detail = { view = { next_bead = "<F7>", prev_bead = false } } } })
    local win = vim.api.nvim_get_current_win()
    local buf = fake.edit_in(win, "ep-s")
    assert.is_not_nil(fake.buf_map(buf, "n", "<F7>"), "<F7> is not mapped with next_bead = '<F7>'")
    assert.is_nil(fake.buf_map(buf, "n", "]b"), "]b still mapped with next_bead = '<F7>'")
    assert.is_nil(fake.buf_map(buf, "n", "[b"), "[b still mapped with prev_bead = false")
    fake.jump(win, "<F7>", "gc-x")
  end)

  it("prev_bead can be remapped to a list of keys", function()
    require("beads").setup({ keymaps = { detail = { view = { prev_bead = { "<F8>" } } } } })
    local win = vim.api.nvim_get_current_win()
    local buf = fake.edit_in(win, "gc-x")
    assert.is_nil(fake.buf_map(buf, "n", "[b"), "[b still mapped with prev_bead = { '<F8>' }")
    assert.is_not_nil(fake.buf_map(buf, "n", "]b"), "]b lost when only prev_bead was changed")
    fake.jump(win, "<F8>", "ep-s")
  end)

  it("the ? help float lists ]b (next) and [b (previous)", function()
    local win = vim.api.nvim_get_current_win()
    fake.edit_in(win, "ep-s")
    local f = open_float(win, "?")
    assert.is_not_nil(f, "? opened no float")
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(f), 0, -1, false)
    local dump = table.concat(lines, "\n")
    local has_next, has_prev = false, false
    for _, l in ipairs(lines) do
      local low = l:lower()
      has_next = has_next or (l:find("]b", 1, true) ~= nil and low:find("next", 1, true) ~= nil)
      has_prev = has_prev or (l:find("[b", 1, true) ~= nil and low:find("prev", 1, true) ~= nil)
    end
    assert.is_true(has_next, "help has no line with ]b and 'next':\n" .. dump)
    assert.is_true(has_prev, "help has no line with [b and 'prev':\n" .. dump)
  end)

  it("README.md lists `]b` and `[b`", function()
    local text = table.concat(vim.fn.readfile(fake.plugin_root .. "/README.md"), "\n")
    assert.is_truthy(text:find("`]b`", 1, true), "README.md does not list `]b`")
    assert.is_truthy(text:find("`[b`", 1, true), "README.md does not list `[b`")
  end)
end)
