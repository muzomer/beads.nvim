-- Bead beads_nvim-4gx.4: human threads in the detail buffer's Questions section, and the
-- read-only behaviour of the section on :w.
-- Interface under test:
--   * The Questions section of beads://fx-1 combines store.list(root, { bead = "fx-1" }) with the
--     async beads.questions.human.list(root, cb) (only the thread whose bead is fx-1).
--   * <CR> on the human thread line opens the thread float; r there calls human.answer:
--     bd update fx-1 --append-notes <text>, then bd label remove fx-1 human.
--   * Editing a Questions line in EDIT mode and :w discards the edit with a WARN naming Questions
--     (like the other read-only regions) and runs no bd update.
-- bd is a fake on PATH (tests/questions_fake.lua).

local fake = require("tests.questions_fake")
local store = require("beads.questions.store")

local function human_beads()
  fake.write_human({
    fake.bead({ notes = "earlier note\nShould we use sqlite?", labels = { "human" } }),
    fake.bead({ id = "fx-2", title = "Other", notes = "Other bead asks", labels = { "human" } }),
  })
end

describe("beads detail Questions: human threads", function()
  before_each(function()
    fake.setup()
    require("beads").setup({})
  end)

  after_each(function()
    fake.teardown()
  end)

  it("shows the bead's human thread next to its stored thread, not other beads' human threads", function()
    human_beads()
    store.add(fake.dir(), { bead = "fx-1", messages = { { author = "agent", body = "A stored question" } } })
    local buf = fake.open_detail()
    local h = fake.wait_question(buf, "Should we use sqlite?")
    local s = fake.wait_question(buf, "A stored question")
    assert.are_not.equal(h, s)
    assert.is_nil(fake.question_line(buf, "Other bead asks"), "human thread of fx-2 shown in fx-1")
    assert.is_false(vim.bo[buf].modified)
  end)

  it("r on a human thread appends the note and removes the human label", function()
    human_beads()
    local buf = fake.open_detail()
    fake.open_thread(buf, "Should we use sqlite?")
    assert.is_true(fake.reply("yes use sqlite"), "r asked for no reply text")
    fake.wait_for(function()
      return fake.count("--append-notes yes use sqlite") >= 1
    end, "bd update --append-notes")
    fake.wait_for(function()
      return fake.count("label remove fx-1 human") >= 1
    end, "bd label remove fx-1 human")
    assert.equals(0, fake.count("fx-2 --append-notes"))
  end)

  it("edits inside Questions are discarded on :w with a warning", function()
    store.add(fake.dir(), { bead = "fx-1", messages = { { author = "agent", body = "Untouchable question" } } })
    local buf = fake.open_detail()
    local n = fake.wait_question(buf, "Untouchable question")
    vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
    fake.press("e")
    pcall(vim.cmd, "stopinsert")
    assert.equals("edit", vim.b[buf].beads_mode)
    local line = vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1]
    vim.api.nvim_buf_set_lines(buf, n - 1, n, false, { line .. " EDITED" })
    local got = fake.capture_notify()
    vim.cmd("write")
    fake.wait_for(function()
      for _, g in ipairs(got) do
        if g.level == vim.log.levels.WARN and g.msg:lower():find("question", 1, true) then
          return true
        end
      end
    end, "WARN naming Questions")
    for _, g in ipairs(got) do
      assert.is_falsy(g.msg:lower():find("comments", 1, true), "spurious Comments warning: " .. g.msg)
    end
    vim.wait(200)
    assert.equals(0, fake.count("update"), "an update ran: " .. vim.inspect(fake.log()))
    assert.equals(0, fake.count("EDITED"))
  end)
end)
