-- Bead beads_nvim-2qo.3: fzf-lua multi-select group actions in the bead pickers.
-- Interface under test (fzf-lua replaced by a fake module recording fzf_exec(contents, opts), as in
-- picker_fzf_spec.lua):
--   * the bead pickers (ready, list, search, needs, epics) enable fzf multi-select
--     (opts.fzf_opts["--multi"] or ["-m"]), so fzf-lua hands every selected line to an action;
--   * ctrl-x (keymaps.picker.close) closes all selected beads: for > 1 a "[y/N]" vim.ui.input
--     confirmation, then one `bd batch` with `close <id>` lines (the shared group executor,
--     lua/beads/group.lua); one bead is closed without confirmation, as before;
--   * keymaps.picker.actions (default "ctrl-a") opens the same action menu as the tree's A
--     (vim.ui.select) for the selected beads; set priority runs one `bd batch` of
--     `update <id> priority=<n>` lines; can be remapped or set to false; the header lists it;
--   * the vim.ui.select adapter stays single-choice.
-- bd is the fake from tests/picker_fake.lua, wrapped by a script that logs the lines of
-- `bd batch -f <file>` to $FAKE_DIR/args.log as "BATCH: <line>" (cli.batch deletes the file).
-- The menu / value / confirm prompts are driven by tests/group_actions_harness.lua.
--
-- assumption: multi-select is enabled via fzf_opts["--multi"] (or "-m").
-- assumption: only the bead pickers are covered; the questions picker is not tested here.
-- assumption: batch lines follow 2qo.2's grammar: `close <id>` and `update <id> priority=1`.

local fake = require("tests.picker_fake")
local H = require("tests.group_actions_harness")

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

local wrap_dir
local h_installed = false

local function h_install()
  H.install()
  h_installed = true
end

local function install_wrapper()
  local orig = vim.fn.exepath("bd")
  assert(orig ~= "", "fake bd not on PATH")
  wrap_dir = vim.fn.tempname()
  vim.fn.mkdir(wrap_dir, "p")
  local script = ([[#!/bin/sh
for a in "$@"; do
  if [ "$a" = "batch" ]; then
    echo "$*" >> "$FAKE_DIR/args.log"
    prev=""
    for b in "$@"; do
      if [ "$prev" = "-f" ] || [ "$prev" = "--file" ]; then sed 's/^/BATCH: /' "$b" >> "$FAKE_DIR/args.log"; fi
      prev="$b"
    done
    echo ok
    exit 0
  fi
done
exec "%s" "$@"
]]):format(orig)
  vim.fn.writefile(vim.split(script, "\n"), wrap_dir .. "/bd")
  vim.fn.setfperm(wrap_dir .. "/bd", "rwxr-xr-x")
  vim.env.PATH = wrap_dir .. ":" .. vim.env.PATH
end

local function setup_fzf(opts)
  calls = {}
  package.preload["fzf-lua"] = nil
  package.loaded["fzf-lua"] = FAKE_FZF
  require("beads").setup(opts or {})
  assert.is_true(require("beads").config.fzf)
end

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

local function header(call)
  local h = call.opts.header or (call.opts.fzf_opts or {})["--header"]
  if type(h) == "table" then
    h = table.concat(h, "\n")
  end
  return fake.strip(h or "")
end

local function log_dump()
  return table.concat(fake.args_log(), "\n")
end

local function batch_lines()
  local out = {}
  for _, l in ipairs(fake.args_log()) do
    local b = l:match("^BATCH: (.*)$")
    if b then
      out[#out + 1] = vim.trim(b)
    end
  end
  table.sort(out)
  return out
end

local function batch_calls()
  local n = 0
  for _, l in ipairs(fake.args_log()) do
    if not l:match("^BATCH: ") and l:match("%f[%w]batch%f[^%w]") then
      n = n + 1
    end
  end
  return n
end

-- non-batch bd invocations matching pattern
local function direct(pattern)
  local out = {}
  for _, l in ipairs(fake.args_log()) do
    if not l:match("^BATCH: ") and l:match(pattern) then
      out[#out + 1] = l
    end
  end
  return out
end

local THREE = { "ip-b", "op-a", "ot-g" }

describe("fzf pickers: multi-select group actions", function()
  local confirms, inputs

  before_each(function()
    fake.setup()
    install_wrapper()
    confirms, inputs = {}, {}
  end)

  after_each(function()
    if h_installed then
      H.restore()
      h_installed = false
    end
    fake.teardown()
    if wrap_dir then
      vim.fn.delete(wrap_dir, "rf")
    end
  end)

  -- vim.ui.input: "[y/N]" prompts answered with `answer`, any other prompt (close reason) with "".
  local function stub_input(answer)
    vim.ui.input = function(opts, cb)
      local p = tostring((opts or {}).prompt or "")
      if p:find("[y/N]", 1, true) then
        confirms[#confirms + 1] = p
        return cb(answer)
      end
      inputs[#inputs + 1] = p
      cb("")
    end
    vim.ui.select = function()
      error("ctrl-x must not open a vim.ui.select")
    end
  end

  it("every bead picker enables fzf multi-select and binds the actions key", function()
    setup_fzf({})
    vim.ui.input = function(_, cb)
      cb("juliet")
    end
    for _, cmd in ipairs({ "Beads ready", "Beads list", "Beads search juliet", "Beads needs", "Beads epics" }) do
      local call = run(cmd)
      local fo = call.opts.fzf_opts or {}
      assert.is_truthy(fo["--multi"] or fo["-m"], cmd .. ": fzf multi-select not enabled (fzf_opts --multi)")
      assert.is_not_nil((call.opts.actions or {})["ctrl-a"], cmd .. ": no fzf action ctrl-a")
    end
  end)

  it("ctrl-x with 3 selected confirms once and closes them in one bd batch", function()
    setup_fzf({})
    stub_input("y")
    local call, lines = run("Beads list")
    action(call, "ctrl-x")(lines_for(lines, THREE), call.opts)
    assert(vim.wait(3000, function()
      return #batch_lines() >= 3
    end, 10), "no bd batch with the 3 closes; log:\n" .. log_dump())
    H.sleep(200)
    assert.are.equal(1, #confirms, "expected one [y/N] confirmation, got " .. #confirms)
    assert.is_truthy(confirms[1]:find("3", 1, true), "confirmation does not name 3 beads: " .. confirms[1])
    assert.are.equal(1, batch_calls(), "expected one bd batch; log:\n" .. log_dump())
    assert.are.same({ "close ip-b", "close op-a", "close ot-g" }, batch_lines())
    assert.are.same({}, direct("%f[%w]close%f[^%w]"), "per-bead bd close ran; log:\n" .. log_dump())
  end)

  it("ctrl-x with 3 selected and the confirmation declined closes nothing", function()
    setup_fzf({})
    stub_input("n")
    local call, lines = run("Beads list")
    action(call, "ctrl-x")(lines_for(lines, THREE), call.opts)
    H.sleep(500)
    assert.are.equal(1, #confirms, "expected one [y/N] confirmation, got " .. #confirms)
    assert.are.equal(0, batch_calls(), "bd batch ran; log:\n" .. log_dump())
    assert.are.same({}, direct("%f[%w]close%f[^%w]"), "bd close ran; log:\n" .. log_dump())
  end)

  it("ctrl-x with a single selection closes it without confirmation", function()
    setup_fzf({})
    stub_input("y")
    local call, lines = run("Beads list")
    action(call, "ctrl-x")({ line_for(lines, "ot-g") }, call.opts)
    assert(vim.wait(3000, function()
      return #direct("close%s+ot%-g") > 0 or vim.tbl_contains(batch_lines(), "close ot-g")
    end, 10), "ot-g was not closed; log:\n" .. log_dump())
    H.sleep(200)
    assert.are.equal(0, #confirms, "single bead was confirmed: " .. table.concat(confirms, " | "))
  end)

  it("ctrl-a opens the action menu; set priority applies to the 3 selected in one bd batch", function()
    setup_fzf({})
    h_install()
    local call, lines = run("Beads list")
    H.reset_state({ name = "priority", menu = H.menu.priority, value = { pick = function(t)
      return t:find("p1", 1, true) ~= nil
    end }, confirm = "y" })
    action(call, "ctrl-a")(lines_for(lines, THREE), call.opts)
    local st = H.state
    assert(st.menu, "ctrl-a opened no vim.ui.select menu")
    assert(st.menu_pick, "action menu has no priority entry; items:\n  " .. table.concat(st.menu, "\n  "))
    assert(vim.wait(3000, function()
      return #batch_lines() >= 3
    end, 10), "no bd batch with the 3 priority updates; log:\n" .. log_dump())
    H.sleep(200)
    assert.are.equal(1, #st.confirms, "expected one [y/N] confirmation, got " .. #st.confirms)
    assert.are.equal(1, batch_calls(), "expected one bd batch; log:\n" .. log_dump())
    assert.are.same({ "update ip-b priority=1", "update op-a priority=1", "update ot-g priority=1" }, batch_lines())
  end)

  it("ctrl-a with a single selection sets the priority without confirmation", function()
    setup_fzf({})
    h_install()
    local call, lines = run("Beads list")
    H.reset_state({ name = "priority", menu = H.menu.priority, value = { pick = function(t)
      return t:find("p1", 1, true) ~= nil
    end }, confirm = "y" })
    action(call, "ctrl-a")({ line_for(lines, "ot-g") }, call.opts)
    local st = H.state
    assert(st.menu_pick, "ctrl-a opened no action menu with a priority entry")
    assert(vim.wait(3000, function()
      return vim.tbl_contains(batch_lines(), "update ot-g priority=1") or #direct("update%s+ot%-g.*priority.*1") > 0
    end, 10), "priority of ot-g was not set; log:\n" .. log_dump())
    H.sleep(200)
    assert.are.equal(0, #st.confirms, "single bead was confirmed: " .. table.concat(st.confirms, " | "))
    for _, l in ipairs(batch_lines()) do
      assert.are.equal("update ot-g priority=1", l, "batch touched another bead; log:\n" .. log_dump())
    end
  end)

  it("header lists the default actions key ctrl-a", function()
    setup_fzf({})
    local call = run("Beads list")
    assert.is_truthy(header(call):find("ctrl-a", 1, true), "header lacks ctrl-a: " .. header(call))
  end)

  it("keymaps.picker.actions can be remapped", function()
    setup_fzf({ keymaps = { picker = { actions = "ctrl-b" } } })
    h_install()
    local call, lines = run("Beads list")
    assert.is_nil(call.opts.actions["ctrl-a"], "default ctrl-a still bound after remap")
    assert.is_truthy(header(call):find("ctrl-b", 1, true), "header lacks ctrl-b: " .. header(call))
    assert.is_falsy(header(call):find("ctrl-a", 1, true), "header still lists ctrl-a: " .. header(call))
    H.reset_state({ name = "priority", menu = {} })
    action(call, "ctrl-b")(lines_for(lines, THREE), call.opts)
    assert(H.state.menu, "ctrl-b opened no vim.ui.select action menu")
  end)

  it("keymaps.picker.actions = false removes the key and its header entry", function()
    setup_fzf({ keymaps = { picker = { actions = false } } })
    local call = run("Beads list")
    assert.is_nil(call.opts.actions["ctrl-a"], "ctrl-a still bound with actions = false")
    assert.is_falsy(header(call):find("ctrl-a", 1, true), "header still lists ctrl-a: " .. header(call))
    assert.is_not_nil(call.opts.actions["ctrl-x"], "ctrl-x lost")
    assert.is_not_nil(call.opts.actions["default"], "default lost")
  end)
end)

describe("vim.ui.select pickers stay single-choice", function()
  before_each(function()
    fake.setup()
    package.loaded["fzf-lua"] = nil
    package.preload["fzf-lua"] = function()
      error("fzf-lua is not installed (test)")
    end
    require("beads").setup({})
    assert.is_false(require("beads").config.fzf)
  end)

  after_each(function()
    fake.teardown()
  end)

  it("one vim.ui.select of beads; choosing one opens it, no menu or confirmation", function()
    local selects, inputs = {}, 0
    vim.ui.select = function(items, opts, cb)
      selects[#selects + 1] = { items = items, opts = opts or {}, cb = cb }
    end
    vim.ui.input = function(_, cb)
      inputs = inputs + 1
      cb(nil)
    end
    vim.cmd("Beads list")
    assert(vim.wait(2000, function()
      return #selects > 0
    end, 10), ":Beads list never called vim.ui.select")
    local s = selects[1]
    local chosen
    for _, it in ipairs(s.items) do
      if type(it) == "table" and it.id == "ot-g" then
        chosen = it
      end
    end
    assert.is_not_nil(chosen, "ot-g not among the select items")
    s.cb(chosen, 1)
    assert(fake.wait_buf("beads://ot-g"), "current buffer is " .. vim.api.nvim_buf_get_name(0))
    assert.are.equal(1, #selects, "a further vim.ui.select was opened")
    assert.are.equal(0, inputs, "a vim.ui.input was opened")
  end)
end)
