-- Bead beads_nvim-r6s: each question shows its agent-poke stage in the thread float.
-- Interface under test (black box): a question sent with <M-s> (detail `a` ask, thread float `r`
-- reply) goes to a fake agent-poke (tests/poke_progress_fake.lua, real progress API: poke returns
-- status, id; progress(id); User autocmd AgentPokeProgress { id, root, stage, target }). The thread
-- float shows one stage line under the last message:
--   sent     -> "sent to <target>"  (just "sent", no " to ", when there is no target title)
--   queued   -> "queued"
--   working  -> "agent is replying…" (U+2026) with an animated spinner on the same line
--   failed   -> 'no agent picked it up — prompt in " register' (em dash), and the prompt is in "
-- The line disappears when the agent's reply arrives. While "sent", progress(id) is polled (~2s).
-- A poke that returned false, nil (picker opened first) is matched by the autocmd's root.
-- Without agent-poke there is no stage line and the fallback message stays as today.
-- Timers stop when the float (and the detail view) close or the reply arrives.
--
-- assumption: the stage line is read from the float's displayed lines (buffer text plus extmark
--   virt_text/virt_lines); it comes after the line holding the last message's body.
-- assumption: "animated" = the stage line's displayed text changes within 2 s; frames not pinned.
-- assumption: <target title> is data.target as agent-poke reports it (a string).
-- assumption: on failure beads puts the prompt into the " register (so the message is true).
-- assumption: the spinner/poll timers stop when the float closes and the detail view is gone;
--   with only the float closed the detail view may still show its own waiting state.

local fake = require("tests.questions_fake")
local poke = require("tests.poke_progress_fake")
local store = require("beads.questions.store")

local REPLYING = "agent is replying…"
local FAILED = 'no agent picked it up — prompt in " register'

local function lines(w)
  return poke.display_lines(vim.api.nvim_win_get_buf(w))
end

-- Index of the last displayed line containing s, or nil.
local function find(w, s)
  local ls = lines(w)
  for i = #ls, 1, -1 do
    if ls[i]:find(s, 1, true) then
      return i, ls[i]
    end
  end
end

local function dump(w)
  return table.concat(lines(w), "\n")
end

-- Waits until the float shows a line containing `stage_text` after the line with `last`.
local function wait_stage(w, stage_text, last, timeout)
  local ok = vim.wait(timeout or 3000, function()
    if not vim.api.nvim_win_is_valid(w) then
      return false
    end
    local s, m = find(w, stage_text), find(w, last)
    return s ~= nil and m ~= nil and s > m
  end, 10)
  assert(vim.api.nvim_win_is_valid(w), "the thread float closed")
  assert(ok, ("no '%s' line under '%s' in the float:\n%s"):format(stage_text, last, dump(w)))
  local _, l = find(w, stage_text)
  return l
end

local function no_stage(w)
  local text = dump(w)
  for _, s in ipairs({ REPLYING, "queued", "sent to", FAILED }) do
    assert.is_falsy(text:find(s, 1, true), "the float still shows '" .. s .. "':\n" .. text)
  end
end

local function wait_no_stage(w)
  vim.wait(3000, function()
    local text = dump(w)
    return not (text:find(REPLYING, 1, true) or text:find("queued", 1, true) or text:find("sent to", 1, true))
  end, 10)
  no_stage(w)
end

-- The stage line animates: its text changes within 2 s.
local function assert_animated(w)
  local seen, n = {}, 0
  vim.wait(2000, function()
    local _, l = find(w, REPLYING)
    if l and not seen[l] then
      seen[l] = true
      n = n + 1
    end
    return n >= 2
  end, 20)
  assert.is_true(n >= 2, "the '" .. REPLYING .. "' line does not animate:\n" .. dump(w))
end

-- An agent writes its reply through bin/beads-ask in another process.
local function agent_reply(tid, body)
  local r = vim
    .system({ fake.repo .. "/bin/beads-ask", "reply", tid, body }, {
      env = { BEADS_NVIM_ROOT = fake.dir(), BEADS_NVIM_NVIM = vim.v.progpath },
      text = true,
    })
    :wait(10000)
  assert.are.equal(0, r.code, "beads-ask reply failed: " .. tostring(r.stderr))
end

-- Stores a thread from the agent, opens beads://fx-1 and its thread float.
local function open_thread()
  local t = store.add(fake.dir(), { bead = "fx-1", messages = { { author = "agent", body = "Which database?" } } })
  local buf = fake.open_detail()
  fake.open_thread(buf, "Which database?")
  return buf, t
end

-- Presses r in the thread float, types text and sends it with <M-s>; returns the thread float.
local function send_reply(text)
  vim.ui.input = function(_, cb)
    cb(nil)
  end
  local f = fake.press_for_float("r")
  assert(f ~= nil, "r opened no reply box")
  vim.api.nvim_set_current_win(f)
  vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(f), 0, -1, false, { text })
  fake.press("<M-s>")
  fake.wait_for(function()
    return #poke.pokes() == 1
  end, "agent-poke.poke called")
  local w
  fake.wait_for(function()
    w = poke.thread_float()
    return w ~= nil
  end, "the thread float")
  return w
end

-- Asks with detail `a` and <M-s>; returns the thread float opened after sending.
local function ask(buf, text)
  vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
  vim.ui.input = function(_, cb)
    cb(nil)
  end
  local f = fake.press_for_float("a")
  assert(f ~= nil, "a opened no ask box")
  vim.api.nvim_set_current_win(f)
  vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(f), 0, -1, false, { text })
  fake.press("<M-s>")
  local w
  fake.wait_for(function()
    w = poke.thread_float()
    return w ~= nil
  end, "the thread float after asking")
  return w
end

describe("thread float stage line", function()
  local base

  before_each(function()
    fake.setup()
    require("beads").setup({})
  end)

  after_each(function()
    fake.teardown()
    poke.uninstall()
  end)

  -- Active timers once the detail view has settled (watchers, debounce).
  local function baseline()
    poke.sleep(500)
    base = poke.timers_now()
  end

  local function wait_timers_settle(what)
    local ok = vim.wait(3000, function()
      return poke.active_timers() <= base
    end, 20)
    assert(ok, ("timers still running after %s: %d active, %d before"):format(what, poke.timers_now(), base))
  end

  it("ask: queued, then the spinner with 'agent is replying…', gone when the reply arrives", function()
    poke.install({ status = "queued", id = "p1", stage = "queued" })
    local buf = fake.open_detail()
    local w = ask(buf, "Where does it go?")
    wait_stage(w, "queued", "Where does it go?")
    local root = poke.pokes()[1].root
    poke.fire("p1", root, "working", "background")
    local l = wait_stage(w, REPLYING, "Where does it go?")
    assert.is_falsy(dump(w):find("queued", 1, true), "queued line left behind:\n" .. dump(w))
    assert.is_truthy(l, l)
    assert_animated(w)
    local tid = store.list(fake.dir(), { bead = "fx-1" })[1].id
    agent_reply(tid, "It goes in lib")
    fake.wait_for(function()
      return find(w, "It goes in lib") ~= nil
    end, "the reply in the float")
    wait_no_stage(w)
  end)

  it("reply: 'sent to <target>' under the last message, polled until progress says working", function()
    poke.install({ status = "typed", id = "p2", stage = "sent", target = "Agent one" })
    open_thread()
    local w = send_reply("Use sqlite")
    wait_stage(w, "sent to Agent one", "Use sqlite")
    fake.wait_for(function()
      return poke.calls("p2") >= 2
    end, "progress('p2') polled twice while sent", 6000)
    poke.set_polled("p2", "working")
    wait_stage(w, REPLYING, "Use sqlite", 4000)
    assert.is_falsy(dump(w):find("sent to", 1, true), "sent line left behind:\n" .. dump(w))
  end)

  it("sent without a target title shows 'sent' and no ' to '", function()
    poke.install({ status = "typed", id = "p3", stage = "sent" })
    open_thread()
    local w = send_reply("Use sqlite")
    local l = wait_stage(w, "sent", "Use sqlite")
    assert.is_falsy(l:find("sent to", 1, true), "stage line names a target: " .. l)
  end)

  it("failed: 'no agent picked it up — prompt in \" register' and the prompt is in \"", function()
    poke.install({ status = false, id = "p4", stage = "failed", err = "boom" })
    open_thread()
    vim.fn.setreg('"', "")
    local w = send_reply("Use sqlite")
    wait_stage(w, FAILED, "Use sqlite")
    assert.is_truthy(vim.fn.getreg('"'):find("Use sqlite", 1, true), "prompt not in \": " .. vim.fn.getreg('"'))
    assert.is_falsy(dump(w):find(REPLYING, 1, true), dump(w))
  end)

  it("failed after working replaces the spinner with the failure text", function()
    poke.install({ status = "started", id = "p5", stage = "working", target = "background" })
    open_thread()
    local w = send_reply("Use sqlite")
    wait_stage(w, REPLYING, "Use sqlite")
    poke.fire("p5", poke.pokes()[1].root, "failed", "background", "stopped")
    wait_stage(w, FAILED, "Use sqlite")
    assert.is_falsy(dump(w):find(REPLYING, 1, true), "spinner left behind:\n" .. dump(w))
    assert.is_truthy(vim.fn.getreg('"'):find("Use sqlite", 1, true), "prompt not in \": " .. vim.fn.getreg('"'))
  end)

  it("a poke that returned false, nil (picker first) is attached by the event's root", function()
    poke.install({ status = false, id = nil })
    open_thread()
    local w = send_reply("Use sqlite")
    poke.sleep(200)
    local root = poke.pokes()[1].root
    poke.fire("p6", root, "sent", "Agent two")
    wait_stage(w, "sent to Agent two", "Use sqlite")
    poke.fire("p6", root, "working", "Agent two")
    wait_stage(w, REPLYING, "Use sqlite")
  end)

  it("an event of an unknown id on another root changes nothing", function()
    poke.install({ status = "queued", id = "p7", stage = "queued" })
    open_thread()
    local w = send_reply("Use sqlite")
    wait_stage(w, "queued", "Use sqlite")
    poke.fire("zz", "/nonexistent/other/root", "working", "background")
    poke.sleep(300)
    assert.is_falsy(dump(w):find(REPLYING, 1, true), "another root's event shows here:\n" .. dump(w))
    assert.is_truthy(find(w, "queued"), dump(w))
  end)

  it("the spinner and polling stop when the float and detail view close", function()
    poke.install({ status = "typed", id = "p8", stage = "sent", target = "Agent one" })
    local buf = open_thread()
    baseline()
    local w = send_reply("Use sqlite")
    wait_stage(w, "sent to Agent one", "Use sqlite")
    poke.set_polled("p8", "working")
    wait_stage(w, REPLYING, "Use sqlite", 4000)
    vim.api.nvim_win_close(w, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    wait_timers_settle("closing the float and the detail view")
    local c = poke.calls("p8")
    poke.sleep(2500)
    assert.are.equal(c, poke.calls("p8"), "progress() still polled after the float closed")
    assert.is_true(poke.timers_now() <= base, "a timer came back")
  end)

  it("the spinner timer stops when the reply arrives (float still open)", function()
    poke.install({ status = "started", id = "p9", stage = "working", target = "background" })
    local _, t = open_thread()
    baseline()
    local w = send_reply("Use sqlite")
    wait_stage(w, REPLYING, "Use sqlite")
    agent_reply(t.id, "Fine by me")
    fake.wait_for(function()
      return find(w, "Fine by me") ~= nil
    end, "the reply in the float")
    wait_no_stage(w)
    wait_timers_settle("the reply arrived")
  end)

  it("without agent-poke: no stage line, no spinner, no error, fallback message as today", function()
    poke.install_missing()
    open_thread()
    baseline()
    local notes = fake.capture_notify()
    vim.ui.input = function(_, cb)
      cb(nil)
    end
    local f = fake.press_for_float("r")
    assert(f ~= nil, "r opened no reply box")
    vim.api.nvim_set_current_win(f)
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(f), 0, -1, false, { "Use sqlite" })
    fake.press("<M-s>")
    fake.wait_for(function()
      for _, n in ipairs(notes) do
        if n.msg:find("agent-poke is not available", 1, true) then
          return true
        end
      end
    end, "the fallback message")
    local w
    fake.wait_for(function()
      w = poke.thread_float()
      return w ~= nil
    end, "the thread float")
    fake.wait_for(function()
      return find(w, "Use sqlite") ~= nil
    end, "the reply in the float")
    local before = dump(w)
    poke.sleep(1000)
    no_stage(w)
    assert.are.equal(before, dump(w), "the float changes on its own (a spinner?)")
    for _, n in ipairs(notes) do
      assert.are_not.equal(vim.log.levels.ERROR, n.level, "error: " .. n.msg)
      assert.is_truthy(n.msg:find("^Beads: "), "message without 'Beads: ': " .. n.msg)
    end
    wait_timers_settle("a send without agent-poke")
  end)
end)
