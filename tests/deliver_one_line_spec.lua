-- Bead beads_nvim-5pz: the fallback ask notification is one line; the prompt is only in the " register.
-- Interface under test:
--   * require("beads.workflow").deliver(root, prompt, note)
--       - agent-poke unavailable: the " register holds the full prompt and exactly one notification
--         is shown: 'Beads: <note> agent-poke is not available; the prompt is in the " register.'
--         (without a note: 'Beads: agent-poke is not available; the prompt is in the " register.').
--       - agent-poke.poke fails: the failure warning is one line (the error's first line).
--   * The detail ask flow (send with <M-s>) uses note "question stored.".
-- agent-poke is stubbed via package.preload; bd is a fake on PATH (tests/questions_fake.lua).

local fake = require("tests.questions_fake")

local AC = "must keep data safe"
local PROMPT = "Bead fx-1: Title\n\nQuestion: why?\n\nAnswer with the beads-ask CLI:\n  beads-ask reply <thread-id> <body|->"
local MSG_NOTE = 'Beads: question stored. agent-poke is not available; the prompt is in the " register.'
local MSG_PLAIN = 'Beads: agent-poke is not available; the prompt is in the " register.'

local orig_notify, orig_preload, orig_loaded, orig_input
local notes

local function capture()
  notes = {}
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = tostring(msg), level = level }
  end
end

local function no_poke()
  package.loaded["agent-poke"] = nil
  package.preload["agent-poke"] = function()
    error("module 'agent-poke' not found (test: not installed)")
  end
end

local function failing_poke()
  package.loaded["agent-poke"] = nil
  package.preload["agent-poke"] = function()
    return {
      poke = function()
        error("no agent session (test)\nsecond line of the error\nthird line", 0)
      end,
    }
  end
end

local function dump()
  local out = {}
  for i, n in ipairs(notes) do
    out[#out + 1] = i .. ": " .. vim.inspect(n.msg)
  end
  return table.concat(out, "\n")
end

local function save()
  orig_notify = vim.notify
  orig_input = vim.ui.input
  orig_preload = package.preload["agent-poke"]
  orig_loaded = package.loaded["agent-poke"]
end

local function restore()
  vim.notify = orig_notify
  vim.ui.input = orig_input
  package.preload["agent-poke"] = orig_preload
  package.loaded["agent-poke"] = orig_loaded
end

describe("workflow.deliver fallback notification", function()
  before_each(function()
    save()
    capture()
    vim.fn.setreg('"', "")
  end)

  after_each(restore)

  it("without agent-poke shows exactly one single-line notification naming the note", function()
    no_poke()
    require("beads.workflow").deliver(vim.fn.getcwd(), PROMPT, "question stored.")
    assert.are.equal(1, #notes, "expected exactly one notification, got:\n" .. dump())
    assert.is_nil(notes[1].msg:find("\n", 1, true), "notification has a newline:\n" .. dump())
    assert.are.equal(MSG_NOTE, notes[1].msg)
  end)

  it("without agent-poke and without a note the message has no lead-in", function()
    no_poke()
    require("beads.workflow").deliver(vim.fn.getcwd(), PROMPT, nil)
    assert.are.equal(1, #notes, "expected exactly one notification, got:\n" .. dump())
    assert.are.equal(MSG_PLAIN, notes[1].msg)
  end)

  it("without agent-poke the \" register still holds the full prompt", function()
    no_poke()
    require("beads.workflow").deliver(vim.fn.getcwd(), PROMPT, "question stored.")
    assert.are.equal(PROMPT, vim.fn.getreg('"'))
  end)

  it("when agent-poke fails the failure warning is one line (the error's first line)", function()
    failing_poke()
    require("beads.workflow").deliver(vim.fn.getcwd(), PROMPT, "question stored.")
    local warning
    for _, n in ipairs(notes) do
      if n.msg:find("agent-poke failed", 1, true) then
        warning = n.msg
      end
    end
    assert.is_not_nil(warning, "no agent-poke failure warning:\n" .. dump())
    assert.are.equal("Beads: agent-poke failed: no agent session (test)", warning)
    for _, n in ipairs(notes) do
      assert.is_nil(n.msg:find("\n", 1, true), "a notification has a newline:\n" .. dump())
    end
    assert.are.equal(PROMPT, vim.fn.getreg('"'))
  end)
end)

describe("detail ask without agent-poke", function()
  local function line_of(buf, text)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if l == text then
        return i
      end
    end
    error("no line '" .. text .. "' in the detail buffer")
  end

  before_each(function()
    save()
    fake.setup()
    fake.write_bead({ acceptance_criteria = AC })
    no_poke()
    require("beads").setup({})
  end)

  after_each(function()
    fake.teardown()
    restore()
  end)

  it("asking a question shows one single-line notification and copies the prompt", function()
    local buf = fake.open_detail()
    local win = vim.fn.bufwinid(buf)
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { line_of(buf, AC), 0 })
    capture()
    vim.fn.setreg('"', "")
    vim.ui.input = function(_, cb)
      cb(nil)
    end
    local f = fake.press_for_float("a")
    assert(f ~= nil, "pressing a opened no ask box")
    vim.api.nvim_set_current_win(f)
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(f), 0, -1, false, { "One line please?" })
    fake.press("<M-s>")
    fake.wait_for(function()
      return vim.fn.getreg('"'):find("One line please?", 1, true) ~= nil
    end, "the prompt in the \" register")
    vim.wait(200)
    assert.are.equal(1, #notes, "expected exactly one notification, got:\n" .. dump())
    assert.are.equal(MSG_NOTE, notes[1].msg)
    local reg = vim.fn.getreg('"')
    assert.is_truthy(reg:find("beads-ask", 1, true), "register prompt lacks beads-ask instructions:\n" .. reg)
    assert.is_truthy(reg:find(AC, 1, true), "register prompt lacks the bead text:\n" .. reg)
  end)
end)
