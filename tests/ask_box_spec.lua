-- Bead beads_nvim-tch: ask like code-review.nvim, the ask box and open-after-send.
-- Interface under test (through key presses):
--   * 'a' in detail VIEW mode (normal = section, visual = quote) opens a floating, multi-line,
--     modifiable input box (never vim.ui.input). Its title names the bead id and the section, or
--     the quote for a visual selection.
--   * Box keys (keymaps.input): submit <C-s> (normal + insert) saves the thread without sending,
--     send <M-s> (normal) saves and calls require("agent-poke").poke, submit_normal <CR> (normal)
--     saves, cancel q / <Esc> (normal) close with nothing stored. Empty text stores nothing.
--   * setup({ ask = { open_after_send = true } }) (the default) opens the new thread's float after
--     saving; false does not.
--   * The thread float's reply (r) uses the same box.
--   * The help float of the box (<leader>b?) lists <M-s>; README documents the box and the reply
--     notification.
-- agent-poke.nvim is stubbed through package.preload. bd is a fake on PATH (tests/questions_fake.lua).
--
-- assumption: the new keymaps.input action that saves and sends is named "send" (default "<M-s>").
-- assumption: <C-s> / <CR> only save: they do not poke the agent.
-- assumption: open_after_send applies to every save (<C-s>, <CR>, <M-s>), not only to <M-s>.
-- assumption: the title match is case-insensitive ("fx-1" and "acceptance" / the quote text).

local fake = require("tests.questions_fake")
local store = require("beads.questions.store")

local AC = "must keep data safe"
local pokes, input_calls

local function stub_poke()
  package.loaded["agent-poke"] = nil
  package.preload["agent-poke"] = function()
    return {
      poke = function(root, prompt, opts)
        pokes[#pokes + 1] = { root = root, prompt = prompt, opts = opts }
      end,
    }
  end
end

local function stub_input()
  vim.ui.input = function(_, cb)
    input_calls = input_calls + 1
    cb(nil)
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

local function title_of(w)
  local t = vim.api.nvim_win_get_config(w).title
  if type(t) == "table" then
    local parts = {}
    for _, c in ipairs(t) do
      parts[#parts + 1] = type(c) == "table" and c[1] or tostring(c)
    end
    return table.concat(parts)
  end
  return tostring(t or "")
end

local function threads()
  return store.list(fake.dir(), { bead = "fx-1" })
end

local function open()
  local buf = fake.open_detail()
  local win = vim.fn.bufwinid(buf)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { line_of(buf, AC), 0 })
  return buf, win
end

-- Presses keys (in the detail window) and returns the ask box window; asserts it is a box.
local function open_box(keys)
  local f = fake.press_for_float(keys)
  assert.are.equal(0, input_calls, "vim.ui.input was used instead of the ask box")
  assert.is_not_nil(f, "pressing " .. keys .. " opened no float")
  vim.api.nvim_set_current_win(f)
  pcall(vim.cmd, "stopinsert")
  return f, vim.api.nvim_win_get_buf(f)
end

local function fill(f, lines)
  vim.api.nvim_set_current_win(f)
  vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(f), 0, -1, false, lines)
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

describe("beads ask box", function()
  before_each(function()
    fake.setup()
    fake.write_bead({ acceptance_criteria = AC })
    pokes, input_calls = {}, 0
    stub_poke()
    stub_input()
    require("beads").setup({})
  end)

  after_each(function()
    package.preload["agent-poke"] = nil
    package.loaded["agent-poke"] = nil
    fake.teardown()
    require("beads").setup({})
  end)

  it("a opens a floating, multi-line, modifiable box titled with the bead id and section", function()
    open()
    local f, b = open_box("a")
    assert.are_not.equal("", vim.api.nvim_win_get_config(f).relative)
    assert.is_true(vim.bo[b].modifiable, "the ask box is not modifiable")
    assert.is_true(vim.api.nvim_win_get_height(f) >= 2, "the ask box is a single line")
    local title = title_of(f):lower()
    assert.is_truthy(title:find("fx-1", 1, true), "title lacks the bead id: " .. title)
    assert.is_truthy(title:find("acceptance", 1, true), "title lacks the section: " .. title)
  end)

  it("visual a titles the box with the quote", function()
    local buf, win = open()
    vim.api.nvim_win_set_cursor(win, { line_of(buf, AC), 5 })
    local f = open_box("v8la")
    local title = title_of(f):lower()
    assert.is_truthy(title:find("fx-1", 1, true), "title lacks the bead id: " .. title)
    assert.is_truthy(title:find("keep data", 1, true), "title lacks the quote: " .. title)
  end)

  it("<C-s> in normal mode stores the full multi-line text and does not poke", function()
    open()
    local f = open_box("a")
    fill(f, { "line one", "line two" })
    fake.press("<C-s>")
    fake.wait_for(function()
      return #threads() == 1
    end, "thread stored after <C-s>")
    assert.are.equal("line one\nline two", threads()[1].messages[1].body)
    assert.are.equal("acceptance", threads()[1].section)
    sleep(300)
    assert.are.equal(0, #pokes, "<C-s> poked the agent; only <M-s> sends")
  end)

  it("<C-s> in insert mode stores the typed multi-line text", function()
    open()
    local f = open_box("a")
    vim.api.nvim_set_current_win(f)
    fake.press("ifirst<CR>second<C-s>")
    fake.wait_for(function()
      return #threads() == 1
    end, "thread stored after insert-mode <C-s>")
    assert.are.equal("first\nsecond", threads()[1].messages[1].body)
  end)

  it("<CR> in normal mode stores the thread", function()
    open()
    local f = open_box("a")
    fill(f, { "enter question" })
    fake.press("<CR>")
    fake.wait_for(function()
      return #threads() == 1
    end, "thread stored after <CR>")
    assert.are.equal("enter question", threads()[1].messages[1].body)
  end)

  it("<M-s> stores the thread and pokes the agent with the question", function()
    open()
    local f, b = open_box("a")
    assert.is_not_nil(fake.buf_map(b, "n", "<M-s>"), "no normal-mode <M-s> map in the ask box")
    fill(f, { "Send this?", "really" })
    fake.press("<M-s>")
    fake.wait_for(function()
      return #threads() == 1 and #pokes == 1
    end, "thread stored and agent poked after <M-s>")
    assert.are.equal("Send this?\nreally", threads()[1].messages[1].body)
    assert.is_truthy(pokes[1].prompt:find("Send this?", 1, true), pokes[1].prompt)
  end)

  for _, k in ipairs({ "q", "<Esc>" }) do
    it(k .. " in normal mode cancels: box closed, nothing stored", function()
      open()
      local f = open_box("a")
      fill(f, { "draft question" })
      vim.cmd("stopinsert")
      fake.press(k)
      fake.wait_for(function()
        return not vim.api.nvim_win_is_valid(f)
      end, "box closed after " .. k)
      sleep(300)
      assert.are.equal(0, #threads())
      assert.are.equal(0, #pokes)
    end)
  end

  it("empty text stores nothing, also with <M-s>", function()
    open()
    local f = open_box("a")
    fill(f, { "", "   " })
    fake.press("<M-s>")
    sleep(300)
    assert.are.equal(0, #threads())
    assert.are.equal(0, #pokes)
  end)

  it("open_after_send (default) opens the new thread's float after saving", function()
    open()
    local f = open_box("a")
    fill(f, { "Open me after?" })
    fake.press("<C-s>")
    fake.wait_for(function()
      return thread_float() ~= nil
    end, "the new thread's float")
    assert.is_truthy(fake.float_text(thread_float()):find("Open me after?", 1, true))
  end)

  it("ask.open_after_send = false opens no float after saving", function()
    require("beads").setup({ ask = { open_after_send = false } })
    open()
    local f = open_box("a")
    fill(f, { "Do not open" })
    fake.press("<C-s>")
    fake.wait_for(function()
      return #threads() == 1
    end, "thread stored")
    sleep(400)
    assert.is_nil(thread_float(), "a thread float opened with open_after_send = false")
    assert.are.equal(0, floats(), "a float is still open")
  end)

  it("the thread float's reply (r) uses the same box", function()
    store.add(fake.dir(), { bead = "fx-1", messages = { { author = "agent", body = "Which one?" } } })
    local buf = open()
    fake.open_thread(buf, "Which one?")
    local f, b = open_box("r")
    assert.is_true(vim.bo[b].modifiable, "the reply box is not modifiable")
    assert.is_not_nil(fake.buf_map(b, "n", "<M-s>"), "the reply box is not the ask box (no <M-s>)")
    fill(f, { "this one", "and that" })
    fake.press("<C-s>")
    fake.wait_for(function()
      local t = store.get(fake.dir(), "t1")
      return t and #t.messages == 2
    end, "reply stored")
    local m = store.get(fake.dir(), "t1").messages[2]
    assert.are.equal("user", m.author)
    assert.are.equal("this one\nand that", m.body)
  end)

  it("keymaps.input configures the box keys", function()
    require("beads").setup({ keymaps = { input = { submit = "<C-g>", send = "<M-g>" } } })
    open()
    local f, b = open_box("a")
    assert.is_not_nil(fake.buf_map(b, "n", "<C-g>"), "no normal <C-g>")
    assert.is_not_nil(fake.buf_map(b, "i", "<C-g>"), "no insert <C-g>")
    assert.is_not_nil(fake.buf_map(b, "n", "<M-g>"), "no normal <M-g>")
    assert.is_nil(fake.buf_map(b, "n", "<C-s>"), "<C-s> still mapped")
    assert.is_nil(fake.buf_map(b, "n", "<M-s>"), "<M-s> still mapped")
    fill(f, { "custom send" })
    fake.press("<M-g>")
    fake.wait_for(function()
      return #threads() == 1 and #pokes == 1
    end, "stored and poked with <M-g>")
  end)

  it("the box help (<leader>b?) lists <M-s>", function()
    open()
    open_box("a")
    local h = fake.press_for_float("<leader>b?")
    assert.is_not_nil(h, "<leader>b? opened no help float in the ask box")
    assert.is_truthy(fake.float_text(h):find("<M-s>", 1, true), fake.float_text(h))
  end)

  it("README documents the box and the reply notification", function()
    local text = table.concat(vim.fn.readfile(fake.repo .. "/README.md"), "\n")
    for _, want in ipairs({ "`<M-s>`", "open_after_send", "agent replied on" }) do
      assert.is_truthy(text:find(want, 1, true), "README.md lacks " .. want)
    end
  end)
end)
