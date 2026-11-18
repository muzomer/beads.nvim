-- Bead beads_nvim-4gx.6: :Beads questions picker and the global <leader>bq.
-- Interface under test:
--   * :Beads questions lists every open thread with needs == "user" on non-closed beads: stored
--     threads (beads.questions.store) plus human threads (beads.questions.human.list). One item
--     per thread; its picker line contains the bead id and the first line of the thread's first
--     message.
--   * Without fzf-lua: vim.ui.select (items read through format_item); choosing an item opens
--     beads://<id> with the cursor on that thread's line in the Questions section.
--   * With fzf-lua: fzf_exec(lines, opts); opts.preview(selected) returns the conversation (all
--     message bodies); opts.actions.default(selected) opens beads://<id> at the thread line.
--   * Global key: keymaps.questions, default "<leader>bq", opens the same picker.
-- bd is a fake on PATH; fixture in tests/questions_waiting_fake.lua.

local fake = require("tests.questions_waiting_fake")

local IN = { "Stored ask alpha", "Second ask alpha", "Human asks delta" }
local OUT = { "Agent turn bravo", "Resolved charlie", "Closed ask echo", "Closed human foxtrot" }

local function wait_detail(id)
  fake.wait_for(function()
    return vim.api.nvim_buf_get_name(0) == "beads://" .. id
  end, "beads://" .. id .. " (current: " .. vim.api.nvim_buf_get_name(0) .. ")")
  return vim.api.nvim_get_current_buf()
end

local function wait_cursor_on(buf, text)
  local want
  fake.wait_for(function()
    want = fake.question_line(buf, text)
    return want ~= nil
      and vim.api.nvim_get_current_buf() == buf
      and vim.api.nvim_win_get_cursor(0)[1] == want
  end, ("cursor on the Questions line of '%s' (line %s, cursor %d)"):format(
    text,
    tostring(want),
    vim.api.nvim_win_get_cursor(0)[1]
  ))
end

local function assert_thread_items(lines)
  local all = table.concat(lines, "\n")
  for _, s in ipairs(IN) do
    assert.is_not_nil(fake.find(lines, s), "missing thread '" .. s .. "' in:\n" .. all)
  end
  for _, s in ipairs(OUT) do
    assert.is_nil(fake.find(lines, s), "thread '" .. s .. "' must not be listed:\n" .. all)
  end
  assert.are.equal(#IN, #lines, "one item per waiting thread:\n" .. all)
  assert.truthy(lines[fake.find(lines, "Second ask alpha")]:find("qa-1", 1, true), "no bead id")
  assert.truthy(lines[fake.find(lines, "Human asks delta")]:find("hu-4", 1, true), "no bead id")
end

describe(":Beads questions (vim.ui.select)", function()
  before_each(function()
    fake.setup()
    fake.write_threads()
  end)

  after_each(function()
    fake.teardown()
  end)

  it("lists only threads waiting on the user on non-closed beads, human threads included", function()
    local get = fake.capture_select()
    vim.cmd("Beads questions")
    assert_thread_items(get(":Beads questions picker").lines)
  end)

  it("choosing a stored thread opens its bead with the cursor on that thread's line", function()
    local get = fake.capture_select()
    vim.cmd("Beads questions")
    local c = get(":Beads questions picker")
    local i = fake.find(c.lines, "Second ask alpha")
    assert.is_not_nil(i, "no item for 'Second ask alpha'")
    c.on_choice(c.items[i], i)
    local buf = wait_detail("qa-1")
    wait_cursor_on(buf, "Second ask alpha")
    assert.are_not.equal(
      fake.question_line(buf, "Stored ask alpha"),
      vim.api.nvim_win_get_cursor(0)[1],
      "cursor on the bead's other thread"
    )
  end)

  it("choosing a human thread opens its bead with the cursor on that thread's line", function()
    local get = fake.capture_select()
    vim.cmd("Beads questions")
    local c = get(":Beads questions picker")
    local i = fake.find(c.lines, "Human asks delta")
    assert.is_not_nil(i, "no item for 'Human asks delta'")
    c.on_choice(c.items[i], i)
    local buf = wait_detail("hu-4")
    wait_cursor_on(buf, "Human asks delta")
  end)

  it("<leader>bq opens the questions picker", function()
    assert.are.equal("<leader>bq", require("beads").config.keymaps.questions)
    local get = fake.capture_select()
    fake.press("<leader>bq")
    assert_thread_items(get("<leader>bq picker").lines)
  end)

  -- passes already: a closed bead's thread stays in its own Questions section.
  it("a closed bead's open thread still shows in its Questions section", function()
    vim.cmd("edit beads://cl-5")
    local buf = vim.api.nvim_get_current_buf()
    fake.wait_for(function()
      return fake.question_line(buf, "Closed ask echo") ~= nil
    end, "Questions line of cl-5's thread")
  end)
end)

describe(":Beads questions (fzf-lua)", function()
  local calls

  local FAKE_FZF = {
    fzf_exec = function(contents, opts)
      calls[#calls + 1] = { contents = contents, opts = opts or {} }
    end,
    utils = {
      ansi_codes = setmetatable({}, {
        __index = function()
          return function(s)
            return s
          end
        end,
      }),
    },
  }

  local function exec_lines(call)
    local c = call.contents
    if type(c) == "table" then
      return vim.list_extend({}, c)
    end
    assert.are.equal("function", type(c), "fzf_exec contents is neither a table nor a function")
    local out, done = {}, false
    c(function(line, cb)
      if line == nil then
        done = true
      else
        out[#out + 1] = line
      end
      if cb then
        cb()
      end
    end)
    fake.wait_for(function()
      return done
    end, "fzf contents function to finish")
    return out
  end

  local function strip(s)
    return (tostring(s):gsub("\27%[[%d;]*m", ""))
  end

  local function run()
    vim.cmd("Beads questions")
    fake.wait_for(function()
      return #calls > 0
    end, ":Beads questions calling fzf_exec")
    local call = calls[#calls]
    local lines = exec_lines(call)
    local plain = {}
    for i, l in ipairs(lines) do
      plain[i] = strip(l)
    end
    return call, lines, plain
  end

  local function action(call, key)
    local a = (call.opts.actions or {})[key]
    assert.is_not_nil(a, "no fzf action for " .. key)
    if type(a) == "table" then
      a = a.fn or a[1]
    end
    assert.are.equal("function", type(a), "action " .. key .. " is not callable")
    return a
  end

  before_each(function()
    calls = {}
    fake.setup({ fzf = FAKE_FZF })
    fake.write_threads()
    vim.ui.select = function()
      error("vim.ui.select must not be used when fzf-lua is present")
    end
  end)

  after_each(function()
    fake.teardown()
  end)

  it("lists the waiting threads with fzf_exec", function()
    local _, _, plain = run()
    assert_thread_items(plain)
  end)

  it("preview shows the thread's conversation", function()
    local call, lines, plain = run()
    assert.are.equal("function", type(call.opts.preview), "opts.preview is not a function")
    local i = fake.find(plain, "Second ask alpha")
    assert.is_not_nil(i, "no line for 'Second ask alpha'")
    local out = call.opts.preview({ lines[i] })
    if type(out) == "table" then
      out = table.concat(out, "\n")
    end
    out = strip(out)
    for _, s in ipairs({ "Second ask alpha", "User reply alpha", "Follow-up alpha" }) do
      assert.truthy(out:find(s, 1, true), "preview lacks '" .. s .. "':\n" .. out)
    end
    assert.is_nil(out:find("Stored ask alpha", 1, true), "preview shows another thread")
  end)

  it("default action opens the bead with the cursor on the thread's line", function()
    local call, lines, plain = run()
    local i = fake.find(plain, "Second ask alpha")
    assert.is_not_nil(i, "no line for 'Second ask alpha'")
    action(call, "default")({ lines[i] }, {})
    local buf = wait_detail("qa-1")
    wait_cursor_on(buf, "Second ask alpha")
  end)
end)
