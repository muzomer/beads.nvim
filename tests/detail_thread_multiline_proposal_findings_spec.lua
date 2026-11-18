-- Bead beads_nvim-4gx.4, review finding (blocker) lua/beads/views/thread.lua:18:
-- a multiline proposal (beads-ask propose --field description - reads the value from stdin) put a
-- newline into one float line, so nvim_buf_set_lines raised and the thread float stayed empty.
-- The float must show the conversation and every line of the proposed value.
-- bd is a fake on PATH (tests/questions_fake.lua).

local fake = require("tests.questions_fake")
local store = require("beads.questions.store")

describe("beads thread float with a multiline proposal", function()
  before_each(function()
    fake.setup()
    require("beads").setup({})
  end)

  after_each(function()
    fake.teardown()
  end)

  it("<CR> opens the float showing every line of a multiline proposal without error", function()
    local t = store.add(fake.dir(), {
      bead = "fx-1",
      messages = { { author = "agent", body = "Rewrite description?" } },
    })
    store.reply(
      fake.dir(),
      t.id,
      "agent",
      "Proposal below",
      { field = "description", value = "First proposed line\nSecond proposed line\nThird proposed line" }
    )
    local buf = fake.open_detail()
    local errs = {}
    local ok, err = pcall(function()
      local f = fake.open_thread(buf, "Rewrite description?")
      vim.wait(100, function()
        return false
      end, 10)
      local text = fake.float_text(f)
      for _, want in ipairs({ "Rewrite description?", "First proposed line", "Second proposed line", "Third proposed line" }) do
        if not text:find(want, 1, true) then
          errs[#errs + 1] = "float lacks '" .. want .. "': " .. text
        end
      end
      for _, l in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(f), 0, -1, false)) do
        assert.is_nil(l:find("\n", 1, true), "float line contains a newline")
      end
    end)
    assert.is_true(ok, "opening the thread float raised: " .. tostring(err))
    assert.are.same({}, errs)
  end)
end)
