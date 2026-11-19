-- Bead beads_nvim-ezh, review findings: the peek float's detail keys.
--   blocker peek.lua:231  a float's reload must fire User BeadsThreadsRefreshed (as
--                         detail.refresh_threads does), so an open thread float repaints with the
--                         agent's answer and the progress waiting spinner clears.
--   nit thread.lua:241    apply in a thread opened from a peek float: read-only checked before the
--                         confirm prompt (no prompt, a 'Beads: ' read-only message, thread stays open).
--   nit peek.lua:214      ]b / [b onto a bead already shown in another stacked float focuses that
--                         float instead of leaving two floats for one bead.
--   nit peek.lua:183      e / i: EDIT mode only once the main window's detail buffer has loaded, so
--                         typed text is never overwritten by the late load.
--   nit keys.lua:73       the peek help lists <CR> once.
-- Fixture and fake bd: tests/peek_fake.lua; agent-poke: tests/poke_progress_fake.lua.
-- assumption: the agent's answer reaches beads through questions.json (written in-process with
--   questions.store.reply), picked up by the root watcher a peek float holds.
-- assumption: for ]b / [b only "one float per bead, focus on it" is pinned, not whether the float
--   ]b was pressed in closes or keeps its old bead.
-- assumption: the help's <CR> count is taken in its first (peek) section, as a key token.

local fake = require("tests.peek_fake")
local poke = require("tests.poke_progress_fake")
local qstore = require("beads.questions.store")

local REPLYING = "agent is replying…"

local function settle(ms)
  vim.wait(ms or 200, function()
    return false
  end, 10)
end

local function try_press(win, keys)
  local ok, err = pcall(fake.press, win, keys)
  pcall(vim.cmd, "stopinsert")
  return ok, err
end

local function snapshot_wins()
  local t = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    t[w] = true
  end
  return t
end

local function wait_new_float(before, what)
  local w
  vim.wait(3000, function()
    for _, x in ipairs(fake.floats()) do
      if not before[x] then
        w = x
        return true
      end
    end
    return false
  end, 10)
  assert(w, what .. " opened no float; floats: " .. fake.describe_floats())
  return w
end

local function row_of_line(win, line)
  for i, l in ipairs(fake.lines_of(win)) do
    if l == line then
      return i
    end
  end
end

local function wait_text(win, text, what)
  assert(vim.wait(3000, function()
    return vim.api.nvim_win_is_valid(win) and fake.text_of(win):find(text, 1, true) ~= nil
  end, 10), what .. ": window never showed " .. text .. ":\n" .. fake.text_of(win))
end

local function peek_c3z()
  local main = vim.api.nvim_get_current_win()
  fake.edit_in(main, "pk-b2y")
  fake.cursor_on(main, "pk-c3z", 2)
  local f = fake.peek(main, "gd", "pk-c3z")
  return main, f
end

-- Opens the thread float of the first question of the peek float f.
local function open_thread(f, text)
  wait_text(f, text, "questions")
  local h = row_of_line(f, "## Questions")
  assert(h, "no ## Questions in the float:\n" .. fake.text_of(f))
  vim.api.nvim_win_set_cursor(f, { h + 1, 0 })
  local before = snapshot_wins()
  try_press(f, "<CR>")
  local tf = wait_new_float(before, "<CR> on a question")
  assert.is_truthy((fake.lines_of(tf)[1] or ""):find("^Thread "), "not a thread float:\n" .. fake.text_of(tf))
  return tf
end

describe("peek float detail keys (review findings)", function()
  local orig_select

  before_each(function()
    fake.setup({})
    orig_select = vim.ui.select
  end)

  after_each(function()
    vim.ui.select = orig_select
    fake.teardown()
    poke.uninstall()
  end)

  it("an agent answer refreshes a thread opened from a peek float and clears the waiting spinner", function()
    poke.install({ status = "queued", id = "p1", stage = "queued" })
    local root = fake.root()
    local t = qstore.add(root, {
      bead = "pk-c3z",
      section = "description",
      messages = { { author = "agent", body = "Which database?" } },
    })
    local _, f = peek_c3z()
    local tf = open_thread(f, "Which database?")
    -- reply from the thread float and send it to the (fake) agent
    local before = snapshot_wins()
    try_press(tf, "r")
    local rf = wait_new_float(before, "r in the thread float")
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(rf), 0, -1, false, { "Use sqlite" })
    fake.press(rf, "<M-s>")
    pcall(vim.cmd, "stopinsert")
    assert(vim.wait(3000, function()
      return #poke.pokes() == 1
    end, 10), "agent-poke.poke was not called")
    wait_text(tf, "Use sqlite", "thread float after the reply")
    poke.fire("p1", root, "working", "background")
    wait_text(tf, REPLYING, "thread float while the agent works")
    assert.is_not_nil(require("beads.progress").waiting(root, "pk-c3z"), "no waiting state before the answer")
    -- the agent answers: questions.json changes, the watcher refreshes the open detail views
    qstore.reply(root, t.id, "agent", "Sqlite it is")
    -- the float itself reloaded (its bead snapshot carries the answer)
    local fbuf = vim.api.nvim_win_get_buf(f)
    local function float_has_answer()
      local snap = require("beads.views.detail").snapshot(fbuf)
      for _, th in ipairs(snap and snap.threads or {}) do
        for _, m in ipairs(th.messages or {}) do
          if m.body == "Sqlite it is" then
            return true
          end
        end
      end
      return false
    end
    assert(vim.wait(3000, float_has_answer, 10), "the peek float never reloaded the agent answer")
    assert(vim.api.nvim_win_is_valid(tf), "the thread float closed")
    wait_text(tf, "Sqlite it is", "thread float after the agent answer (BeadsThreadsRefreshed)")
    assert(vim.wait(3000, function()
      return not fake.text_of(tf):find(REPLYING, 1, true)
    end, 10), "the thread float still shows the spinner:\n" .. fake.text_of(tf))
    assert.is_nil(require("beads.progress").waiting(root, "pk-c3z"), "the bead still waits on the agent")
  end)

  it("apply in a thread opened from a peek float: no prompt, a read-only message, thread stays open", function()
    local root = fake.root()
    local t = qstore.add(root, {
      bead = "pk-c3z",
      section = "description",
      messages = { { author = "agent", body = "Rename it?" } },
    })
    qstore.reply(root, t.id, "agent", "Proposal", { field = "title", value = "Charlie renamed" })
    local _, f = peek_c3z()
    local tf = open_thread(f, "Rename it?")
    wait_text(tf, "proposal: title", "thread float")
    local prompts = {}
    vim.ui.select = function(items, opts, cb)
      prompts[#prompts + 1] = opts and opts.prompt or "?"
      cb(items[1])
    end
    fake.notes = {}
    try_press(tf, "a")
    settle(300)
    assert.are.equal(0, #prompts, "apply prompted: " .. table.concat(prompts, " | "))
    local msg
    for _, n in ipairs(fake.notes) do
      if n:find("read%-only") then
        msg = n
      end
    end
    assert(msg, "no read-only message; notes: " .. table.concat(fake.notes, " | "))
    assert.is_truthy(msg:find("^Beads: "), "message lacks the 'Beads: ' prefix: " .. msg)
    assert.is_true(vim.api.nvim_win_is_valid(tf), "apply closed the thread float")
  end)

  for _, key in ipairs({ "[b", "]b" }) do
    it(key .. " onto a bead already shown in another float focuses that float (one float per bead)", function()
      local root = fake.root()
      local order = require("beads.views.tree").order(root)
      assert(#order >= 3, "tree order too short: " .. table.concat(order, " "))
      local peek = require("beads.views.peek")
      -- f1 shows the bead `key` steps onto from f2
      local a, b = order[2], order[3]
      if key == "]b" then
        a, b = order[3], order[2]
      end
      peek.open(a, root)
      local f1
      vim.wait(3000, function()
        f1 = fake.peek_of(a)
        return f1 ~= nil and fake.text_of(f1):find("Body of " .. a, 1, true) ~= nil
      end, 10)
      assert(f1, "no peek float for " .. a)
      peek.open(b, root)
      local f2
      vim.wait(3000, function()
        f2 = fake.peek_of(b)
        return f2 ~= nil and fake.text_of(f2):find("Body of " .. b, 1, true) ~= nil
      end, 10)
      assert(f2 and f2 ~= f1, "no second peek float for " .. b)
      try_press(f2, key)
      vim.wait(1000, function()
        return fake.shown_bead(vim.api.nvim_get_current_win()) == a
      end, 10)
      settle(300)
      local n = 0
      for _, w in ipairs(fake.peeks()) do
        if fake.shown_bead(w) == a then
          n = n + 1
        end
      end
      assert.are.equal(1, n, key .. " left more than one float showing " .. a .. ": " .. fake.describe_floats())
      assert.are.equal(f1, vim.api.nvim_get_current_win(), key .. " did not focus the float already showing " .. a)
    end)
  end

  for _, key in ipairs({ "e", "i" }) do
    it(key .. " enters EDIT mode in the main window only once the bead has loaded", function()
      local main, f = peek_c3z()
      local seen_early = false
      try_press(f, key)
      -- right after the key: EDIT mode on a buffer that has not loaded yet is the bug
      local function check()
        local w = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_win_get_buf(w)
        if fake.shown_id(w) == "pk-c3z" and vim.b[buf].beads_mode == "edit" and not fake.detail_loaded(buf, "pk-c3z") then
          seen_early = true
        end
      end
      check()
      local buf
      vim.wait(3000, function()
        check()
        local w = vim.api.nvim_get_current_win()
        buf = vim.api.nvim_win_get_buf(w)
        return fake.shown_id(w) == "pk-c3z" and fake.detail_loaded(buf, "pk-c3z") and vim.b[buf].beads_mode == "edit"
      end, 1)
      assert.is_false(seen_early, key .. " entered EDIT mode before beads://pk-c3z loaded")
      assert.are.equal(main, vim.api.nvim_get_current_win(), key .. " did not open the bead in the main window")
      assert.is_true(fake.detail_loaded(buf, "pk-c3z"), "beads://pk-c3z never loaded")
      assert.are.equal("edit", vim.b[buf].beads_mode, key .. " did not enter EDIT mode after the load")
      -- what the user types now stays: no late load overwrites it
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "typed after the load" })
      settle(500)
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      assert.is_truthy(text:find("typed after the load", 1, true), "typed text was overwritten:\n" .. text)
      assert.is_truthy(text:find("Charlie blocker", 1, true), "buffer lost the loaded bead:\n" .. text)
    end)
  end

  it("the peek help lists <CR> once", function()
    local _, f = peek_c3z()
    local before = snapshot_wins()
    try_press(f, "?")
    local hf = wait_new_float(before, "?")
    local n = 0
    for i, l in ipairs(fake.lines_of(hf)) do
      if i > 1 and l == "" then
        break -- end of the peek section
      end
      for _, tok in ipairs(vim.split(vim.trim(l), "[%s,/]+")) do
        if tok == "<CR>" then
          n = n + 1
        end
      end
    end
    assert.are.equal(1, n, "peek help lists <CR> " .. n .. " times:\n" .. fake.text_of(hf))
  end)
end)
