-- Bead beads_nvim-r6s, review findings:
--   1. (blocker, progress.lua:78) a question stuck on "sent" is polled forever: after a timeout
--      polling stops, the spinner timer stops and the stage line still says "sent" (no spinner).
--   2. (blocker, progress.lua:144) an entry registered without an id (poke returned false, nil)
--      expires after a short time: a later AgentPokeProgress event on the same root is not
--      claimed by it, and a late "failed" event does not overwrite the " register.
--   3. (nit, progress.lua:216) the table of entries is capped: old final entries are dropped.
--   4. (nit, detail.lua:706) the detail winbar spinner is redrawn while the cursor is in another
--      window (the thread float): the tick uses a redraw that covers every window's winbar
--      (":redrawstatus!", ":redraw", or nvim__redraw for winbars of all windows / the detail window).
--   5. (nit, thread.lua:84) on a very narrow editor the thread float is not wider than the editor.
-- agent-poke is the fake of tests/poke_progress_fake.lua.
--
-- assumption: the limits are plain fields of require("beads.progress"), read when checked (not
--   copied at load), in milliseconds / entries:
--     sent_timeout_ms (default 120000): a "sent" stage older than this stops being polled/spun
--     unclaimed_ms    (default 10000):  an id-less entry claims root events only this long
--     max_entries     (default 50):     at most this many entries are kept, oldest dropped first
--   the tests lower the timeouts and restore them; the cap test relies on the default (< 55).
-- assumption: after the sent timeout the float keeps a stage line containing "sent".
-- assumption: "no spinner" in the detail view = its winbar text stops changing.
-- assumption: the cap drops the oldest entries; whether active entries may be evicted is not tested.
-- assumption: (4) is checked by spying the redraw API calls, not the screen: in headless nvim the
--   detail winbar row on screen already animates with a plain :redrawstatus from the float.
-- assumption: narrow editor = 20 columns; float width plus its border cells <= vim.o.columns.

local fake = require("tests.questions_fake")
local poke = require("tests.poke_progress_fake")
local store = require("beads.questions.store")

local REPLYING = "agent is replying…"
local FAILED = 'no agent picked it up — prompt in " register'

local function lines(w)
  return poke.display_lines(vim.api.nvim_win_get_buf(w))
end

local function dump(w)
  return table.concat(lines(w), "\n")
end

local function find(w, s)
  local ls = lines(w)
  for i = #ls, 1, -1 do
    if ls[i]:find(s, 1, true) then
      return i, ls[i]
    end
  end
end

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

local function open_thread()
  local t = store.add(fake.dir(), { bead = "fx-1", messages = { { author = "agent", body = "Which database?" } } })
  local buf = fake.open_detail()
  fake.open_thread(buf, "Which database?")
  return buf, t
end

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

local function winbar(buf)
  local win = vim.fn.bufwinid(buf)
  return ((require("beads.views.detail").winbar(win) or ""):gsub("%%#[^#]*#", ""))
end

describe("poke progress (review findings)", function()
  local progress = require("beads.progress")
  local saved, base, cols, rows

  before_each(function()
    saved = {
      sent_timeout_ms = progress.sent_timeout_ms,
      unclaimed_ms = progress.unclaimed_ms,
      max_entries = progress.max_entries,
    }
    cols, rows = vim.o.columns, vim.o.lines
    fake.setup()
    require("beads").setup({})
  end)

  after_each(function()
    fake.teardown()
    poke.uninstall()
    progress.sent_timeout_ms = saved.sent_timeout_ms
    progress.unclaimed_ms = saved.unclaimed_ms
    progress.max_entries = saved.max_entries
    vim.o.columns, vim.o.lines = cols, rows
  end)

  local function baseline()
    poke.sleep(500)
    base = poke.timers_now()
  end

  it("a question stuck on 'sent' stops being polled and spun after the timeout, still saying 'sent'", function()
    progress.sent_timeout_ms = 1000
    poke.install({ status = "typed", id = "s1", stage = "sent", target = "Agent one" })
    local buf = open_thread()
    baseline()
    local w = send_reply("Use sqlite")
    wait_stage(w, "sent to Agent one", "Use sqlite")
    -- past the timeout, with the float and the detail view still open
    poke.sleep(1500)
    local ok = vim.wait(3000, function()
      return poke.active_timers() <= base
    end, 20)
    assert(ok, ("timers still running after the sent timeout: %d active, %d before"):format(poke.timers_now(), base))
    local c = poke.calls("s1")
    poke.sleep(2500) -- longer than the ~2 s poll period
    assert.are.equal(c, poke.calls("s1"), "progress('s1') still polled after the sent timeout")
    assert.is_true(vim.api.nvim_win_is_valid(w), "the thread float closed")
    local _, l = find(w, "sent")
    assert.is_truthy(l, "no 'sent' stage line after the timeout:\n" .. dump(w))
    assert.is_falsy(dump(w):find(REPLYING, 1, true), dump(w))
    -- the detail winbar shows no spinner any more (it stops changing)
    local first, changed = winbar(buf), false
    vim.wait(1000, function()
      changed = winbar(buf) ~= first
      return changed
    end, 20)
    assert.is_false(changed, "the detail winbar still animates after the sent timeout: " .. first)
  end)

  it("an id-less entry expires: a later event on the same root is not claimed", function()
    progress.unclaimed_ms = 300
    poke.install({ status = false, id = nil })
    open_thread()
    local w = send_reply("Use sqlite")
    fake.wait_for(function()
      return find(w, "Use sqlite") ~= nil
    end, "the reply in the float")
    poke.sleep(800)
    local root = poke.pokes()[1].root
    poke.fire("late", root, "sent", "Other agent")
    poke.fire("late", root, "working", "Other agent")
    poke.sleep(400)
    local text = dump(w)
    assert.is_falsy(text:find("sent to Other agent", 1, true), "an expired entry claimed the event:\n" .. text)
    assert.is_falsy(text:find(REPLYING, 1, true), "an expired entry claimed the event:\n" .. text)
  end)

  it("a late 'failed' event for an expired id-less entry leaves the \" register alone", function()
    progress.unclaimed_ms = 300
    poke.install({ status = false, id = nil })
    open_thread()
    local w = send_reply("Use sqlite")
    fake.wait_for(function()
      return find(w, "Use sqlite") ~= nil
    end, "the reply in the float")
    poke.sleep(800)
    vim.fn.setreg('"', "mine")
    poke.fire("late2", poke.pokes()[1].root, "failed", "Other agent", "boom")
    poke.sleep(400)
    assert.are.equal("mine", vim.fn.getreg('"'), "the \" register was overwritten by an expired entry")
    assert.is_falsy(dump(w):find(FAILED, 1, true), "an expired entry shows the failure:\n" .. dump(w))
  end)

  it("the entries table is capped: the oldest failed entries are dropped", function()
    poke.install({ status = "started", id = "unused", stage = "working" })
    local root = fake.dir()
    for i = 1, 55 do
      progress.add({ root = root, bead = "b" .. i, thread = "t" .. i, id = "x" .. i, prompt = "q" .. i })
      poke.fire("x" .. i, root, "failed", nil, "boom")
    end
    assert.are.equal(FAILED, progress.stage_text(root, "b55", "t55"))
    assert.is_nil(progress.stage_text(root, "b1", "t1"), "the oldest of 55 failed entries is still kept")
  end)

  it("the detail winbar spinner is redrawn for all windows while the cursor is in the thread float", function()
    -- "queued": the float's own stage line is static, the detail winbar still spins
    poke.install({ status = "queued", id = "wb1", stage = "queued" })
    local buf = open_thread()
    local w = send_reply("Use sqlite")
    wait_stage(w, "queued", "Use sqlite")
    vim.api.nvim_set_current_win(w)
    local dwin = vim.fn.bufwinid(buf)
    assert.are_not.equal(-1, dwin)
    assert.is_truthy(winbar(buf):find("💬", 1, true), "the detail winbar shows no spinner: " .. winbar(buf))
    -- Spy on the redraw calls made while the spinner ticks (passed through to nvim).
    local api = vim.api
    local orig = { cmd = api.nvim_cmd, exec2 = api.nvim_exec2, command = api.nvim_command, redraw = api.nvim__redraw }
    local all, seen = false, {}
    local function str(s)
      s = vim.trim(tostring(s or ""))
      seen[#seen + 1] = s
      -- ":redrawstatus!" / ":redraw" / ":redraw!" redraw every window's winbar
      if s:match("^redraws?t?a?t?u?s?!") or s:match("^redraw!?$") then
        all = true
      end
    end
    api.nvim_cmd = function(c, o)
      if type(c) == "table" then
        seen[#seen + 1] = vim.inspect(c)
        if (c.cmd == "redrawstatus" and c.bang) or c.cmd == "redraw" then
          all = true
        end
      end
      return orig.cmd(c, o or {})
    end
    api.nvim_exec2 = function(s, o)
      str(s)
      return orig.exec2(s, o or {})
    end
    api.nvim_command = function(s)
      str(s)
      return orig.command(s)
    end
    if orig.redraw then
      api.nvim__redraw = function(o)
        seen[#seen + 1] = vim.inspect(o)
        if type(o) == "table" and (o.winbar or o.statusline or o.valid == false) and (o.win == nil or o.win == dwin) then
          all = true
        end
        return orig.redraw(o)
      end
    end
    local ok, err = pcall(poke.sleep, 800)
    api.nvim_cmd, api.nvim_exec2, api.nvim_command, api.nvim__redraw = orig.cmd, orig.exec2, orig.command, orig.redraw
    assert(ok, err)
    assert.is_true(
      all,
      "no redraw of other windows' winbars while the spinner ticks; calls seen: " .. table.concat(seen, " | ")
    )
  end)

  it("on a 20-column editor the thread float is not wider than the editor", function()
    poke.install_missing()
    vim.o.columns = 20
    local t = store.add(fake.dir(), { bead = "fx-1", messages = { { author = "agent", body = "Which database?" } } })
    assert.is_truthy(t)
    local buf = fake.open_detail()
    local f = fake.open_thread(buf, "Which database?")
    local c = vim.api.nvim_win_get_config(f)
    local b = 0
    if type(c.border) == "table" then
      local left, right = c.border[8] or c.border[4], c.border[4]
      if #c.border == 8 then
        left, right = c.border[8], c.border[4]
      elseif #c.border == 4 then
        left, right = c.border[4], c.border[2]
      elseif #c.border == 2 then
        left, right = c.border[2], c.border[2]
      elseif #c.border == 1 then
        left, right = c.border[1], c.border[1]
      end
      local function w(x)
        x = type(x) == "table" and x[1] or x
        return (x and x ~= "") and 1 or 0
      end
      b = w(left) + w(right)
    elseif c.border and c.border ~= "none" then
      b = 2
    end
    assert.is_true(c.width >= 1, "float width " .. tostring(c.width))
    assert.is_true(
      c.width + b <= vim.o.columns,
      ("float width %d + border %d is wider than the %d-column editor"):format(c.width, b, vim.o.columns)
    )
  end)
end)
