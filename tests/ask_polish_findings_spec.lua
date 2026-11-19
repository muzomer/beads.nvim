-- Bead beads_nvim-y5w, review findings (tests/ask_polish_spec.lua is frozen; this adds to it).
-- Interface under test:
--   * Thread float reply box (r) on a human-flagged thread: <M-s> calls human.answer (bd update
--     --append-notes, bd label remove ... human) and then pokes the agent through
--     require("agent-poke").poke (owner decision 2026-11-19).
--   * Reply box on a stored thread: <M-s> does not poke when qstore.reply stored nothing (thread gone).
--   * require("beads.questions.store").readable(root) is false for valid JSON that load() rejects
--     (an object that is neither a thread list nor has a `threads` list) and for an empty file,
--     so the questions watcher keeps its snapshot.
-- agent-poke is stubbed through package.preload. bd is a fake on PATH (tests/questions_fake.lua).
--
-- assumption: the human-thread poke prompt contains the reply text and the bead id.
-- assumption: the poke on a human thread happens only after human.answer finished (label removed).
-- assumption: an empty questions.json counts as a bad read (readable() false), per the reviewer nit.

local fake = require("tests.questions_fake")
local store = require("beads.questions.store")

local pokes

local function stub_poke()
  package.loaded["agent-poke"] = nil
  package.preload["agent-poke"] = function()
    return {
      poke = function(root, prompt, opts)
        pokes[#pokes + 1] = { root = root, prompt = prompt, opts = opts, calls = #fake.log() }
      end,
    }
  end
end

local function sleep(ms)
  vim.wait(ms, function()
    return false
  end, 10)
end

local function qpath()
  return fake.dir() .. "/.beads-nvim/questions.json"
end

local function write_raw(s)
  vim.fn.mkdir(fake.dir() .. "/.beads-nvim", "p")
  local tmp = qpath() .. ".test.tmp"
  local f = assert(io.open(tmp, "w"))
  f:write(s)
  f:close()
  assert(vim.uv.fs_rename(tmp, qpath()))
end

describe("beads reply box <M-s> (findings)", function()
  before_each(function()
    fake.setup()
    pokes = {}
    stub_poke()
    vim.ui.input = function(_, cb)
      cb(nil)
    end
    require("beads").setup({ ask = { open_after_send = false } })
  end)

  after_each(function()
    package.preload["agent-poke"] = nil
    package.loaded["agent-poke"] = nil
    fake.teardown()
    require("beads").setup({})
  end)

  it("<M-s> on a human-flagged thread answers it and then pokes the agent", function()
    fake.write_human({ fake.bead({ notes = "earlier note\nShould we use sqlite?", labels = { "human" } }) })
    local buf = fake.open_detail()
    fake.open_thread(buf, "Should we use sqlite?")
    local f = fake.press_for_float("r")
    assert(f ~= nil, "r in the human thread float opened no reply box")
    vim.api.nvim_set_current_win(f)
    pcall(vim.cmd, "stopinsert")
    local b = vim.api.nvim_win_get_buf(f)
    assert.is_not_nil(fake.buf_map(b, "n", "<M-s>"), "no normal-mode <M-s> map in the reply box")
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "yes use sqlite" })
    fake.press("<M-s>")
    fake.wait_for(function()
      return fake.count("label remove fx-1 human") >= 1
    end, "bd label remove fx-1 human after <M-s>")
    assert.is_true(fake.count("--append-notes yes use sqlite") >= 1, "note not appended")
    fake.wait_for(function()
      return #pokes == 1
    end, "agent poked after <M-s> on a human thread", 1500)
    assert.are.equal(fake.dir(), pokes[1].root)
    assert.is_truthy(pokes[1].prompt:find("yes use sqlite", 1, true), "prompt lacks the reply:\n" .. pokes[1].prompt)
    assert.is_truthy(pokes[1].prompt:find("fx-1", 1, true), "prompt lacks the bead id:\n" .. pokes[1].prompt)
    -- the poke comes after the answer was recorded (label removed)
    local removed_at
    for i, l in ipairs(fake.log()) do
      if l:find("label remove fx-1 human", 1, true) then
        removed_at = i
      end
    end
    assert.is_true(pokes[1].calls >= removed_at, "agent poked before human.answer finished")
  end)

  it("<M-s> does not poke when the thread is gone and the reply was not stored", function()
    store.add(fake.dir(), { bead = "fx-1", messages = { { author = "agent", body = "Which one?" } } })
    local buf = fake.open_detail()
    fake.open_thread(buf, "Which one?")
    local f = fake.press_for_float("r")
    assert(f ~= nil, "r in the thread float opened no reply box")
    vim.api.nvim_set_current_win(f)
    pcall(vim.cmd, "stopinsert")
    local b = vim.api.nvim_win_get_buf(f)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "orphan reply" })
    -- the thread disappears while the reply box is open
    write_raw("[]")
    assert.is_nil(store.get(fake.dir(), "t1"))
    assert(vim.api.nvim_win_is_valid(f), "reply box closed before submit")
    vim.api.nvim_set_current_win(f)
    fake.press("<M-s>")
    sleep(500)
    assert.is_nil(store.get(fake.dir(), "t1"), "reply recreated the thread")
    assert.are.equal(0, #pokes, "agent poked about a reply that was not stored: " .. (pokes[1] and pokes[1].prompt or ""))
  end)
end)

describe("beads questions store readable() (findings)", function()
  before_each(function()
    fake.setup()
  end)

  after_each(function()
    fake.teardown()
  end)

  it("is false for a JSON object that is neither a thread list nor has a threads list", function()
    write_raw('{"foo": 1, "bar": [1, 2]}')
    assert.is_false(store.readable(fake.dir()))
  end)

  it("is false for a JSON object whose threads field is not a list", function()
    write_raw('{"threads": {"a": 1}}')
    assert.is_false(store.readable(fake.dir()))
  end)

  it("is false for an empty questions.json", function()
    write_raw("")
    assert.is_false(store.readable(fake.dir()))
  end)

  -- passes already: guards that good shapes and a missing file still count as readable.
  it("is true for a missing file, a thread list, an empty list and a threads object", function()
    assert.is_true(store.readable(fake.dir()))
    write_raw("[]")
    assert.is_true(store.readable(fake.dir()))
    write_raw('[{"id":"t1","bead":"fx-1","messages":[]}]')
    assert.is_true(store.readable(fake.dir()))
    write_raw('{"threads":[{"id":"t1","bead":"fx-1","messages":[]}]}')
    assert.is_true(store.readable(fake.dir()))
  end)
end)

describe("beads questions watcher with a wrong-shape or empty questions.json (findings)", function()
  local notes

  local function replied()
    local out = {}
    for _, n in ipairs(notes) do
      if n.msg:find("agent replied", 1, true) then
        out[#out + 1] = n.msg
      end
    end
    return out
  end

  local function with_new_reply(good, body)
    local data = vim.json.decode(good)
    local list = data.threads or data
    for _, t in ipairs(list) do
      if t.id == "t1" then
        t.messages[#t.messages + 1] = { author = "agent", body = body }
      end
    end
    return vim.json.encode(data)
  end

  local function setup_answered()
    require("beads").setup({ notify_group_ms = 200 })
    store.add(fake.dir(), {
      bead = "fx-1",
      messages = { { author = "user", body = "Old question" }, { author = "agent", body = "Old reply" } },
    })
    local buf = fake.open_detail()
    fake.wait_question(buf, "Old question")
    sleep(400)
    notes = fake.capture_notify()
    local f = assert(io.open(qpath(), "r"))
    local good = f:read("*a")
    f:close()
    return good
  end

  local function check_only_new()
    fake.wait_for(function()
      return #replied() >= 1
    end, "an 'agent replied' notification", 2000)
    sleep(600)
    local got = replied()
    assert.are.equal(1, #got, table.concat(got, "\n---\n"))
    assert.is_truthy(got[1]:find("New reply", 1, true), got[1])
    assert.is_falsy(got[1]:find("Old reply", 1, true), "an earlier agent reply was announced again: " .. got[1])
  end

  before_each(function()
    fake.setup()
  end)

  after_each(function()
    fake.teardown()
    require("beads").setup({})
  end)

  it("a wrong-shape JSON read keeps the snapshot; the next good read announces only the new reply", function()
    local good = setup_answered()
    write_raw('{"foo": 1}')
    sleep(700)
    assert.are.same({}, replied())
    write_raw(with_new_reply(good, "New reply"))
    check_only_new()
  end)

  it("an empty-file read keeps the snapshot; the next good read announces only the new reply", function()
    local good = setup_answered()
    write_raw("")
    sleep(700)
    assert.are.same({}, replied())
    write_raw(with_new_reply(good, "New reply"))
    check_only_new()
  end)
end)
