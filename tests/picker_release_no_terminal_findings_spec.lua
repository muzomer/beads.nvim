-- Reviewer finding for bead beads_nvim-4u9.9 (lua/beads/views/picker.lua release_with_terminal):
-- when fzf-lua runs without a terminal buffer in the current window (fzf-tmux / tmux popup
-- profile), the watcher hold taken by picker.open / questions.open must still be released once
-- the picker finishes; otherwise the watcher refcount leaks on every picker open.
--
-- fzf-lua is a fake module (test double for the external plugin) whose fzf_exec records its
-- arguments and opens no window and no terminal buffer. "The picker finishes" is simulated by
-- running the chosen action (if any) and then calling opts.winopts.on_close / opts.on_close when
-- the adapter provides them (fzf-lua's close hook).
-- The watcher refcount is observed by wrapping beads.watch.acquire: every hold handed out while
-- the picker opens must have been released after it finishes.

local pfake = require("tests.picker_fake")
local qfake = require("tests.questions_waiting_fake")
local cli = require("beads.cli")
require("beads.views.questions") -- load before questions_waiting_fake changes the cwd

local calls, holds, orig_acquire

local FAKE_FZF = {
  fzf_exec = function(contents, opts)
    calls[#calls + 1] = { contents = contents, opts = opts or {}, holds = vim.list_extend({}, holds) }
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

local function spy_acquire()
  holds = {}
  local watch = require("beads.watch")
  orig_acquire = watch.acquire
  watch.acquire = function(root)
    local release = orig_acquire(root)
    local h = { root = root, released = false }
    h.release = function()
      h.released = true
      return release()
    end
    holds[#holds + 1] = h
    return h.release
  end
end

local function restore_acquire()
  for _, h in ipairs(holds or {}) do
    if not h.released then
      pcall(h.release)
    end
  end
  require("beads.watch").acquire = orig_acquire
end

local function outstanding(list, root)
  local n = 0
  for _, h in ipairs(list) do
    if h.root == root and not h.released then
      n = n + 1
    end
  end
  return n
end

local function open(cmd)
  vim.cmd(cmd)
  assert(vim.wait(2000, function()
    return #calls > 0
  end, 10), cmd .. " never called fzf-lua fzf_exec")
  local call = calls[#calls]
  assert.are_not.equal("terminal", vim.bo[vim.api.nvim_get_current_buf()].buftype)
  return call
end

local function lines_of(call)
  local c = call.contents
  if type(c) == "table" then
    return vim.list_extend({}, c)
  end
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
  assert(vim.wait(2000, function()
    return done
  end, 10), "contents function never finished")
  return out
end

-- Simulates fzf-lua finishing: the chosen action runs (nil = <Esc>), then the close hooks.
local function finish(call, key, selected)
  if key then
    local a = (call.opts.actions or {})[key]
    assert.is_not_nil(a, "no fzf action for " .. key)
    if type(a) == "table" then
      a = a.fn or a[1]
    end
    a(selected, call.opts)
  end
  local wo = call.opts.winopts
  if type(wo) == "table" and type(wo.on_close) == "function" then
    wo.on_close()
  end
  if type(call.opts.on_close) == "function" then
    call.opts.on_close()
  end
end

local function assert_released(call, root)
  assert.is_true(outstanding(call.holds, root) > 0, "picker took no watcher hold on " .. root)
  local ok = vim.wait(500, function()
    return outstanding(call.holds, root) == 0
  end, 10)
  assert.is_true(
    ok,
    ("watcher hold on %s not released after the picker finished (%d outstanding)"):format(
      root,
      outstanding(call.holds, root)
    )
  )
end

describe("picker watcher hold without a terminal buffer (fzf-tmux)", function()
  before_each(function()
    pfake.setup()
    calls = {}
    package.preload["fzf-lua"] = nil
    package.loaded["fzf-lua"] = FAKE_FZF
    require("beads").setup({})
    assert.is_true(require("beads").config.fzf)
    spy_acquire()
  end)

  after_each(function()
    restore_acquire()
    pfake.teardown()
  end)

  it(":Beads list releases the hold when closed with <Esc>", function()
    local root = cli.get_root()
    local call = open("Beads list")
    finish(call, nil)
    assert_released(call, root)
  end)

  it(":Beads list releases the hold after an action (ctrl-y)", function()
    local root = cli.get_root()
    local call = open("Beads list")
    local lines = lines_of(call)
    finish(call, "ctrl-y", { lines[1] })
    assert_released(call, root)
  end)
end)

describe("questions picker watcher hold without a terminal buffer (fzf-tmux)", function()
  before_each(function()
    calls = {}
    qfake.setup({ fzf = FAKE_FZF })
    qfake.write_threads()
    spy_acquire()
  end)

  after_each(function()
    restore_acquire()
    qfake.teardown()
  end)

  it(":Beads questions releases the hold when closed with <Esc>", function()
    local root = cli.get_root()
    local call = open("Beads questions")
    finish(call, nil)
    assert_released(call, root)
  end)
end)
