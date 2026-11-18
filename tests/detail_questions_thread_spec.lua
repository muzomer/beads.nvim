-- Bead beads_nvim-4gx.4: Questions section in beads://<id> and the thread float (stored threads).
-- Interface under test:
--   * The detail buffer (VIEW mode) shows '## Questions' with one line per thread of this bead from
--     beads.questions.store.list(root, { bead = id }) (threads of other beads are not shown).
--   * <CR> on a thread line (VIEW mode) opens a float with the conversation. Thread float keys
--     (keymaps.thread defaults): r/i reply, x resolve, a apply proposal, n/p next/prev,
--     ?/g? help, q/<Esc> close; buffer-local on the float buffer.
--   * r stores a user message (store.reply author "user"); x resolves (status "resolved").
--   * a on a thread whose latest proposal is { field = "title", value = ... } writes the value into
--     the detail buffer as an unsaved edit (modified, EDIT mode) without any bd write call; :w then
--     saves it through the normal path (bd update fx-1 --title ...).
--   * ]u / [u in VIEW mode jump to the next / previous thread line waiting for the owner
--     (needs == "user").
-- bd is a fake on PATH (tests/questions_fake.lua).

local fake = require("tests.questions_fake")
local store = require("beads.questions.store")

local function add(body, extra)
  local t = { bead = "fx-1", messages = { { author = "agent", body = body } } }
  for k, v in pairs(extra or {}) do
    t[k] = v
  end
  return store.add(fake.dir(), t)
end

local function write_calls()
  local n = 0
  for _, l in ipairs(fake.log()) do
    local w = " " .. l .. " "
    if not (w:find(" list ", 1, true) or w:find(" show ", 1, true)) then
      for _, sub in ipairs({ " update ", "label remove", "label add", " close ", " comment" }) do
        if w:find(sub, 1, true) then
          n = n + 1
          break
        end
      end
    end
  end
  return n
end

describe("beads detail Questions section and thread float", function()
  before_each(function()
    fake.setup()
    require("beads").setup({})
  end)

  after_each(function()
    fake.teardown()
  end)

  it("shows the bead's stored threads (two) and not those of other beads", function()
    add("First question here")
    add("Second question here")
    store.add(fake.dir(), { bead = "fx-2", messages = { { author = "agent", body = "Other bead question" } } })
    local buf = fake.open_detail()
    local a = fake.wait_question(buf, "First question here")
    local b = fake.wait_question(buf, "Second question here")
    assert.are_not.equal(a, b)
    assert.is_nil(fake.question_line(buf, "Other bead question"), "thread of fx-2 shown in fx-1")
    assert.is_false(vim.bo[buf].modified)
  end)

  it("<CR> on a thread line opens a float with the conversation and the thread keys", function()
    local t = add("DB: Which database?")
    store.reply(fake.dir(), t.id, "user", "DB: Postgres please")
    store.reply(fake.dir(), t.id, "agent", "DB: Which version?")
    local buf = fake.open_detail()
    local f = fake.open_thread(buf, "DB:")
    local text = fake.float_text(f)
    assert.is_truthy(text:find("Which database?", 1, true), text)
    assert.is_truthy(text:find("Postgres please", 1, true), text)
    assert.is_truthy(text:find("Which version?", 1, true), text)
    local fbuf = vim.api.nvim_win_get_buf(f)
    for _, k in ipairs({ "r", "i", "x", "a", "n", "p", "?", "g?", "q", "<Esc>" }) do
      assert.is_not_nil(fake.buf_map(fbuf, "n", k), "no buffer-local thread float map for " .. k)
    end
    fake.press("q")
    assert.is_false(vim.api.nvim_win_is_valid(f), "q did not close the thread float")
  end)

  it("r in the thread float stores a user reply", function()
    local t = add("Which database?")
    local buf = fake.open_detail()
    fake.open_thread(buf, "Which database?")
    assert.is_true(fake.reply("Use sqlite"), "r asked for no reply text")
    fake.wait_for(function()
      local cur = store.get(fake.dir(), t.id)
      local last = cur.messages[#cur.messages]
      return last.author == "user" and last.body == "Use sqlite"
    end, "user reply stored")
    assert.equals("agent", store.get(fake.dir(), t.id).needs)
  end)

  it("x in the thread float resolves the thread", function()
    local t = add("Which database?")
    local buf = fake.open_detail()
    fake.open_thread(buf, "Which database?")
    fake.press("x")
    fake.wait_for(function()
      return store.get(fake.dir(), t.id).status == "resolved"
    end, "thread resolved")
  end)

  it("a applies a proposal as an unsaved edit in EDIT mode with no bd call; :w saves it", function()
    local t = add("Better title?")
    store.reply(fake.dir(), t.id, "agent", "Better title? Proposal", { field = "title", value = "Proposed title" })
    local buf = fake.open_detail()
    fake.open_thread(buf, "Better title?")
    local before = write_calls()
    fake.select_apply()
    fake.press("a")
    fake.wait_for(function()
      return vim.tbl_contains(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "# Proposed title")
    end, "proposed title in the detail buffer")
    pcall(vim.cmd, "stopinsert")
    assert.is_true(vim.bo[buf].modified, "detail buffer not marked modified")
    assert.equals("edit", vim.b[buf].beads_mode)
    assert.is_true(vim.bo[buf].modifiable)
    assert.equals(before, write_calls(), "a made a bd write call: " .. vim.inspect(fake.log()))

    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
    vim.cmd("write")
    fake.wait_for(function()
      return fake.count("--title Proposed title") >= 1
    end, "bd update --title Proposed title")
  end)

  it("]u and [u jump between threads waiting for the owner", function()
    add("Waiting one")
    local t2 = add("Answered one")
    store.reply(fake.dir(), t2.id, "user", "Answered one: my answer")
    add("Waiting two")
    local buf = fake.open_detail()
    local w1 = fake.wait_question(buf, "Waiting one")
    local w2 = fake.wait_question(buf, "Waiting two")
    fake.wait_question(buf, "Answered one")
    local win = vim.fn.bufwinid(buf)
    vim.api.nvim_set_current_win(win)
    local lo, hi = math.min(w1, w2), math.max(w1, w2)
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    fake.press("]u")
    assert.equals(lo, vim.api.nvim_win_get_cursor(win)[1])
    fake.press("]u")
    assert.equals(hi, vim.api.nvim_win_get_cursor(win)[1])
    fake.press("[u")
    assert.equals(lo, vim.api.nvim_win_get_cursor(win)[1])
  end)
end)
