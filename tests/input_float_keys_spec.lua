-- Bead beads_nvim-4gx.8: default input float keys (note / comment floats).
-- Interface under test: <C-s> submits in normal and insert mode, <CR> submits in normal mode,
--   q and <Esc> cancel in normal mode (each map has a desc).
-- bd is a fake on PATH (tests/modes_fake.lua).

local fake = require("tests.modes_fake")

describe("beads input float keys", function()
  before_each(function()
    fake.setup()
    require("beads").setup({})
  end)

  after_each(function()
    fake.teardown()
  end)

  it("maps <C-s> (n, i), <CR> (n), q and <Esc> (n) with a desc", function()
    fake.open_detail()
    local f = fake.press_for_float("n")
    assert.is_not_nil(f, "n opened no float")
    local fbuf = vim.api.nvim_win_get_buf(f)
    for _, m in ipairs({ { "n", "<C-s>" }, { "i", "<C-s>" }, { "n", "<CR>" }, { "n", "q" }, { "n", "<Esc>" } }) do
      local km = fake.buf_map(fbuf, m[1], m[2])
      assert.is_not_nil(km, "no " .. m[1] .. "-mode map " .. m[2] .. " in the input float")
      assert.is_true(type(km.desc) == "string" and km.desc ~= "", m[2] .. " has no desc")
    end
  end)

  it("<CR> in normal mode submits the note", function()
    fake.open_detail()
    local f = fake.press_for_float("n")
    assert.is_not_nil(f, "n opened no float")
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(f), 0, -1, false, { "enter note" })
    vim.api.nvim_set_current_win(f)
    fake.press("<CR>")
    fake.wait_for(function()
      return fake.count("--append-notes") >= 1 and fake.count("enter note") >= 1
    end, "bd update --append-notes after <CR>")
    assert.is_false(vim.api.nvim_win_is_valid(f), "float still open after <CR>")
  end)

  -- passes already: guards <C-s> in insert mode
  it("<C-s> in insert mode submits the note", function()
    fake.open_detail()
    local f = fake.press_for_float("n")
    assert.is_not_nil(f, "n opened no float")
    vim.api.nvim_set_current_win(f)
    fake.press("iinsert note<C-s>")
    fake.wait_for(function()
      return fake.count("--append-notes") >= 1 and fake.count("insert note") >= 1
    end, "bd update --append-notes after <C-s> in insert mode")
  end)
end)
