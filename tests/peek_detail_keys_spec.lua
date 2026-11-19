-- Bead beads_nvim-ezh: a peek float has the same keys as the detail VIEW buffer, acting on the
-- float's bead.
-- Interface under test:
--   * In a peek float: e / i open the float's bead in the main window in EDIT mode and close all
--     floats; x close (asks a reason), C claim, n note, c comment, a ask act on the float's bead;
--     ]b / [b replace the float's bead in place (same window) with the next / previous bead in tree
--     order (a count works); ]u / [u jump to the next / previous thread waiting for you; <CR> on a
--     question line opens the thread float, elsewhere opens the bead in the main window; ? and g?
--     show the help, which lists the keys.
--   * Keys come from keymaps.detail.view.*; keymaps.peek.* overrides.
--   * Actions that change the bead refresh the float.
-- Fixture and fake bd: tests/peek_fake.lua; bd calls are captured by a vim.system spy.
-- Not covered here (already pinned by peek_keys_spec / peek_stack_spec): q, Q, gd, yy, yr.
-- assumption: keymaps.peek.* uses the detail-view action names (edit, close_bead, claim,
--   open_thread, next_waiting, prev_waiting, next_bead, prev_bead, ask, note, comment, details).
-- assumption: the setup order is keymaps.peek.<action> (user) > keymaps.detail.view.<action> (user)
--   > default, so remapping detail.view.claim moves C in the float too.
-- assumption: "refresh the float" means the action re-fetches the float's bead itself (the fake
--   bd keeps updated_at unchanged, so the store subscription alone does not repaint it).
-- assumption: the peek help lists each key as the first token of a line ("%-12s desc" format).

local fake = require("tests.peek_fake")
local qstore = require("beads.questions.store")

local calls
local orig_system

local function start_spy()
  calls = {}
  orig_system = vim.system
  vim.system = function(cmd, opts, on_exit)
    if type(cmd) == "table" then
      calls[#calls + 1] = vim.deepcopy(cmd)
    end
    return orig_system(cmd, opts, on_exit)
  end
end

local function stop_spy()
  if orig_system then
    vim.system = orig_system
    orig_system = nil
  end
end

-- First captured bd call containing every token in `want`.
local function find_call(want)
  for _, c in ipairs(calls) do
    local ok = c[1] == "bd"
    for _, w in ipairs(want) do
      ok = ok and vim.list_contains(c, w)
    end
    if ok then
      return c
    end
  end
end

local function wait_call(want, what)
  local c
  vim.wait(3000, function()
    c = find_call(want)
    return c ~= nil
  end, 10)
  local seen = {}
  for _, x in ipairs(calls) do
    seen[#seen + 1] = table.concat(x, " ")
  end
  assert(c, ("%s: no bd call with %s; calls:\n%s"):format(what, table.concat(want, " "), table.concat(seen, "\n")))
  return c
end

local function settle(ms)
  vim.wait(ms or 200, function()
    return false
  end, 10)
end

-- Presses keys, swallowing the errors an unmapped key can raise in a read-only buffer (red phase).
local function try_press(win, keys)
  local ok, err = pcall(fake.press, win, keys)
  pcall(vim.cmd, "stopinsert")
  return ok, err
end

-- Main window shows the detail of pk-b2y; returns (main window, peek float of pk-c3z).
local function peek_c3z()
  local main = vim.api.nvim_get_current_win()
  fake.edit_in(main, "pk-b2y")
  fake.cursor_on(main, "pk-c3z", 2)
  local f = fake.peek(main, "gd", "pk-c3z")
  return main, f
end

local function new_float(before)
  for _, w in ipairs(fake.floats()) do
    if not before[w] then
      return w
    end
  end
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
    w = new_float(before)
    return w ~= nil
  end, 10)
  assert(w, what .. " opened no float; floats: " .. fake.describe_floats())
  return w
end

local function title_of(win)
  local t = vim.api.nvim_win_get_config(win).title
  if type(t) == "string" then
    return t
  end
  local out = {}
  for _, chunk in ipairs(t or {}) do
    out[#out + 1] = type(chunk) == "table" and chunk[1] or tostring(chunk)
  end
  return table.concat(out)
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
  end, 10), what .. ": float never showed " .. text .. ":\n" .. fake.text_of(win))
end

describe("peek float detail keys", function()
  before_each(function()
    fake.setup({})
    start_spy()
  end)

  after_each(function()
    stop_spy()
    fake.teardown()
  end)

  for _, key in ipairs({ "e", "i" }) do
    it(key .. " opens the float's bead in the main window in EDIT mode and closes the floats", function()
      local main = vim.api.nvim_get_current_win()
      fake.edit_in(main, "pk-b2y")
      fake.cursor_on(main, "pk-c3z", 2)
      local f1 = fake.peek(main, "gd", "pk-c3z")
      fake.cursor_on(f1, "pk-d4w", 1)
      local f2 = fake.peek(f1, "gd", "pk-d4w")
      try_press(f2, key)
      assert(vim.wait(3000, function()
        return #fake.peeks() == 0
      end, 10), key .. " left peek floats open: " .. fake.describe_floats())
      local cur = vim.api.nvim_get_current_win()
      assert.are.equal("", vim.api.nvim_win_get_config(cur).relative, "focus is not in a normal window")
      assert.are.equal("pk-d4w", fake.shown_id(cur), key .. " did not open the top float's bead in the main window")
      local buf = vim.api.nvim_win_get_buf(cur)
      assert(vim.wait(3000, function()
        return fake.detail_loaded(buf, "pk-d4w")
      end, 10), "beads://pk-d4w never loaded")
      settle(300)
      assert.are.equal("edit", vim.b[buf].beads_mode, key .. " did not leave the bead in EDIT mode")
    end)
  end

  it("x closes the float's bead (asks a reason)", function()
    vim.ui.input = function(_, cb)
      cb("done")
    end
    local _, f = peek_c3z()
    try_press(f, "x")
    wait_call({ "close", "pk-c3z", "--reason", "done" }, "x")
    assert.is_nil(find_call({ "close", "pk-b2y" }), "x closed the main window's bead")
  end)

  it("C claims the float's bead", function()
    local _, f = peek_c3z()
    try_press(f, "C")
    wait_call({ "update", "pk-c3z", "--claim" }, "C")
    assert.is_nil(find_call({ "update", "pk-b2y", "--claim" }), "C claimed the main window's bead")
  end)

  it("n appends a note to the float's bead", function()
    local _, f = peek_c3z()
    local before = snapshot_wins()
    try_press(f, "n")
    local nf = wait_new_float(before, "n")
    pcall(vim.cmd, "stopinsert")
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(nf), 0, -1, false, { "a peek note" })
    fake.press(nf, "<C-s>")
    local c = wait_call({ "update", "pk-c3z", "--append-notes" }, "n")
    assert.is_true(vim.list_contains(c, "a peek note"), "note text not sent: " .. table.concat(c, " "))
  end)

  it("c comments on the float's bead", function()
    local _, f = peek_c3z()
    local before = snapshot_wins()
    try_press(f, "c")
    local cf = wait_new_float(before, "c")
    pcall(vim.cmd, "stopinsert")
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(cf), 0, -1, false, { "a peek comment" })
    fake.press(cf, "<C-s>")
    wait_call({ "comment", "pk-c3z" }, "c")
  end)

  it("a opens the ask box for the float's bead", function()
    local _, f = peek_c3z()
    fake.cursor_on(f, "Body of pk-c3z", 0)
    local before = snapshot_wins()
    try_press(f, "a")
    local af = wait_new_float(before, "a")
    assert.is_truthy(title_of(af):find("Ask pk-c3z", 1, true), "ask box title: " .. title_of(af))
  end)

  it("C refreshes the float with the changed bead", function()
    local _, f = peek_c3z()
    -- let the float's own initial fetch (bd show pk-c3z) finish before the fixture changes
    wait_call({ "show", "pk-c3z" }, "initial fetch")
    settle(300)
    local items = fake.items()
    for _, b in ipairs(items) do
      if b.id == "pk-c3z" then
        -- same updated_at: only an explicit refresh by the action shows the change
        b.status = "in_progress"
      end
    end
    fake.set_list(items)
    settle(300)
    assert.is_truthy(fake.text_of(f):find("status: open", 1, true), "float changed before any action")
    try_press(f, "C")
    wait_text(f, "status: in_progress", "C")
  end)

  it("]b / [b replace the float's bead in place in tree order (count works)", function()
    local root = fake.root()
    local order = require("beads.views.tree").order(root)
    assert(#order >= 4, "tree order too short: " .. table.concat(order, " "))
    require("beads.views.peek").open(order[2], root)
    local f
    vim.wait(3000, function()
      f = fake.peek_of(order[2])
      return f ~= nil and fake.text_of(f):find("Body of " .. order[2], 1, true) ~= nil
    end, 10)
    assert(f, "no peek float for " .. order[2])
    local function expect(id, keys)
      assert(vim.wait(3000, function()
        return vim.api.nvim_win_is_valid(f) and fake.shown_bead(f) == id
      end, 10), ("%s: float shows %s, want %s"):format(keys, tostring((fake.shown_bead(f))), id))
      assert.are.equal(1, #fake.peeks(), keys .. " left more than one float: " .. fake.describe_floats())
    end
    try_press(f, "]b")
    expect(order[3], "]b")
    try_press(f, "[b")
    expect(order[2], "[b")
    try_press(f, "2]b")
    expect(order[4], "2]b")
  end)

  it("<CR> on a question line opens the thread float", function()
    qstore.add(fake.root(), {
      bead = "pk-c3z",
      section = "description",
      messages = { { author = "agent", body = "Peek question here" } },
    })
    local _, f = peek_c3z()
    wait_text(f, "## Questions", "questions")
    local h = row_of_line(f, "## Questions")
    vim.api.nvim_win_set_cursor(f, { h + 1, 0 })
    local before = snapshot_wins()
    try_press(f, "<CR>")
    local tf = wait_new_float(before, "<CR> on a question")
    assert.is_truthy((fake.lines_of(tf)[1] or ""):find("^Thread "), "not a thread float:\n" .. fake.text_of(tf))
  end)

  it("<CR> elsewhere opens the float's bead in the main window (passes already)", function()
    local main, f = peek_c3z()
    fake.cursor_on(f, "Body of pk-c3z", 0)
    try_press(f, "<CR>")
    assert(vim.wait(3000, function()
      return #fake.peeks() == 0
    end, 10), "<CR> left peek floats open")
    assert.are.equal(main, vim.api.nvim_get_current_win())
    assert.are.equal("pk-c3z", fake.shown_id(main))
  end)

  it("]u / [u jump between threads waiting for you", function()
    local root = fake.root()
    local t1 = qstore.add(root, { bead = "pk-c3z", section = "description", messages = { { author = "agent", body = "first q" } } })
    qstore.reply(root, t1.id, "user", "my answer") -- needs the agent now
    qstore.add(root, { bead = "pk-c3z", section = "description", messages = { { author = "agent", body = "second q" } } })
    local _, f = peek_c3z()
    wait_text(f, "second q", "threads")
    local h = row_of_line(f, "## Questions")
    vim.api.nvim_win_set_cursor(f, { 1, 0 })
    try_press(f, "]u")
    assert.are.equal(h + 2, vim.api.nvim_win_get_cursor(f)[1], "]u did not jump to the thread waiting for you")
    vim.api.nvim_win_set_cursor(f, { #fake.lines_of(f), 0 })
    try_press(f, "[u")
    assert.are.equal(h + 2, vim.api.nvim_win_get_cursor(f)[1], "[u did not jump back to the thread waiting for you")
  end)

  for _, hk in ipairs({ "?", "g?" }) do
    it(hk .. " help lists the detail keys of the float", function()
      local _, f = peek_c3z()
      local before = snapshot_wins()
      try_press(f, hk)
      local hf = wait_new_float(before, hk)
      local firsts = {}
      for _, l in ipairs(fake.lines_of(hf)) do
        for _, tok in ipairs(vim.split(vim.trim(l), "[%s,/]+")) do
          firsts[tok] = true
        end
      end
      for _, k in ipairs({ "e", "x", "C", "]b", "[b", "]u", "n", "c", "a", "K", "gd", "Q" }) do
        assert.is_true(firsts[k] == true, ("%s help does not list %s:\n%s"):format(hk, k, fake.text_of(hf)))
      end
    end)
  end

  it("a key remapped in keymaps.detail.view applies to the float", function()
    require("beads").setup({ tree = { layout = "split" }, keymaps = { detail = { view = { claim = "<F7>", yank_id = "<F6>" } } } })
    local _, f = peek_c3z()
    local fbuf = vim.api.nvim_win_get_buf(f)
    assert.is_nil(fake.buf_map(fbuf, "n", "C"), "C still mapped in the float with detail.view.claim = '<F7>'")
    assert.is_nil(fake.buf_map(fbuf, "n", "yy"), "yy still mapped in the float with detail.view.yank_id = '<F6>'")
    try_press(f, "<F7>")
    wait_call({ "update", "pk-c3z", "--claim" }, "<F7>")
  end)

  it("keymaps.peek overrides keymaps.detail.view in the float", function()
    require("beads").setup({
      tree = { layout = "split" },
      keymaps = { detail = { view = { claim = "<F7>" } }, peek = { claim = "<F8>" } },
    })
    local main, f = peek_c3z()
    local fbuf = vim.api.nvim_win_get_buf(f)
    assert.is_nil(fake.buf_map(fbuf, "n", "<F7>"), "<F7> mapped in the float with peek.claim = '<F8>'")
    assert.is_not_nil(fake.buf_map(vim.api.nvim_win_get_buf(main), "n", "<F7>"), "detail view lost <F7>")
    try_press(f, "<F8>")
    wait_call({ "update", "pk-c3z", "--claim" }, "<F8>")
  end)
end)
