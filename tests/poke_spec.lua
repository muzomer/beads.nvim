-- Bead beads_nvim-4gx.7: :Beads poke [pick] / output / chat pass-through to agent-poke.nvim.
-- Interface under test (agent-poke v0.1.0 API, keyed by project root):
--   :Beads poke        -> require("agent-poke").poke(root, prompt, opts?) once, prompt naming every
--                         open thread waiting on the agent (needs = "agent"); none -> no call + notify.
--   :Beads poke pick   -> require("agent-poke").pick(root)
--   :Beads output      -> require("agent-poke").output(root)
--   :Beads chat        -> require("agent-poke").chat(root)
--   global <leader>bp (keymaps.poke) = :Beads poke, <leader>bP (keymaps.output) = :Beads output.
--   Without agent-poke, each command notifies an install hint mentioning "agent-poke" and does not error.
-- root = require("beads.cli").get_root() (the fake's temp dir). agent-poke is stubbed via package.preload.
-- Assumptions: threads are named by their thread id; the "none waiting" message mentions
-- "thread" or "waiting"; the install hint mentions "agent-poke".

local fake = require("tests.questions_waiting_fake")
local qstore = require("beads.questions.store")

local calls
local notes
local orig_preload, orig_loaded

local function stub_agent_poke()
  calls = { poke = {}, pick = {}, output = {}, chat = {} }
  package.loaded["agent-poke"] = nil
  package.preload["agent-poke"] = function()
    local m = {}
    for name in pairs(calls) do
      m[name] = function(...)
        local log = calls[name]
        log[#log + 1] = { ... }
      end
    end
    m.setup = function() end
    m.stop = function() end
    return m
  end
end

local function no_agent_poke()
  package.loaded["agent-poke"] = nil
  package.preload["agent-poke"] = function()
    error("agent-poke is not installed (test)")
  end
end

local function capture_notify()
  notes = {}
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = tostring(msg), level = level }
  end
end

local function notes_text()
  local t = {}
  for _, n in ipairs(notes) do
    t[#t + 1] = n.msg
  end
  return table.concat(t, "\n")
end

local function settle()
  vim.wait(200, function()
    return false
  end, 10)
end

local function wait_calls(name, what)
  fake.wait_for(function()
    return #calls[name] > 0
  end, what or ("agent-poke." .. name .. " call"), 2000)
  settle()
end

local function has_id(s, id)
  return s:find("%f[%w]" .. vim.pesc(id) .. "%f[^%w]") ~= nil
end

describe(":Beads poke/output/chat", function()
  before_each(function()
    orig_preload = package.preload["agent-poke"]
    orig_loaded = package.loaded["agent-poke"]
    fake.setup()
    stub_agent_poke()
    capture_notify()
  end)

  after_each(function()
    fake.teardown()
    package.preload["agent-poke"] = orig_preload
    package.loaded["agent-poke"] = orig_loaded
  end)

  it(":Beads poke sends one prompt naming the threads waiting on the agent", function()
    local ids = fake.write_threads()
    local extra = qstore.add(fake.dir(), {
      bead = "pl-7",
      messages = {
        { author = "agent", body = "Golf ask" },
        { author = "user", body = "golf answer" },
      },
    }).id
    assert.are.equal("agent", qstore.get(fake.dir(), extra).needs)
    vim.cmd("Beads poke")
    wait_calls("poke", "agent-poke.poke")
    assert.are.equal(1, #calls.poke, "poke called " .. #calls.poke .. " times")
    local args = calls.poke[1]
    assert.are.equal(fake.dir(), args[1], "poke not called for the current root")
    local prompt = args[2]
    assert.are.equal("string", type(prompt), "prompt is not a string")
    assert.is_true(has_id(prompt, ids.ag), "prompt does not name waiting thread " .. ids.ag .. ":\n" .. prompt)
    assert.is_true(has_id(prompt, extra), "prompt does not name waiting thread " .. extra .. ":\n" .. prompt)
    for _, k in ipairs({ "a", "b", "rs", "cl" }) do
      assert.is_false(has_id(prompt, ids[k]), "prompt names non-waiting thread " .. ids[k] .. ":\n" .. prompt)
    end
    assert.are.equal(0, #calls.pick)
  end)

  it(":Beads poke with no thread waiting on the agent sends nothing and says so", function()
    qstore.add(fake.dir(), { bead = "qa-1", messages = { { author = "agent", body = "Only user turn" } } })
    vim.cmd("Beads poke")
    local function said()
      for _, n in ipairs(notes) do
        local m = n.msg:lower()
        if (m:find("thread", 1, true) or m:find("waiting", 1, true)) and not n.msg:find("Usage", 1, true) then
          return true
        end
      end
      return false
    end
    vim.wait(1500, said, 10)
    assert.is_true(said(), "no 'nothing waiting' message; notifications:\n" .. notes_text())
    settle()
    assert.are.equal(0, #calls.poke, "poke was called with nothing waiting")
  end)

  it(":Beads poke pick calls agent-poke.pick(root)", function()
    fake.write_threads()
    vim.cmd("Beads poke pick")
    wait_calls("pick", "agent-poke.pick")
    assert.are.equal(1, #calls.pick)
    assert.are.equal(fake.dir(), calls.pick[1][1])
    assert.are.equal(0, #calls.poke, "poke pick also poked")
  end)

  for _, sub in ipairs({ "output", "chat" }) do
    it(":Beads " .. sub .. " calls agent-poke." .. sub .. "(root)", function()
      vim.cmd("Beads " .. sub)
      wait_calls(sub)
      assert.are.equal(1, #calls[sub])
      assert.are.equal(fake.dir(), calls[sub][1][1])
      assert.are.equal(0, #calls.poke)
    end)
  end

  it("completion lists poke, output and chat", function()
    local items = vim.fn.getcompletion("Beads ", "cmdline")
    for _, s in ipairs({ "poke", "output", "chat" }) do
      assert.is_true(vim.tbl_contains(items, s), s .. " not completed; got: " .. table.concat(items, ", "))
    end
    assert.are.same({ "poke" }, vim.fn.getcompletion("Beads po", "cmdline"))
  end)

  for _, cmd in ipairs({ "poke", "poke pick", "output", "chat" }) do
    it("without agent-poke, :Beads " .. cmd .. " shows an install hint and does not error", function()
      fake.write_threads()
      no_agent_poke()
      local ok, err = pcall(vim.cmd, "Beads " .. cmd)
      assert.is_true(ok, ":Beads " .. cmd .. " errored: " .. tostring(err))
      vim.wait(1500, function()
        return notes_text():find("agent-poke", 1, true) ~= nil
      end, 10)
      local text = notes_text()
      assert.is_truthy(text:find("agent-poke", 1, true), "no install hint mentioning agent-poke:\n" .. text)
    end)
  end

  it("<leader>bp pokes and <leader>bP shows the output", function()
    fake.write_threads()
    vim.cmd.enew()
    fake.press("<leader>bp")
    wait_calls("poke", "agent-poke.poke from <leader>bp")
    assert.are.equal(1, #calls.poke)
    assert.are.equal(fake.dir(), calls.poke[1][1])
    fake.press("<leader>bP")
    wait_calls("output", "agent-poke.output from <leader>bP")
    assert.are.equal(1, #calls.output)
    assert.are.equal(fake.dir(), calls.output[1][1])
    for _, k in ipairs({ "<leader>bp", "<leader>bP" }) do
      local m = vim.fn.maparg(k, "n", false, true)
      assert.is_true(type(m.desc) == "string" and m.desc ~= "", k .. " has no desc")
    end
  end)

  it("keymaps.poke and keymaps.output remap the global keys", function()
    require("beads").setup({ keymaps = { poke = "<F7>", output = false } })
    fake.write_threads()
    vim.cmd.enew()
    assert.are.same({}, vim.fn.maparg("<leader>bp", "n", false, true), "<leader>bp still mapped after override")
    assert.are.same({}, vim.fn.maparg("<leader>bP", "n", false, true), "<leader>bP mapped with output = false")
    fake.press("<F7>")
    wait_calls("poke", "agent-poke.poke from <F7>")
    assert.are.equal(1, #calls.poke)
  end)
end)
