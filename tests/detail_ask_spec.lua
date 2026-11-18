-- Bead beads_nvim-4gx.5: ask flow from the detail buffer (a on a section or a selection).
-- Interface under test:
--   * VIEW mode key keymaps.detail.view.ask (default "a"), buffer-local in normal mode (section
--     under the cursor) and visual mode (the selected text becomes the thread's quote).
--   * It asks for the question in the ask box (bead beads_nvim-tch: a floating input box, never
--     vim.ui.input). <C-s> saves; <M-s> (keymaps.input.send) saves and sends. A non-empty question
--     stores a thread through beads.questions.store
--     ({ bead, section, quote, messages = { { author = "user", body } } }); sending calls
--     require("agent-poke").poke(root, prompt[, opts]).
--   * agent-poke.nvim is stubbed through package.preload (prompt captured). When it cannot be
--     required the thread is still stored and the user is notified how to deliver it.
--   * agent-poke is required at ask time (not cached at setup or module load).
--   * The prompt holds the rendered bead plus the section and quote, so the quote and the section
--     name appear at least twice in it.
-- bd is a fake on PATH (tests/questions_fake.lua).

local fake = require("tests.questions_fake")
local store = require("beads.questions.store")

local AC = "must keep data safe"
local pokes

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

local function no_poke()
  package.loaded["agent-poke"] = nil
  package.preload["agent-poke"] = function()
    error("module 'agent-poke' not found (test: not installed)")
  end
end

-- Line number of the first buffer line equal to text.
local function line_of(buf, text)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l == text then
      return i
    end
  end
  error("no line '" .. text .. "' in the detail buffer")
end

-- Presses keys in the detail window and answers in the ask box (filled, then submitted with
-- submit: "<C-s>" saves, "<M-s>" saves and sends; default "<M-s>"). vim.ui.input must not be used.
local function ask(keys, text, submit)
  local asked = false
  vim.ui.input = function(_, cb)
    asked = true
    cb(nil)
  end
  local f = fake.press_for_float(keys)
  assert(not asked, "pressing " .. keys .. " used vim.ui.input instead of the ask box")
  assert(f ~= nil, "pressing " .. keys .. " opened no ask box")
  vim.api.nvim_set_current_win(f)
  local b = vim.api.nvim_win_get_buf(f)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.split(text, "\n", { plain = true }))
  fake.press(submit or "<M-s>")
end

local function threads()
  return store.list(fake.dir(), { bead = "fx-1" })
end

local function open()
  local buf = fake.open_detail()
  local win = vim.fn.bufwinid(buf)
  vim.api.nvim_set_current_win(win)
  return buf, win
end

describe("beads detail ask flow", function()
  before_each(function()
    fake.setup()
    fake.write_bead({
      acceptance_criteria = AC,
      dependencies = {
        { id = "fx-0", depends_on_id = "fx-0", dependency_type = "parent-child" },
        { id = "fx-9", depends_on_id = "fx-9", dependency_type = "blocks" },
      },
    })
    pokes = {}
    stub_poke()
    require("beads").setup({})
  end)

  after_each(function()
    package.preload["agent-poke"] = nil
    package.loaded["agent-poke"] = nil
    fake.teardown()
  end)

  it("binds a (keymaps.detail.view.ask) in VIEW mode, normal and visual", function()
    local buf = open()
    assert.are.equal("a", require("beads.keys").first("detail_view", "ask") or "(none)")
    assert.is_not_nil(fake.buf_map(buf, "n", "a"), "no buffer-local normal map for a")
    assert.is_not_nil(fake.buf_map(buf, "x", "a"), "no buffer-local visual map for a")
  end)

  it("a on the Acceptance section stores a thread with section 'acceptance' and pokes", function()
    local buf, win = open()
    vim.api.nvim_win_set_cursor(win, { line_of(buf, AC), 0 })
    ask("a", "Is data loss ever acceptable?")
    fake.wait_for(function()
      return #threads() == 1
    end, "thread stored")
    local t = threads()[1]
    assert.are.equal("fx-1", t.bead)
    assert.are.equal("acceptance", t.section)
    assert.is_truthy(t.messages[1], "thread has no message")
    assert.are.equal("user", t.messages[1].author)
    assert.is_truthy(t.messages[1].body:find("Is data loss ever acceptable?", 1, true), t.messages[1].body)
    assert.are.equal("agent", t.needs)
    fake.wait_for(function()
      return #pokes == 1
    end, "agent-poke.poke called")
    assert.are.equal(fake.dir(), vim.fn.resolve(pokes[1].root))
  end)

  it("visual a stores the selected text as quote", function()
    local buf, win = open()
    local n = line_of(buf, AC)
    -- "must keep data safe": select "keep data" (cols 5..13)
    vim.api.nvim_win_set_cursor(win, { n, 5 })
    ask("v8la", "Keep it where?")
    fake.wait_for(function()
      return #threads() == 1
    end, "thread stored")
    local t = threads()[1]
    assert.are.equal("keep data", t.quote)
    assert.are.equal("acceptance", t.section)
  end)

  it("the poked prompt has id, title, section, quote, parent, blocker, question and beads-ask instructions", function()
    local buf, win = open()
    line_of(buf, "parent: fx-0") -- fixture sanity: parent and blocker are loaded
    line_of(buf, "blocked_by: [fx-9]")
    vim.api.nvim_win_set_cursor(win, { line_of(buf, AC), 5 })
    ask("v8la", "Which store counts as safe?")
    fake.wait_for(function()
      return #pokes == 1
    end, "agent-poke.poke called")
    local p = pokes[1].prompt
    assert.are.equal("string", type(p))
    local t = threads()[1]
    local function count(hay, needle)
      local n, i = 0, 1
      while true do
        local a, b = hay:find(needle, i, true)
        if not a then
          return n
        end
        n, i = n + 1, b + 1
      end
    end
    assert.is_true(count(p, "keep data") >= 2, "prompt lacks the quote beyond the rendered bead:\n" .. p)
    assert.is_true(count(p:lower(), "acceptance") >= 2, "prompt lacks the section beyond the rendered bead:\n" .. p)
    for _, want in ipairs({
      "fx-1",
      fake.TITLE,
      "## Workflow",
      "fx-0",
      "fx-9",
      "Which store counts as safe?",
      "beads-ask reply",
      "propose",
      t.id,
    }) do
      assert.is_truthy(p:find(want, 1, true), "prompt lacks '" .. want .. "':\n" .. p)
    end
  end)

  it("an empty question stores nothing and pokes nothing", function()
    local buf, win = open()
    vim.api.nvim_win_set_cursor(win, { line_of(buf, AC), 0 })
    ask("a", "")
    vim.wait(300, function()
      return #pokes > 0 or #threads() > 0
    end, 10)
    assert.are.equal(0, #threads())
    assert.are.equal(0, #pokes)
  end)

  it("without agent-poke the thread is stored and the user is told how to deliver it", function()
    no_poke()
    local got = fake.capture_notify()
    vim.fn.setreg('"', "")
    local buf, win = open()
    vim.api.nvim_win_set_cursor(win, { line_of(buf, AC), 0 })
    ask("a", "Fallback question?")
    fake.wait_for(function()
      return #threads() == 1
    end, "thread stored")
    fake.wait_for(function()
      for _, g in ipairs(got) do
        if g.msg:find("agent-poke", 1, true) then
          return true
        end
      end
    end, "a notification mentioning agent-poke")
    local copied = vim.fn.getreg('"'):find("Fallback question?", 1, true)
    for _, g in ipairs(got) do
      copied = copied or g.msg:find("Fallback question?", 1, true)
    end
    assert.is_truthy(copied, "the prompt was neither copied to the \" register nor shown")
  end)
end)
