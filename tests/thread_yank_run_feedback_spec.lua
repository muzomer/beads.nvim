-- Bead beads_nvim-69z: yank_run (yr) in a thread float of a human thread echoes what was yanked,
-- like the other yanks (one notification "Beads: ..." containing the yanked text).
-- bd is a fake on PATH (tests/questions_fake.lua).

local fake = require("tests.questions_fake")
vim.opt.rtp:prepend(fake.repo)

describe("thread float yank_run feedback", function()
  local notes

  before_each(function()
    fake.setup()
    require("beads").setup({})
    vim.fn.setreg('"', "")
  end)

  after_each(function()
    fake.teardown()
  end)

  it("yr on a human thread sets the register and notifies 'Beads: ...' with the command", function()
    fake.write_human({ fake.bead({ notes = "earlier note\nShould we use sqlite?", labels = { "human" } }) })
    local buf = fake.open_detail()
    fake.open_thread(buf, "Should we use sqlite?")
    vim.ui.input = function()
      error("yr asked for input")
    end
    notes = fake.capture_notify()
    fake.press("yr")
    local want = "/beads-workflow:run-bead fx-1"
    assert.are.equal(want, vim.fn.getreg('"'), "register not set")
    vim.wait(500, function()
      return false
    end, 10)
    local got = {}
    for _, n in ipairs(notes) do
      if n.msg:find(want, 1, true) then
        got[#got + 1] = n.msg
      end
    end
    local all = {}
    for _, n in ipairs(notes) do
      all[#all + 1] = n.msg
    end
    assert.are.equal(1, #got, "expected one yank notification:\n" .. table.concat(all, "\n---\n"))
    assert.is_truthy(vim.startswith(got[1], "Beads: "), got[1])
  end)
end)
