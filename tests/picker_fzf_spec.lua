-- Interface under test (bead beads_nvim-ge7.13): pickers via :Beads <source> with fzf-lua PRESENT,
-- so the fzf-lua adapter (lua/beads/pickers/fzf.lua) is used.
-- fzf-lua is replaced by a fake module (test double for the external plugin) whose
-- fzf_exec(contents, opts) records its arguments, mirroring the real API:
--   contents: list of lines, or function(cb) that calls cb(line) per line and cb(nil) at the end;
--   opts.preview: function(selected) -> string or list of lines (fzf-lua accepts lua function previews);
--   opts.actions[key]: function(selected, opts) or { fn = function(selected, opts) }.
-- Expected action keys: "default" open detail, "ctrl-y" yank id, "ctrl-x" close bead,
-- "alt-r" yank run command (yr is not bindable in fzf).
-- bd is a fake on PATH (tests/picker_fake.lua).

local fake = require("tests.picker_fake")
local model = require("beads.model")
local render = require("beads.buffer.render")

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
  assert(vim.wait(2000, function()
    return done
  end, 10), "contents function never finished")
  return out
end

local function run(cmd)
  vim.cmd(cmd)
  assert(vim.wait(2000, function()
    return #calls > 0
  end, 10), cmd .. " never called fzf-lua fzf_exec")
  local call = calls[#calls]
  return call, exec_lines(call)
end

local function line_for(lines, id)
  for _, l in ipairs(lines) do
    if fake.line_id(l) == id then
      return l
    end
  end
  error("no picker line for " .. id .. ":\n" .. table.concat(lines, "\n"))
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

local function has_line(lines, s)
  for _, l in ipairs(lines) do
    if l == s then
      return true
    end
  end
  return false
end

describe("pickers with fzf-lua", function()
  before_each(function()
    fake.setup()
    calls = {}
    package.preload["fzf-lua"] = nil
    package.loaded["fzf-lua"] = FAKE_FZF
    require("beads").setup({})
    assert.is_true(require("beads").config.fzf)
    vim.ui.select = function()
      error("vim.ui.select must not be used when fzf-lua is present")
    end
    vim.ui.input = function(_, cb)
      cb("")
    end
  end)

  after_each(function()
    fake.teardown()
  end)

  it("uses fzf_exec with the source's beads", function()
    local _, lines = run("Beads epics")
    assert.are.same(fake.sorted(fake.EXPECTED.epics), fake.ids_of(lines))
  end)

  it("preview shows the rendered detail of the bead", function()
    local call, lines = run("Beads list")
    assert.are.equal("function", type(call.opts.preview), "opts.preview is not a function")
    local out = call.opts.preview({ line_for(lines, "op-a") })
    if type(out) == "table" then
      out = table.concat(out, "\n")
    end
    assert.are.equal("string", type(out), "preview returned nothing")
    local got = vim.split(fake.strip(out), "\n", { plain = true })
    local expected = render.render(model.normalize(fake.by_id("op-a")))
    for _, want in ipairs({ "id: op-a", "# Open alpha", "## Workflow", "Alpha description text" }) do
      assert.is_true(has_line(expected, want), "fixture/render mismatch for " .. want)
      assert.is_true(has_line(got, want), "preview lacks line '" .. want .. "':\n" .. out)
    end
  end)

  it("default action (<CR>) opens the detail buffer", function()
    local call, lines = run("Beads list")
    action(call, "default")({ line_for(lines, "ot-g") }, call.opts)
    assert(fake.wait_buf("beads://ot-g"), "current buffer is " .. vim.api.nvim_buf_get_name(0))
  end)

  it("ctrl-y yanks the bead id", function()
    vim.fn.setreg('"', "before")
    local call, lines = run("Beads list")
    action(call, "ctrl-y")({ line_for(lines, "ip-b") }, call.opts)
    assert(vim.wait(1000, function()
      return vim.fn.getreg('"') == "ip-b"
    end, 10), "unnamed register is " .. vim.fn.getreg('"'))
  end)

  it("alt-r yanks the workflow run command (run-bead for tasks)", function()
    vim.fn.setreg('"', "before")
    local call, lines = run("Beads list")
    action(call, "alt-r")({ line_for(lines, "op-a") }, call.opts)
    assert(vim.wait(1000, function()
      return vim.fn.getreg('"') == "/beads-workflow:run-bead op-a"
    end, 10), "unnamed register is " .. vim.fn.getreg('"'))
  end)

  it("alt-r yanks run-epic for an epic", function()
    vim.fn.setreg('"', "before")
    local call, lines = run("Beads epics")
    action(call, "alt-r")({ line_for(lines, "ep-f") }, call.opts)
    assert(vim.wait(1000, function()
      return vim.fn.getreg('"') == "/beads-workflow:run-epic ep-f"
    end, 10), "unnamed register is " .. vim.fn.getreg('"'))
  end)

  it("ctrl-x closes the bead with bd close", function()
    local call, lines = run("Beads list")
    action(call, "ctrl-x")({ line_for(lines, "ot-g") }, call.opts)
    assert(vim.wait(2000, function()
      for _, a in ipairs(fake.args_log()) do
        if a:match("close%s+ot%-g") then
          return true
        end
      end
      return false
    end, 10), "bd close ot-g was not run; log:\n" .. table.concat(fake.args_log(), "\n"))
  end)
end)
