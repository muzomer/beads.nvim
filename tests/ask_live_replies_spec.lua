-- Bead beads_nvim-tch: live replies and the reply notification.
-- Interface under test:
--   * While a beads view is open, a write to <root>/.beads-nvim/questions.json by another process
--     (bin/beads-ask reply) refreshes the open detail buffer's Questions section and any open thread
--     float of that bead, with no other refresh trigger (no BufEnter / FocusGained / key press).
--   * A new non-user message on a thread of any bead notifies
--     "Beads: agent replied on <bead id>: <first line>"; replies within notify_group_ms give one
--     grouped notification; notify = false gives none; the plugin's own writes give none.
-- bd is a fake on PATH (tests/questions_fake.lua; its `bd context` is not embedded, so this also
-- checks that the questions watcher does not depend on the dolt backend mode).
--
-- assumption: "within ~1s" is checked as within 1500 ms after the beads-ask process exits.
-- assumption: a grouped notification starts with "Beads: agent replied" and names every bead id
-- that got a reply.

local fake = require("tests.questions_fake")
local store = require("beads.questions.store")

local WITHIN_MS = 1500
local notes

local function sleep(ms)
  vim.wait(ms, function()
    return false
  end, 10)
end

-- Runs `beads-ask reply <tid> <body>` in a separate process (an agent) and waits for it to exit.
local function agent_reply(tid, body)
  local r = vim
    .system({ fake.repo .. "/bin/beads-ask", "reply", tid, body }, {
      env = { BEADS_NVIM_ROOT = fake.dir(), BEADS_NVIM_NVIM = vim.v.progpath },
      text = true,
    })
    :wait(10000)
  assert.are.equal(0, r.code, "beads-ask reply failed: " .. tostring(r.stderr))
end

local function replied()
  local out = {}
  for _, n in ipairs(notes) do
    if n.msg:find("agent replied", 1, true) then
      out[#out + 1] = n.msg
    end
  end
  return out
end

-- A thread already answered before the view opens: its agent message must never be announced.
local function answered_thread(bead)
  return store.add(fake.dir(), {
    bead = bead,
    messages = { { author = "user", body = "Old question" }, { author = "agent", body = "Old reply" } },
  })
end

local function no_old(got)
  for _, m in ipairs(got) do
    assert.is_falsy(m:find("Old reply", 1, true), "an earlier agent message was announced: " .. m)
  end
end

local function ask_thread(bead, body)
  return store.add(fake.dir(), { bead = bead, messages = { { author = "user", body = body } } })
end

-- Opens beads://fx-1 and waits until the thread line shows; gives the watcher time to start.
local function open_detail(preview)
  local buf = fake.open_detail()
  fake.wait_question(buf, "[agent] " .. preview)
  sleep(300)
  return buf
end

describe("beads live replies", function()
  after_each(function()
    fake.teardown()
    require("beads").setup({})
  end)

  before_each(function()
    fake.setup()
  end)

  it("an agent reply updates the open detail buffer and thread float without another trigger", function()
    require("beads").setup({ notify_group_ms = 200 })
    ask_thread("fx-1", "Is it safe?")
    local buf = open_detail("Is it safe?")
    local f = fake.open_thread(buf, "Is it safe?")
    sleep(200)
    agent_reply("t1", "Yes it is\nmore detail")
    local ok = vim.wait(WITHIN_MS, function()
      return fake.question_line(buf, "[you] Is it safe?") ~= nil
        and vim.api.nvim_win_is_valid(f)
        and fake.float_text(f):find("Yes it is", 1, true) ~= nil
    end, 10)
    local lines = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.is_true(fake.question_line(buf, "[you] Is it safe?") ~= nil, "Questions section not refreshed:\n" .. lines)
    assert.is_true(vim.api.nvim_win_is_valid(f), "the thread float was closed")
    assert.is_truthy(fake.float_text(f):find("Yes it is", 1, true), "thread float not refreshed:\n" .. fake.float_text(f))
    assert.is_true(ok)
  end)

  it("one agent reply gives one 'agent replied on <id>: <first line>' notification", function()
    require("beads").setup({ notify_group_ms = 200 })
    ask_thread("fx-1", "Is it safe?")
    answered_thread("fx-1")
    open_detail("Is it safe?")
    notes = fake.capture_notify()
    agent_reply("t1", "Yes it is\nmore detail")
    fake.wait_for(function()
      return #replied() >= 1
    end, "an 'agent replied' notification", WITHIN_MS + 200)
    sleep(800)
    local got = replied()
    assert.are.equal(1, #got, table.concat(got, "\n---\n"))
    assert.is_truthy(got[1]:find("Beads: agent replied on fx-1: Yes it is", 1, true), got[1])
    assert.is_falsy(got[1]:find("more detail", 1, true), "notification has more than the first line: " .. got[1])
    no_old(got)
  end)

  it("a reply on a thread of a bead that is not open notifies with that bead's id", function()
    require("beads").setup({ notify_group_ms = 200 })
    ask_thread("fx-1", "Is it safe?")
    ask_thread("fx-2", "Other bead?")
    open_detail("Is it safe?")
    notes = fake.capture_notify()
    agent_reply("t2", "Answer for two")
    fake.wait_for(function()
      return #replied() >= 1
    end, "an 'agent replied' notification", WITHIN_MS + 200)
    assert.is_truthy(replied()[1]:find("agent replied on fx-2: Answer for two", 1, true), replied()[1])
  end)

  it("replies within notify_group_ms give one grouped notification", function()
    require("beads").setup({ notify_group_ms = 1500 })
    ask_thread("fx-1", "Is it safe?")
    ask_thread("fx-2", "Other bead?")
    answered_thread("fx-2")
    open_detail("Is it safe?")
    notes = fake.capture_notify()
    agent_reply("t1", "First answer")
    sleep(400)
    agent_reply("t2", "Second answer")
    fake.wait_for(function()
      return #replied() >= 1
    end, "an 'agent replied' notification", 3000)
    sleep(1000)
    local got = replied()
    assert.are.equal(1, #got, table.concat(got, "\n---\n"))
    assert.is_truthy(got[1]:find("Beads: agent replied", 1, true), got[1])
    assert.is_truthy(got[1]:find("fx-1", 1, true), got[1])
    assert.is_truthy(got[1]:find("fx-2", 1, true), got[1])
    no_old(got)
  end)

  it("notify = false gives no notification but still refreshes the buffer", function()
    require("beads").setup({ notify = false, notify_group_ms = 200 })
    ask_thread("fx-1", "Is it safe?")
    local buf = open_detail("Is it safe?")
    notes = fake.capture_notify()
    agent_reply("t1", "Quiet answer")
    fake.wait_for(function()
      return fake.question_line(buf, "[you] Is it safe?") ~= nil
    end, "Questions section refreshed", WITHIN_MS)
    sleep(800)
    assert.are.same({}, replied())
  end)

  -- passes already: guards that the plugin's own writes (a reply from the thread float) notify nothing
  it("the plugin's own write gives no 'agent replied' notification", function()
    require("beads").setup({ notify_group_ms = 200 })
    store.add(fake.dir(), { bead = "fx-1", messages = { { author = "agent", body = "Which one?" } } })
    local buf = fake.open_detail()
    fake.wait_question(buf, "[you] Which one?")
    sleep(300)
    notes = fake.capture_notify()
    fake.open_thread(buf, "Which one?")
    assert.is_true(fake.reply("my own answer"))
    fake.wait_for(function()
      local t = store.get(fake.dir(), "t1")
      return t and #t.messages == 2
    end, "own reply stored")
    sleep(1000)
    assert.are.same({}, replied())
  end)
end)
