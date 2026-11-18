-- Bead beads_nvim-qvs.1: fzf pickers with several selections.
-- Interface under test: the fzf-lua actions of the bead pickers (fzf-lua replaced by a fake module
-- recording fzf_exec(contents, opts), as in picker_fzf_spec.lua): ctrl-y (yank_id), alt-r
-- (yank_run) and default (<CR>), called with the list of selected lines.
-- bd is the fake from tests/picker_fake.lua (ready.json beads are deliberately NOT in the store).
--
-- assumption: the yanked ids / run commands are in selection order, one per line, in the "
--   register (one trailing newline allowed).
-- assumption: the <CR> note names the number of ignored selections and contains "ignor"
--   (e.g. "Beads: 2 selections ignored").

local fake = require("tests.picker_fake")

local calls, notes, orig_notify
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

local function run(cmd)
  local n = #calls
  vim.cmd(cmd)
  assert(vim.wait(2000, function()
    return #calls > n
  end, 10), cmd .. " never called fzf-lua fzf_exec")
  local call = calls[#calls]
  assert.are.equal("table", type(call.contents), "contents is not a list")
  return call, call.contents
end

local function line_for(lines, id)
  for _, l in ipairs(lines) do
    if fake.line_id(l) == id then
      return l
    end
  end
  error("no picker line for " .. id .. ":\n" .. table.concat(lines, "\n"))
end

local function lines_for(lines, ids)
  local out = {}
  for _, id in ipairs(ids) do
    out[#out + 1] = line_for(lines, id)
  end
  return out
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

local function reg_lines()
  local s = vim.fn.getreg('"'):gsub("\n$", "")
  return vim.split(s, "\n", { plain = true })
end

local function wait_reg(want)
  vim.wait(1000, function()
    return vim.deep_equal(reg_lines(), want)
  end, 10)
  assert.are.same(want, reg_lines(), "register:\n" .. vim.fn.getreg('"'))
end

local function ignored_notes()
  local out = {}
  for _, n in ipairs(notes) do
    if n.msg:lower():find("ignor", 1, true) then
      out[#out + 1] = n.msg
    end
  end
  return out
end

local function notes_dump()
  return table.concat(
    vim.tbl_map(function(n)
      return n.msg
    end, notes),
    "\n---\n"
  )
end

describe("fzf pickers: several selections", function()
  before_each(function()
    fake.setup()
    calls, notes = {}, {}
    orig_notify = vim.notify
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    package.preload["fzf-lua"] = nil
    package.loaded["fzf-lua"] = FAKE_FZF
    require("beads").setup({})
    assert.is_true(require("beads").config.fzf)
    vim.ui.input = function(_, cb)
      cb("")
    end
  end)

  after_each(function()
    vim.notify = orig_notify
    fake.teardown()
  end)

  it("ctrl-y with 3 selected yanks all 3 ids, one per line", function()
    vim.fn.setreg('"', "before")
    local call, lines = run("Beads list")
    action(call, "ctrl-y")(lines_for(lines, { "ot-g", "ip-b", "op-a" }), call.opts)
    wait_reg({ "ot-g", "ip-b", "op-a" })
  end)

  it("alt-r with 2 selected (an epic and a task) yanks both run commands, one per line", function()
    vim.fn.setreg('"', "before")
    local call, lines = run("Beads list")
    action(call, "alt-r")(lines_for(lines, { "ep-f", "op-a" }), call.opts)
    wait_reg({ "/beads-workflow:run-epic ep-f", "/beads-workflow:run-bead op-a" })
  end)

  it("alt-r in the ready picker yanks the run commands of beads outside the store", function()
    vim.fn.setreg('"', "before")
    local call, lines = run("Beads ready")
    action(call, "alt-r")(lines_for(lines, { "rd-h", "rd-i" }), call.opts)
    wait_reg({ "/beads-workflow:run-bead rd-h", "/beads-workflow:run-bead rd-i" })
  end)

  it("ctrl-y with one selection still yanks just that id", function()
    vim.fn.setreg('"', "before")
    local call, lines = run("Beads list")
    action(call, "ctrl-y")({ line_for(lines, "ip-b") }, call.opts)
    wait_reg({ "ip-b" })
  end)

  it("<CR> with 3 selected opens the first and notifies once that 2 were ignored", function()
    local call, lines = run("Beads list")
    action(call, "default")(lines_for(lines, { "ip-b", "op-a", "ot-g" }), call.opts)
    assert(fake.wait_buf("beads://ip-b"), "current buffer is " .. vim.api.nvim_buf_get_name(0))
    vim.wait(200, function()
      return false
    end, 10)
    local got = ignored_notes()
    assert.are.equal(1, #got, "expected one 'ignored' note; notes:\n" .. notes_dump())
    assert.is_truthy(got[1]:find("%f[%d]2%f[%D]"), "note does not name 2 ignored selections: " .. got[1])
  end)

  it("<CR> with one selection opens it without an 'ignored' note", function()
    local call, lines = run("Beads list")
    action(call, "default")({ line_for(lines, "ot-g") }, call.opts)
    assert(fake.wait_buf("beads://ot-g"), "current buffer is " .. vim.api.nvim_buf_get_name(0))
    vim.wait(200, function()
      return false
    end, 10)
    assert.are.same({}, ignored_notes(), "notes:\n" .. notes_dump())
  end)
end)
