-- Bead beads_nvim-4u9.15: peek floats follow live updates and hold the watcher.
-- Interface under test:
--   * A peek float re-renders when its bead changes in the store (an external change, picked up
--     by the watcher's store refresh; simulated here by store.refresh after the fake bd output
--     changed).
--   * The watcher (beads.watch.acquire) is held while any peek float is open and released after
--     the last one closes: the number of outstanding holds returns to its start value.
-- The refcount is observed by wrapping beads.watch.acquire (as picker_release_no_terminal_findings).
-- Fixture and fake bd: tests/peek_fake.lua.
-- assumption: an external change reaches the float through a store refresh (what the watcher does).

local fake = require("tests.peek_fake")
local store = require("beads.store")

local holds, orig_acquire

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
  holds = {}
  if orig_acquire then
    require("beads.watch").acquire = orig_acquire
    orig_acquire = nil
  end
end

local function outstanding()
  local n = 0
  for _, h in ipairs(holds) do
    if not h.released then
      n = n + 1
    end
  end
  return n
end

local function settle()
  vim.wait(200, function()
    return false
  end, 10)
end

local function origin()
  local win = vim.api.nvim_get_current_win()
  fake.edit_in(win, "pk-b2y")
  return win
end

local function peek_blocker(win)
  fake.cursor_on(win, "pk-c3z", 2)
  return fake.peek(win, "gd", "pk-c3z")
end

describe("gd peek floats and the watcher", function()
  before_each(function()
    fake.setup({})
    spy_acquire()
  end)

  after_each(function()
    fake.close_floats()
    restore_acquire()
    fake.teardown()
  end)

  it("a peek float updates when its bead changes externally", function()
    local win = origin()
    local f = peek_blocker(win)
    local items = fake.items()
    for _, b in ipairs(items) do
      if b.id == "pk-c3z" then
        b.description = "Body of pk-c3z\nRewritten from a shell."
        b.updated_at = "2026-11-18T12:00:00Z"
      end
    end
    fake.set_list(items)
    store.refresh(fake.root())
    assert(vim.wait(3000, function()
      return vim.api.nvim_win_is_valid(f) and fake.text_of(f):find("Rewritten from a shell.", 1, true) ~= nil
    end, 10), "peek float did not follow the external change:\n" .. fake.text_of(f))
    assert.is_true(vim.api.nvim_win_is_valid(f))
    assert.is_false(vim.bo[vim.api.nvim_win_get_buf(f)].modifiable, "float became modifiable after the update")
  end)

  it("holds the watcher while peek floats are open; q on the last returns the refcount to its start", function()
    local win = origin()
    settle()
    local base = outstanding()
    local f1 = peek_blocker(win)
    settle()
    assert.is_true(outstanding() > base, ("no watcher hold while a peek float is open (%d <= %d)"):format(outstanding(), base))
    fake.cursor_on(f1, "pk-d4w")
    local f2 = fake.peek(f1, "gd", "pk-d4w")
    fake.press(f2, "q")
    settle()
    assert.is_true(vim.api.nvim_win_is_valid(f1), "setup: q closed both floats")
    assert.is_true(outstanding() > base, "watcher released while a peek float is still open")
    fake.press(f1, "q")
    settle()
    assert.are.equal(0, #fake.peeks())
    assert.are.equal(base, outstanding(), "watcher holds did not return to the start value after the last float closed")
  end)

  it("Q releases every hold the peek floats took", function()
    local win = origin()
    settle()
    local base = outstanding()
    local f1 = peek_blocker(win)
    fake.cursor_on(f1, "pk-d4w")
    local f2 = fake.peek(f1, "gd", "pk-d4w")
    settle()
    assert.is_true(outstanding() > base, "no watcher hold while peek floats are open")
    fake.press(f2, "Q")
    settle()
    assert.are.equal(0, #fake.peeks())
    assert.are.equal(base, outstanding(), "Q did not return the watcher holds to the start value")
  end)
end)
