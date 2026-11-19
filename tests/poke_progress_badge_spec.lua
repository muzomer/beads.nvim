-- Bead beads_nvim-r6s: tree and detail show the waiting state of a sent question; no multiplexer.
-- Interface under test (black box): beads from tests/questions_waiting_fake.lua; the user replies
-- with <M-s> in the thread float of ag-2 (its only thread needs the agent, so it has no 💬 today).
-- A fake agent-poke (tests/poke_progress_fake.lua) reports the stage through AgentPokeProgress.
--   * while the question is sent/queued/working, the ag-2 tree line and the detail view of ag-2 show
--     💬 with an animated spinner next to it;
--   * the spinner stops when the reply arrives (and its timers stop);
--   * another thread of the same bead does not show the stage in its float;
--   * without agent-poke the tree line has no spinner;
--   * lua/ and plugin/ name no multiplexer (only the existing fzf-tmux comment).
--
-- assumption: in the tree the spinner is part of the ag-2 row: its text or its extmark virt_text.
-- assumption: in the detail view it shows in the winbar (detail.winbar(win), highlights stripped)
--   or on the thread's Questions row (text or extmark virt_text), with 💬 in the same place.
-- assumption: "spinner" = that text changes within 2 s; frames are not pinned. "No spinner" = it
--   stays the same for 1.5 s.
-- assumption: a bead that waits on the agent shows 💬 while its question is pending, even though
--   💬 otherwise means "waiting on you"; after the reply 💬 stays (the thread now needs the user).

local fake = require("tests.questions_waiting_fake")
local poke = require("tests.poke_progress_fake")
local qstore = require("beads.questions.store")

local GLYPH = "💬"
local REPLYING = "agent is replying…"

local function tree_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "beads-tree" then
      return w
    end
  end
end

local function open_tree()
  vim.cmd("Beads tree")
  local w
  fake.wait_for(function()
    w = tree_win()
    return w ~= nil
  end, "the tree window")
  return w
end

-- Displayed text (with virtual text) of the tree row of id, or nil.
local function tree_row(w, id)
  local buf = vim.api.nvim_win_get_buf(w)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:match("^[%s│├└─▾▸]*%S+%s+" .. vim.pesc(id) .. "%s") then
      return poke.row_text(buf, i)
    end
  end
end

local function detail_snapshot(buf)
  return require("beads.views.detail").snapshot(buf)
end

local function open_detail(id)
  vim.cmd("edit beads://" .. id)
  local buf = vim.api.nvim_get_current_buf()
  fake.wait_for(function()
    local s = detail_snapshot(buf)
    return s ~= nil and s.threads ~= nil and #s.threads > 0 and not vim.bo[buf].modified
  end, "detail buffer of " .. id)
  return buf
end

local function question_row(buf, text)
  local start
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l == "## Questions" then
      start = i
    elseif start and l:find(text, 1, true) then
      return i
    end
  end
end

-- Opens the thread float of the Questions line containing text.
local function open_thread(buf, text)
  local n
  fake.wait_for(function()
    n = question_row(buf, text)
    return n ~= nil
  end, "Questions line '" .. text .. "'")
  local win = vim.fn.bufwinid(buf)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { n, 0 })
  fake.press("<CR>")
  local f
  fake.wait_for(function()
    f = poke.thread_float()
    return f ~= nil
  end, "the thread float")
  vim.api.nvim_set_current_win(f)
  return f
end

local function send_reply(text, no_poke)
  vim.ui.input = function(_, cb)
    cb(nil)
  end
  local before = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    before[w] = true
  end
  fake.press("r")
  local f
  fake.wait_for(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if not before[w] and vim.api.nvim_win_get_config(w).relative ~= "" then
        f = w
        return true
      end
    end
  end, "the reply box")
  pcall(vim.cmd, "stopinsert")
  vim.api.nvim_set_current_win(f)
  vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(f), 0, -1, false, { text })
  fake.press("<M-s>")
  if no_poke then
    return
  end
  fake.wait_for(function()
    return #poke.pokes() == 1
  end, "agent-poke.poke called")
end

-- What the detail view shows of its waiting state: winbar and the thread's Questions row.
local function detail_places(buf, text)
  local win = vim.fn.bufwinid(buf)
  local bar = (require("beads.views.detail").winbar(win) or ""):gsub("%%#[^#]*#", "")
  local n = question_row(buf, text)
  return { winbar = bar, row = n and poke.row_text(buf, n) or "" }
end

-- Waits until get() returns text containing 💬 that changes within 2 s.
local function assert_spinner(get, what)
  local seen, n, last = {}, 0, nil
  vim.wait(3000, function()
    local t = get()
    last = t
    if t and t:find(GLYPH, 1, true) and not seen[t] then
      seen[t] = true
      n = n + 1
    end
    return n >= 2
  end, 20)
  assert(n >= 2, ("%s shows no 💬 spinner: %s"):format(what, tostring(last)))
end

local function assert_static(get, what)
  local first = get()
  poke.sleep(1500)
  assert.are.equal(first, get(), what .. " still changes (spinner left running)")
end

local function agent_reply(tid, body)
  local r = vim
    .system({ fake.repo .. "/bin/beads-ask", "reply", tid, body }, {
      env = { BEADS_NVIM_ROOT = fake.dir(), BEADS_NVIM_NVIM = vim.v.progpath },
      text = true,
    })
    :wait(10000)
  assert.are.equal(0, r.code, "beads-ask reply failed: " .. tostring(r.stderr))
end

describe("waiting state in tree and detail", function()
  local ids

  before_each(function()
    fake.setup()
    ids = fake.write_threads()
  end)

  after_each(function()
    fake.teardown()
    poke.uninstall()
  end)

  it("tree and detail show 💬 with a spinner while working; it stops when the reply arrives", function()
    poke.install({ status = "started", id = "b1", stage = "queued", target = "background" })
    local buf = open_detail("ag-2")
    local base
    vim.wait(500, function()
      return false
    end, 10)
    base = poke.timers_now()
    open_thread(buf, "Agent turn bravo")
    send_reply("Go ahead bravo")
    poke.fire("b1", poke.pokes()[1].root, "working", "background")
    local function winbar_or_row()
      if not vim.api.nvim_buf_is_valid(buf) then
        return nil
      end
      local p = detail_places(buf, "Agent turn bravo")
      local hit = {}
      for _, s in ipairs({ p.winbar, p.row }) do
        if s:find(GLYPH, 1, true) then
          hit[#hit + 1] = s
        end
      end
      return #hit > 0 and table.concat(hit, " | ") or (p.winbar .. " | " .. p.row)
    end
    assert_spinner(winbar_or_row, "the detail view of ag-2")
    local t = open_tree()
    assert_spinner(function()
      return tree_row(t, "ag-2")
    end, "the tree line of ag-2")
    local qa = tree_row(t, "qa-1")
    assert.is_truthy(qa, "no tree line for qa-1")

    agent_reply(ids.ag, "Done bravo")
    poke.fire("b1", poke.pokes()[1].root, "done", "background")
    fake.wait_for(function()
      local th = qstore.list(fake.dir(), { bead = "ag-2" })[1]
      return th and th.messages[#th.messages].body == "Done bravo"
    end, "the reply stored")
    poke.sleep(1000)
    assert_static(function()
      return tree_row(t, "ag-2")
    end, "the tree line of ag-2")
    assert_static(winbar_or_row, "the detail view of ag-2")
    local ok = vim.wait(3000, function()
      return poke.active_timers() <= base
    end, 20)
    assert(ok, ("timers still running after the reply: %d active, %d before"):format(poke.timers_now(), base))
  end)

  it("another thread of the same bead does not show the stage", function()
    poke.install({ status = "started", id = "b2", stage = "working", target = "background" })
    local buf = open_detail("qa-1")
    open_thread(buf, "Stored ask alpha")
    send_reply("Reply on alpha")
    local w
    fake.wait_for(function()
      w = poke.thread_float()
      return w and table.concat(poke.display_lines(vim.api.nvim_win_get_buf(w)), "\n"):find(REPLYING, 1, true)
    end, "'" .. REPLYING .. "' in the float of thread A")
    vim.api.nvim_win_close(w, true)
    local f = open_thread(buf, "Second ask alpha")
    poke.sleep(300)
    local text = table.concat(poke.display_lines(vim.api.nvim_win_get_buf(f)), "\n")
    assert.is_truthy(text:find("Follow-up alpha", 1, true), "not thread B:\n" .. text)
    assert.is_falsy(text:find(REPLYING, 1, true), "thread B shows thread A's stage:\n" .. text)
  end)

  -- passes already: guards that without agent-poke nothing animates and no 💬 is added.
  it("without agent-poke the tree line has no spinner", function()
    poke.install_missing()
    local notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    local buf = open_detail("ag-2")
    open_thread(buf, "Agent turn bravo")
    send_reply("Go ahead bravo", true)
    fake.wait_for(function()
      local th = qstore.list(fake.dir(), { bead = "ag-2" })[1]
      return th and th.messages[#th.messages].body == "Go ahead bravo"
    end, "the reply stored")
    local t = open_tree()
    fake.wait_for(function()
      return tree_row(t, "ag-2") ~= nil
    end, "the tree line of ag-2")
    assert_static(function()
      return tree_row(t, "ag-2")
    end, "the tree line of ag-2")
    assert.is_falsy(tree_row(t, "ag-2"):find(GLYPH, 1, true), "ag-2 shows 💬: " .. tree_row(t, "ag-2"))
    for _, n in ipairs(notes) do
      assert.are_not.equal(vim.log.levels.ERROR, n.level, "error: " .. n.msg)
    end
  end)
end)

-- passes already: guards that beads.nvim names no multiplexer.
describe("no multiplexer in beads.nvim code", function()
  it("lua/ and plugin/ name no multiplexer or pane (only the existing fzf-tmux comment)", function()
    local files = vim.fn.globpath(fake.repo, "lua/**/*.lua", false, true)
    vim.list_extend(files, vim.fn.globpath(fake.repo, "plugin/**/*.lua", false, true))
    assert.is_true(#files > 0)
    local bad = {}
    for _, f in ipairs(files) do
      for n, line in ipairs(vim.fn.readfile(f)) do
        local l = line:lower():gsub("fzf%-tmux", "")
        for _, word in ipairs({ "herdr", "tmux", "zellij", "wezterm" }) do
          if l:find(word, 1, true) then
            bad[#bad + 1] = ("%s:%d: %s"):format(f, n, line)
          end
        end
        if l:find("%f[%a]panes?%f[%A]") then
          bad[#bad + 1] = ("%s:%d: %s"):format(f, n, line)
        end
      end
    end
    assert.are.same({}, bad)
  end)
end)
