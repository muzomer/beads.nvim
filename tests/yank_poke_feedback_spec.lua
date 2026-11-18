-- Bead beads_nvim-4u9.9 (and notes from epic beads_nvim-4gx's review):
--   * yank feedback is consistent across tree / detail / pickers: each yank sets the " register
--     and gives one notification starting with "Beads: " that contains the yanked text;
--   * :Beads poke's prompt names the beads-ask CLI (like the ask prompt does) and is delivered by
--     the same helper as the ask flow, so without a working agent-poke the prompt is copied to the
--     " register (the ask flow's fallback) and the user is told so.
-- Uses tests/questions_waiting_fake.lua (fake bd on PATH; agent-poke stubbed via package.preload).
-- assumption: yank messages read "Beads: ..." and contain the yanked text verbatim.

local fake = require("tests.questions_waiting_fake")
-- fake.setup() changes the cwd; make plugin modules resolvable by absolute path
vim.opt.rtp:prepend(fake.repo)

local notes, orig_preload, orig_loaded

local function capture_notify()
  notes = {}
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = tostring(msg), level = level }
  end
end

local function notes_with(text)
  local out = {}
  for _, n in ipairs(notes) do
    if n.msg:find(text, 1, true) then
      out[#out + 1] = n
    end
  end
  return out
end

local function dump()
  local t = {}
  for _, n in ipairs(notes) do
    t[#t + 1] = n.msg
  end
  return table.concat(t, "\n---\n")
end

local function line_of(buf, text)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:find(text, 1, true) then
      return i
    end
  end
end

local function assert_yank_feedback(text, where)
  assert.are.equal(text, vim.fn.getreg('"'), where .. ": register not set")
  fake.wait_for(function()
    return #notes_with(text) > 0
  end, where .. ": yank notification", 1500)
  local got = notes_with(text)
  assert.are.equal(1, #got, where .. ": expected one yank notification:\n" .. dump())
  assert.is_truthy(vim.startswith(got[1].msg, "Beads: "), where .. ": yank message lacks 'Beads: ': " .. got[1].msg)
end

local function has_id(s, id)
  return s:find("%f[%w]" .. vim.pesc(id) .. "%f[^%w]") ~= nil
end

describe("yank feedback", function()
  before_each(function()
    fake.setup()
    capture_notify()
    vim.fn.setreg('"', "")
  end)

  after_each(function()
    fake.teardown()
  end)

  it("picker yank notifies 'Beads: ...' with the text", function()
    require("beads.views.picker").yank("pl-7")
    assert_yank_feedback("pl-7", "picker")
  end)

  it("tree yy notifies 'Beads: ...' with the id", function()
    vim.cmd("Beads tree")
    local buf
    fake.wait_for(function()
      buf = vim.api.nvim_get_current_buf()
      return vim.bo[buf].filetype == "beads-tree" and line_of(buf, "pl-7") ~= nil
    end, "tree to list pl-7")
    vim.api.nvim_win_set_cursor(0, { line_of(buf, "pl-7"), 0 })
    notes = {}
    fake.press("yy")
    assert_yank_feedback("pl-7", "tree")
  end)

  it("detail yy notifies 'Beads: ...' with the id", function()
    vim.cmd.edit("beads://pl-7")
    local buf = vim.api.nvim_get_current_buf()
    fake.wait_for(function()
      return require("beads.views.detail").snapshot(buf) ~= nil
    end, "detail load")
    notes = {}
    fake.press("yy")
    assert_yank_feedback("pl-7", "detail")
  end)
end)

describe(":Beads poke prompt and delivery", function()
  local calls

  before_each(function()
    orig_preload = package.preload["agent-poke"]
    orig_loaded = package.loaded["agent-poke"]
    fake.setup()
    capture_notify()
    vim.fn.setreg('"', "")
  end)

  after_each(function()
    fake.teardown()
    package.preload["agent-poke"] = orig_preload
    package.loaded["agent-poke"] = orig_loaded
  end)

  local function install(poke)
    calls = {}
    package.loaded["agent-poke"] = nil
    package.preload["agent-poke"] = function()
      return {
        poke = poke or function(...)
          calls[#calls + 1] = { ... }
        end,
        pick = function() end,
        output = function() end,
        chat = function() end,
      }
    end
  end

  it("the poke prompt names the beads-ask CLI", function()
    local ids = fake.write_threads()
    install()
    vim.cmd("Beads poke")
    fake.wait_for(function()
      return #calls > 0
    end, "agent-poke.poke", 2000)
    local prompt = calls[1][2]
    assert.is_true(has_id(prompt, ids.ag), "prompt does not name " .. ids.ag .. ":\n" .. prompt)
    assert.is_truthy(prompt:find("beads-ask", 1, true), "prompt does not name the beads-ask CLI:\n" .. prompt)
  end)

  it("without agent-poke, the poke prompt is copied to the \" register", function()
    local ids = fake.write_threads()
    package.loaded["agent-poke"] = nil
    package.preload["agent-poke"] = function()
      error("agent-poke is not installed (test)")
    end
    vim.cmd("Beads poke")
    fake.wait_for(function()
      return #notes > 0
    end, "a notification", 2000)
    local reg = vim.fn.getreg('"')
    assert.is_true(has_id(reg, ids.ag), "register does not hold the prompt naming " .. ids.ag .. ": " .. reg)
    assert.is_truthy(reg:find("beads-ask", 1, true), "register prompt does not name beads-ask: " .. reg)
    local text = dump()
    assert.is_truthy(text:find("agent-poke", 1, true), "no hint mentioning agent-poke:\n" .. text)
    for _, n in ipairs(notes) do
      assert.is_truthy(vim.startswith(n.msg, "Beads: "), "message lacks 'Beads: ': " .. n.msg)
    end
  end)

  it("when agent-poke.poke fails, the poke prompt is copied to the \" register", function()
    local ids = fake.write_threads()
    install(function()
      error("no agent session (test)")
    end)
    local ok, err = pcall(vim.cmd, "Beads poke")
    assert.is_true(ok, ":Beads poke errored: " .. tostring(err))
    fake.wait_for(function()
      return has_id(vim.fn.getreg('"'), ids.ag)
    end, "prompt in the \" register", 2000)
    assert.is_truthy(vim.fn.getreg('"'):find("beads-ask", 1, true))
  end)
end)
