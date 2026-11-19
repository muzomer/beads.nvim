-- Bead beads_nvim-4kk, finding on tests/ask_picker_float_order_spec.lua:214: the ask is really
-- sent from INSERT mode (<M-s> while typing, keys.lua input "send" imap: stopinsert, then send() runs
-- while the mode is still "i"). agent-poke then schedules its "Poke which agent?" picker one tick
-- later, so it is not open yet when poke() returns false, nil. The thread float must still wait
-- for that picker and open only after it is answered or cancelled.
-- The agent-poke stub is the same contract as in ask_picker_float_order_spec.lua (picker through
-- vim.ui.select, vim.schedule'd when called in insert mode; poke returns false, nil while pending;
-- no completion callback; on_start only on a background start). It also records the mode poke() was
-- called in, so the test proves the scheduled (insert-mode) path is the one exercised.
-- assumption: "<M-s> pressed while typing" is modelled as feedkeys("A<M-s>") on the ask box; the
--   picker is checked 500 ms after vim.ui.select was called; the float is expected within 3 s of the
--   answer.

local fake = require("tests.questions_fake")
local store = require("beads.questions.store")

local AC = "must keep data safe"
local QUESTION = "Which picker comes first?"

local poke -- the stub's state
local selects -- recorded vim.ui.select calls: { items, opts, on_choice, win }

local function make_stub()
  local s = {
    stored = nil, -- stored target value: { target = name, id = entry id } | { target = "background" }
    delivered = {}, -- { root, entry, prompt, opts }
    background = {}, -- { root, prompt, opts }
    poke_calls = 0,
    poke_modes = {}, -- vim mode at each poke() call
  }
  local target = {
    name = "fakepane",
    list = function()
      return { { id = "pane-1", label = "fake pane 1" } }
    end,
    deliver = function(root, entry, prompt, opts)
      s.delivered[#s.delivered + 1] = { root = root, entry = entry, prompt = prompt, opts = opts }
      return "typed"
    end,
  }
  s.targets = { target }

  local function bg(root, prompt, opts)
    s.background[#s.background + 1] = { root = root, prompt = prompt, opts = opts }
    if opts and type(opts.on_start) == "function" then
      pcall(opts.on_start)
    end
    return "started", "bg-" .. #s.background
  end

  local function pick_generic(root, on_pick)
    local items = {}
    for _, t in ipairs(s.targets) do
      for _, e in ipairs(t.list(root)) do
        items[#items + 1] = { target = t, entry = e, title = e.label }
      end
    end
    items[#items + 1] = { title = "claude (background)" }
    local function choose(item)
      if not item then
        return
      end
      local value = item.target and { target = item.target.name, id = item.entry.id } or { target = "background" }
      if not on_pick then
        s.stored = value
        return
      end
      local ok, res = pcall(on_pick, item)
      if ok and res then
        s.stored = value
      end
    end
    local function open()
      vim.ui.select(items, {
        prompt = "Poke which agent?",
        format_item = function(i)
          return i.title
        end,
      }, choose)
    end
    if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
      vim.schedule(open)
    else
      open()
    end
  end

  local M = { targets = s.targets }
  function M.poke(root, prompt, opts)
    s.poke_calls = s.poke_calls + 1
    s.poke_modes[#s.poke_modes + 1] = vim.api.nvim_get_mode().mode
    opts = opts or {}
    if #s.targets == 0 then
      return bg(root, prompt, opts)
    end
    if opts.pick or type(s.stored) ~= "table" then
      local result, rid = false, nil
      pick_generic(root, function(item)
        if item.target then
          result = item.target.deliver(root, item.entry, prompt, opts)
          rid = "h-" .. #s.delivered
        else
          result, rid = bg(root, prompt, opts)
        end
        return result
      end)
      return result, rid
    end
    if s.stored.target == "background" then
      return bg(root, prompt, opts)
    end
    for _, t in ipairs(s.targets) do
      if t.name == s.stored.target then
        for _, e in ipairs(t.list(root)) do
          if e.id == s.stored.id then
            return t.deliver(root, e, prompt, opts), "h-" .. #s.delivered
          end
        end
      end
    end
    return bg(root, prompt, opts)
  end
  function M.pick(root, on_pick)
    pick_generic(root, on_pick)
  end
  function M.register_target(spec)
    s.targets[#s.targets + 1] = spec
    return true
  end
  s.module = M
  s.state = {
    get = function()
      return { target = s.stored }
    end,
    set = function(_, key, value)
      if key == "target" then
        s.stored = value
      end
    end,
    normalize = function(r)
      return r
    end,
  }
  return s
end

local function install_stub()
  poke = make_stub()
  package.loaded["agent-poke"] = nil
  package.loaded["agent-poke.state"] = nil
  package.preload["agent-poke"] = function()
    return poke.module
  end
  package.preload["agent-poke.state"] = function()
    return poke.state
  end
end

local function line_of(buf, text)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l == text then
      return i
    end
  end
  error("no line '" .. text .. "' in the detail buffer")
end

local function sleep(ms)
  vim.wait(ms, function()
    return false
  end, 10)
end

local function thread_float()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" and fake.float_text(w):find("Thread t1", 1, true) then
      return w
    end
  end
end

local function floats()
  local n = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      n = n + 1
    end
  end
  return n
end

local function threads()
  return store.list(fake.dir(), { bead = "fx-1" })
end

-- Opens the detail buffer, asks QUESTION on the Acceptance section and sends it with <M-s>.
local function ask_and_send()
  local buf = fake.open_detail()
  local win = vim.fn.bufwinid(buf)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { line_of(buf, AC), 0 })
  local f = fake.press_for_float("a")
  assert(f, "a opened no ask box")
  vim.api.nvim_set_current_win(f)
  pcall(vim.cmd, "stopinsert")
  vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(f), 0, -1, false, { QUESTION })
  -- type at the end of the question and send it without leaving insert mode
  fake.press("A<M-s>")
  return buf
end

-- Sends a question with no stored target and checks the picker is shown alone; returns the call.
local function ask_until_picker()
  ask_and_send()
  fake.wait_for(function()
    return #selects == 1
  end, "the agent picker (vim.ui.select) after <M-s>")
  local sel = selects[1]
  assert.are.equal(1, poke.poke_calls, "agent-poke was not poked once")
  assert.are.equal("i", poke.poke_modes[1]:sub(1, 1), "poke() did not run in insert mode: " .. poke.poke_modes[1])
  assert.are.equal("Poke which agent?", sel.opts and sel.opts.prompt)
  fake.wait_for(function()
    return #threads() == 1
  end, "the question stored")
  sleep(500)
  assert.is_nil(thread_float(), "the thread float opened while the agent picker is still waiting for an answer")
  assert.are.equal(0, floats(), "a float opened while the agent picker is still waiting for an answer")
  assert.are.equal(sel.win, vim.api.nvim_get_current_win(), "focus moved away while the agent picker is open")
  assert.are.equal(1, #selects, "the picker was asked more than once")
  assert.are.equal(0, #poke.delivered, "a target got the prompt before one was chosen")
  return sel
end

local function item_where(sel, pred)
  for _, it in ipairs(sel.items) do
    if pred(it) then
      return it
    end
  end
  error("no such picker item")
end

describe("beads ask: thread float waits for the agent picker opened from insert mode", function()
  before_each(function()
    fake.setup()
    fake.write_bead({ acceptance_criteria = AC })
    install_stub()
    selects = {}
    vim.ui.input = function(_, cb)
      cb(nil)
    end
    vim.ui.select = function(items, opts, on_choice)
      selects[#selects + 1] = { items = items, opts = opts, on_choice = on_choice, win = vim.api.nvim_get_current_win() }
    end
    require("beads").setup({})
  end)

  after_each(function()
    pcall(vim.cmd, "stopinsert")
    package.preload["agent-poke"] = nil
    package.loaded["agent-poke"] = nil
    package.preload["agent-poke.state"] = nil
    package.loaded["agent-poke.state"] = nil
    fake.teardown()
    require("beads").setup({})
  end)

  it("insert-mode send: shows the scheduled picker only, then opens the float once a target is chosen", function()
    local sel = ask_until_picker()
    sel.on_choice(item_where(sel, function(i)
      return i.target ~= nil
    end), 1)
    assert.are.equal(1, #poke.delivered, "the chosen target did not get the prompt")
    assert.is_truthy(poke.delivered[1].prompt:find(QUESTION, 1, true), poke.delivered[1].prompt)
    fake.wait_for(function()
      return thread_float() ~= nil
    end, "the thread float after a target was chosen")
    assert.is_truthy(fake.float_text(thread_float()):find(QUESTION, 1, true), fake.float_text(thread_float()))
  end)

  it("insert-mode send: a cancelled scheduled pick still opens the float with the stored question", function()
    local sel = ask_until_picker()
    sel.on_choice(nil, nil)
    fake.wait_for(function()
      return thread_float() ~= nil
    end, "the thread float after the pick was cancelled")
    assert.is_truthy(fake.float_text(thread_float()):find(QUESTION, 1, true), fake.float_text(thread_float()))
    assert.are.equal(0, #poke.delivered)
    assert.are.equal(0, #poke.background)
  end)

  it("insert-mode send: choosing the background agent in the scheduled picker opens the float after the pick", function()
    local sel = ask_until_picker()
    sel.on_choice(item_where(sel, function(i)
      return i.target == nil
    end), 2)
    assert.are.equal(1, #poke.background, "the background agent did not get the prompt")
    fake.wait_for(function()
      return thread_float() ~= nil
    end, "the thread float after the background agent was chosen")
  end)

  it("insert-mode send: open_after_send = false opens nothing while picking or after a target is chosen", function()
    require("beads").setup({ ask = { open_after_send = false } })
    local sel = ask_until_picker()
    sel.on_choice(item_where(sel, function(i)
      return i.target ~= nil
    end), 1)
    assert.are.equal(1, #poke.delivered)
    sleep(500)
    assert.is_nil(thread_float(), "a thread float opened with open_after_send = false")
    assert.are.equal(0, floats(), "a float opened with open_after_send = false")
  end)
end)
