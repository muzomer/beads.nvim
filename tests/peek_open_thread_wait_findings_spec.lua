-- Bead beads_nvim-ezh, review findings (second round): the peek float's e / i wait and its
-- open_thread key.
--   blocker peek.lua:198  e / i waits for the main window's detail buffer to load; once the wait
--                         gives up, a 'Beads: ' message explains it (once), the user stays in VIEW
--                         mode and no timer is left to switch to EDIT mode later.
--   blocker keys.lua:75   in a peek float the `open` action (thread on a question line, else the
--                         bead in the main window) is bound to the keys of open_thread, resolved as
--                         keymaps.peek.open_thread, else keymaps.peek.open, else
--                         keymaps.detail.view.open_thread, else <CR>; false disables it; the help
--                         lists the key(s) once.
-- Fixture and fake bd: tests/peek_fake.lua. A wrapper bd (test double) put first on PATH delays
-- `bd show` while a flag file exists, so the main window's load outlasts the wait.
-- assumption: the wait's timeout is the module field require('beads.views.peek').edit_wait_ms
--   (milliseconds, default ~6000); the test lowers it to 300.
-- assumption: the give-up message names the bead id (pk-c3z).
-- assumption: the help's keys are counted in its first (peek) section, as key tokens.

local fake = require("tests.peek_fake")
local qstore = require("beads.questions.store")

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

local function new_float(before)
  for _, x in ipairs(fake.floats()) do
    if not before[x] then
      return x
    end
  end
end

local function wait_new_float(before, what)
  local w
  vim.wait(3000, function()
    w = new_float(before)
    return w ~= nil
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

-- A peek float of pk-c3z with one question; cursor on the question line.
local function peek_with_question()
  qstore.add(fake.root(), {
    bead = "pk-c3z",
    section = "description",
    messages = { { author = "agent", body = "Which database?" } },
  })
  local _, f = peek_c3z()
  wait_text(f, "Which database?", "questions")
  local h = row_of_line(f, "## Questions")
  assert(h, "no ## Questions in the float:\n" .. fake.text_of(f))
  vim.api.nvim_win_set_cursor(f, { h + 1, 0 })
  return f
end

-- Presses key in the float f; returns the thread float it opened, or nil.
local function thread_from(f, key)
  local before = snapshot_wins()
  vim.api.nvim_win_set_cursor(f, { vim.api.nvim_win_get_cursor(f)[1], 0 })
  try_press(f, key)
  local w
  vim.wait(1000, function()
    w = new_float(before)
    return w ~= nil
  end, 10)
  if w and (fake.lines_of(w)[1] or ""):find("^Thread ") then
    return w
  end
  return nil
end

local function mapped(win, lhs)
  return fake.buf_map(vim.api.nvim_win_get_buf(win), "n", lhs) ~= nil
end

-- Counts key tokens in the help's first (peek) section.
local function help_count(f, key)
  local before = snapshot_wins()
  try_press(f, "?")
  local hf = wait_new_float(before, "?")
  local n = 0
  for i, l in ipairs(fake.lines_of(hf)) do
    if i > 1 and (l == "" or l:find("^── ")) then
      break
    end
    for _, tok in ipairs(vim.split(vim.trim(l), "[%s,/]+")) do
      if tok == key then
        n = n + 1
      end
    end
  end
  return n, fake.text_of(hf)
end

describe("peek float e / i wait gives up with a message (review finding)", function()
  local peek, orig_wait, wrap_dir, flag, orig_path

  before_each(function()
    fake.setup({})
    peek = require("beads.views.peek")
    orig_wait = peek.edit_wait_ms
    -- wrapper bd: `show` sleeps while the flag file exists, then runs the fake bd
    wrap_dir = vim.fn.tempname()
    vim.fn.mkdir(wrap_dir, "p")
    flag = wrap_dir .. "/slow"
    local real = vim.fn.exepath("bd")
    vim.fn.writefile({
      "#!/bin/sh",
      'for a in "$@"; do',
      '  if [ "$a" = "show" ] && [ -f "' .. flag .. '" ]; then sleep 2; fi',
      "done",
      'exec "' .. real .. '" "$@"',
    }, wrap_dir .. "/bd")
    vim.fn.setfperm(wrap_dir .. "/bd", "rwxr-xr-x")
    orig_path = vim.env.PATH
    vim.env.PATH = wrap_dir .. ":" .. orig_path
  end)

  after_each(function()
    peek.edit_wait_ms = orig_wait
    vim.env.PATH = orig_path
    fake.teardown()
    vim.fn.delete(wrap_dir, "rf")
  end)

  for _, key in ipairs({ "e", "i" }) do
    it(key .. ": when the bead does not load in time, one 'Beads: ' message, VIEW mode, no late EDIT", function()
      local main, f = peek_c3z()
      peek.edit_wait_ms = 300
      vim.fn.writefile({}, flag)
      fake.notes = {}
      try_press(f, key)
      local w = vim.api.nvim_get_current_win()
      assert.are.equal(main, w, key .. " did not go to the main window")
      local buf = vim.api.nvim_win_get_buf(w)
      local function gave_up()
        for _, n in ipairs(fake.notes) do
          if n:find("pk-c3z", 1, true) then
            return true
          end
        end
        return false
      end
      -- the wait gives up after ~300 ms, well before the 2 s load lands
      assert(
        vim.wait(1200, gave_up, 10),
        key .. ": no message naming pk-c3z after the wait gave up; notes: " .. table.concat(fake.notes, " | ")
      )
      assert.is_false(fake.detail_loaded(buf, "pk-c3z"), "the slow load finished before the timeout (test setup)")
      assert.are_not.equal("edit", vim.b[buf].beads_mode, key .. " entered EDIT mode on an unloaded buffer")
      -- the load lands later: the abandoned wait must not switch to EDIT mode then
      vim.fn.delete(flag)
      assert(vim.wait(5000, function()
        return fake.detail_loaded(buf, "pk-c3z")
      end, 10), "beads://pk-c3z never loaded")
      settle(500)
      assert.are_not.equal("edit", vim.b[buf].beads_mode, key .. ": a leftover timer entered EDIT mode after the give-up")
      local msgs = {}
      for _, n in ipairs(fake.notes) do
        if n:find("pk-c3z", 1, true) then
          msgs[#msgs + 1] = n
        end
      end
      assert.are.equal(1, #msgs, "expected one give-up message: " .. table.concat(msgs, " | "))
      assert.is_truthy(msgs[1]:find("^Beads: "), "message lacks the 'Beads: ' prefix: " .. msgs[1])
    end)
  end
end)

describe("peek float open_thread key (review finding)", function()
  after_each(function()
    fake.teardown()
  end)

  it("keymaps.detail.view.open_thread = 'o': o opens the thread in a peek float, <CR> is unmapped", function()
    fake.setup({ keymaps = { detail = { view = { open_thread = "o" } } } })
    local f = peek_with_question()
    assert.is_false(mapped(f, "<CR>"), "<CR> still mapped in the peek float")
    assert.is_true(mapped(f, "o"), "o not mapped in the peek float")
    assert(thread_from(f, "o"), "o on a question line opened no thread; floats: " .. fake.describe_floats())
  end)

  it("keymaps.detail.view.open_thread = 'o': <CR> on a question line opens no thread", function()
    fake.setup({ keymaps = { detail = { view = { open_thread = "o" } } } })
    local f = peek_with_question()
    assert.is_nil(thread_from(f, "<CR>"), "<CR> still opens the thread")
  end)

  it("keymaps.peek.open_thread = false: no thread-opening key in the float", function()
    fake.setup({ keymaps = { detail = { view = { open_thread = "o" } }, peek = { open_thread = false } } })
    local f = peek_with_question()
    assert.is_false(mapped(f, "o"), "o mapped although peek.open_thread = false")
    assert.is_false(mapped(f, "<CR>"), "<CR> mapped although peek.open_thread = false")
    assert.is_nil(thread_from(f, "<CR>"), "<CR> opened the thread although peek.open_thread = false")
  end)

  it("keymaps.peek.open_thread = 'T' wins over keymaps.detail.view.open_thread", function()
    fake.setup({ keymaps = { detail = { view = { open_thread = "o" } }, peek = { open_thread = "T" } } })
    local f = peek_with_question()
    assert.is_false(mapped(f, "o"), "o mapped although peek.open_thread = 'T'")
    assert.is_false(mapped(f, "<CR>"), "<CR> mapped although peek.open_thread = 'T'")
    assert(thread_from(f, "T"), "T on a question line opened no thread; floats: " .. fake.describe_floats())
  end)

  it("keymaps.peek.open = 'O' wins over keymaps.detail.view.open_thread", function()
    fake.setup({ keymaps = { detail = { view = { open_thread = "o" } }, peek = { open = "O" } } })
    local f = peek_with_question()
    assert.is_false(mapped(f, "o"), "o mapped although peek.open = 'O'")
    assert.is_false(mapped(f, "<CR>"), "<CR> mapped although peek.open = 'O'")
    assert(thread_from(f, "O"), "O on a question line opened no thread; floats: " .. fake.describe_floats())
  end)

  it("default: <CR> on a question line opens the thread", function()
    fake.setup({})
    local f = peek_with_question()
    assert(thread_from(f, "<CR>"), "<CR> opened no thread; floats: " .. fake.describe_floats())
  end)

  it("the help lists the remapped key once and no <CR>", function()
    fake.setup({ keymaps = { detail = { view = { open_thread = "o" } } } })
    local _, f = peek_c3z()
    local n, text = help_count(f, "o")
    assert.are.equal(1, n, "peek help lists o " .. n .. " times:\n" .. text)
    fake.close_floats()
    local _, f2 = peek_c3z()
    local m, text2 = help_count(f2, "<CR>")
    assert.are.equal(0, m, "peek help lists <CR> " .. m .. " times:\n" .. text2)
  end)
end)
