-- Bead beads_nvim-y5w: ask polish (reply box send key, corrupt questions.json, error first line).
-- Interface under test:
--   * Thread float reply box (r): <M-s> saves the reply and pokes the agent through
--     require("agent-poke").poke (the same delivery as the ask box, workflow.deliver); <C-s> only
--     saves. The box title advertises <M-s>.
--   * Questions watcher: a corrupt or unreadable <root>/.beads-nvim/questions.json keeps the previous
--     snapshot; the next good read announces only replies new since that snapshot.
--   * require("beads.workflow").deliver(root, prompt, note): when agent-poke.poke fails, the warning
--     is "Beads: agent-poke failed: <first non-empty line of the error>".
-- agent-poke is stubbed through package.preload. bd is a fake on PATH (tests/questions_fake.lua).
--
-- assumption: the reply poke prompt contains the reply text and the thread id (so the agent can
--   answer with beads-ask reply <tid>).
-- assumption: only agent (non-human) threads are checked for <M-s>; human threads are not covered.
-- assumption: "unreadable" is a questions.json without read permission; "corrupt" is invalid JSON.
-- assumption: "first non-empty line" skips lines that are empty or whitespace only, and the line is
--   used as is (no trimming of a non-empty line is asserted).

local fake = require("tests.questions_fake")
local store = require("beads.questions.store")

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

local function sleep(ms)
  vim.wait(ms, function()
    return false
  end, 10)
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

local function open_reply_box()
  store.add(fake.dir(), { bead = "fx-1", messages = { { author = "agent", body = "Which one?" } } })
  local buf = fake.open_detail()
  fake.open_thread(buf, "Which one?")
  local f = fake.press_for_float("r")
  assert(f ~= nil, "r in the thread float opened no reply box")
  vim.api.nvim_set_current_win(f)
  pcall(vim.cmd, "stopinsert")
  return f, vim.api.nvim_win_get_buf(f)
end

describe("beads thread reply box send key", function()
  before_each(function()
    fake.setup()
    pokes = {}
    stub_poke()
    vim.ui.input = function(_, cb)
      cb(nil)
    end
    require("beads").setup({ ask = { open_after_send = false } })
  end)

  after_each(function()
    package.preload["agent-poke"] = nil
    package.loaded["agent-poke"] = nil
    fake.teardown()
    require("beads").setup({})
  end)

  it("<M-s> in the reply box saves the reply and pokes the agent", function()
    local f, b = open_reply_box()
    assert.is_not_nil(fake.buf_map(b, "n", "<M-s>"), "no normal-mode <M-s> map in the reply box")
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "use the second one", "because reasons" })
    vim.api.nvim_set_current_win(f)
    fake.press("<M-s>")
    fake.wait_for(function()
      local t = store.get(fake.dir(), "t1")
      return t and #t.messages == 2
    end, "reply stored after <M-s>")
    local m = store.get(fake.dir(), "t1").messages[2]
    assert.are.equal("user", m.author)
    assert.are.equal("use the second one\nbecause reasons", m.body)
    fake.wait_for(function()
      return #pokes == 1
    end, "agent poked after <M-s> in the reply box", 1500)
    assert.are.equal(fake.dir(), pokes[1].root)
    assert.is_truthy(pokes[1].prompt:find("use the second one", 1, true), "prompt lacks the reply:\n" .. pokes[1].prompt)
    assert.is_truthy(pokes[1].prompt:find("t1", 1, true), "prompt lacks the thread id:\n" .. pokes[1].prompt)
  end)

  -- passes already: guards that <C-s> in the reply box only saves.
  it("<C-s> in the reply box saves without poking", function()
    local f, b = open_reply_box()
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "just save" })
    vim.api.nvim_set_current_win(f)
    fake.press("<C-s>")
    fake.wait_for(function()
      local t = store.get(fake.dir(), "t1")
      return t and #t.messages == 2
    end, "reply stored after <C-s>")
    sleep(300)
    assert.are.equal(0, #pokes, "<C-s> poked the agent")
  end)

  -- passes already: guards that the reply box title advertises the send key.
  it("the reply box title advertises <M-s> send", function()
    local f = open_reply_box()
    local title = title_of(f)
    assert.is_truthy(title:find("<M-s> send", 1, true), "title: " .. title)
  end)
end)

describe("beads questions watcher with a bad questions.json", function()
  local notes

  local function path()
    return fake.dir() .. "/.beads-nvim/questions.json"
  end

  local function replied()
    local out = {}
    for _, n in ipairs(notes) do
      if n.msg:find("agent replied", 1, true) then
        out[#out + 1] = n.msg
      end
    end
    return out
  end

  -- Writes the file atomically (like beads-ask does) so the watcher sees one change.
  local function write_raw(s)
    local tmp = path() .. ".test.tmp"
    local f = assert(io.open(tmp, "w"))
    f:write(s)
    f:close()
    assert(vim.uv.fs_rename(tmp, path()))
  end

  -- Contents of questions.json with an extra agent message on t1.
  local function with_new_reply(good, body)
    local data = vim.json.decode(good)
    local list = data.threads or data
    for _, t in ipairs(list) do
      if t.id == "t1" then
        t.messages[#t.messages + 1] = { author = "agent", body = body }
      end
    end
    return vim.json.encode(data)
  end

  local function setup_answered()
    require("beads").setup({ notify_group_ms = 200 })
    store.add(fake.dir(), {
      bead = "fx-1",
      messages = { { author = "user", body = "Old question" }, { author = "agent", body = "Old reply" } },
    })
    local buf = fake.open_detail()
    fake.wait_question(buf, "Old question")
    sleep(400)
    notes = fake.capture_notify()
    local f = assert(io.open(path(), "r"))
    local good = f:read("*a")
    f:close()
    return good
  end

  local function check_only_new()
    fake.wait_for(function()
      return #replied() >= 1
    end, "an 'agent replied' notification", 2000)
    sleep(600)
    local got = replied()
    assert.are.equal(1, #got, table.concat(got, "\n---\n"))
    assert.is_truthy(got[1]:find("New reply", 1, true), got[1])
    assert.is_falsy(got[1]:find("Old reply", 1, true), "an earlier agent reply was announced again: " .. got[1])
  end

  before_each(function()
    fake.setup()
  end)

  after_each(function()
    pcall(vim.fn.setfperm, path(), "rw-r--r--")
    fake.teardown()
    require("beads").setup({})
  end)

  it("a corrupt read keeps the snapshot; the next good read announces only the new reply", function()
    local good = setup_answered()
    write_raw("{ this is not json")
    sleep(700)
    assert.are.same({}, replied())
    write_raw(with_new_reply(good, "New reply"))
    check_only_new()
  end)

  it("an unreadable file keeps the snapshot; the next good read announces only the new reply", function()
    local good = setup_answered()
    vim.fn.setfperm(path(), "---------")
    -- sanity: the file really is unreadable for this process
    assert.is_nil(io.open(path(), "r"), "questions.json is still readable (running as root?)")
    sleep(700)
    assert.are.same({}, replied())
    vim.fn.setfperm(path(), "rw-r--r--")
    write_raw(with_new_reply(good, "New reply"))
    check_only_new()
  end)
end)

describe("workflow.deliver poke failure warning", function()
  local orig_notify, notes

  before_each(function()
    orig_notify = vim.notify
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    package.loaded["agent-poke"] = nil
    package.preload["agent-poke"] = function()
      return {
        poke = function()
          error("\n  \nreal reason (test)\nsecond line", 0)
        end,
      }
    end
  end)

  after_each(function()
    vim.notify = orig_notify
    package.preload["agent-poke"] = nil
    package.loaded["agent-poke"] = nil
  end)

  it("uses the first non-empty line of an error that starts with a newline", function()
    require("beads.workflow").deliver(vim.fn.getcwd(), "prompt text", "question stored.")
    local warning
    for _, n in ipairs(notes) do
      if n.msg:find("agent-poke failed", 1, true) then
        warning = n.msg
      end
    end
    assert.is_not_nil(warning, "no agent-poke failure warning")
    assert.are.equal("Beads: agent-poke failed: real reason (test)", warning)
  end)
end)
