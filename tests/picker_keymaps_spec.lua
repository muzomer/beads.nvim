-- Bead beads_nvim-4gx.8: fzf picker actions come from keymaps.picker.
-- Interface under test: keymaps.picker = { yank_id = "ctrl-y", yank_run = "alt-r", close = "ctrl-x" }
--   (defaults); a changed value renames the fzf action key, false removes it. "default" (<CR>) stays.
-- fzf-lua is a fake module recording fzf_exec(contents, opts). bd is a fake (tests/picker_fake.lua).

local fake = require("tests.picker_fake")

local calls
local identity = function(s)
  return s
end
local FAKE_FZF = {
  fzf_exec = function(contents, opts)
    calls[#calls + 1] = { contents = contents, opts = opts or {} }
  end,
  utils = {
    ansi_codes = setmetatable({}, {
      __index = function()
        return identity
      end,
    }),
  },
}

local function run(opts)
  calls = {}
  package.preload["fzf-lua"] = nil
  package.loaded["fzf-lua"] = FAKE_FZF
  require("beads").setup(opts)
  assert.is_true(require("beads").config.fzf)
  vim.cmd("Beads list")
  assert(vim.wait(2000, function()
    return #calls > 0
  end, 10), "fzf_exec never called")
  local call = calls[#calls]
  local lines = call.contents
  assert.are.equal("table", type(lines), "contents is not a list")
  return call, lines
end

local function fn_of(a)
  if type(a) == "table" then
    a = a.fn or a[1]
  end
  return a
end

describe("fzf picker keymaps", function()
  before_each(function()
    fake.setup()
  end)

  after_each(function()
    fake.teardown()
  end)

  it("defaults: ctrl-y, alt-r, ctrl-x and default", function()
    local call = run({})
    for _, k in ipairs({ "default", "ctrl-y", "alt-r", "ctrl-x" }) do
      assert.is_not_nil(call.opts.actions[k], "no fzf action " .. k)
    end
  end)

  it("keymaps.picker changes and disables actions", function()
    local call, lines = run({ keymaps = { picker = { yank_id = "ctrl-k", close = false } } })
    local acts = call.opts.actions
    assert.is_not_nil(acts["ctrl-k"], "no fzf action ctrl-k for yank_id")
    assert.is_nil(acts["ctrl-y"], "default ctrl-y still bound")
    assert.is_nil(acts["ctrl-x"], "ctrl-x still bound with close = false")
    assert.is_not_nil(acts["alt-r"], "yank_run default lost")
    assert.is_not_nil(acts["default"], "default action lost")
    local line
    for _, l in ipairs(lines) do
      if fake.line_id(l) == "ip-b" then
        line = l
      end
    end
    vim.fn.setreg('"', "before")
    fn_of(acts["ctrl-k"])({ line }, call.opts)
    assert(vim.wait(1000, function()
      return vim.fn.getreg('"') == "ip-b"
    end, 10), "ctrl-k did not yank the id")
  end)
end)
