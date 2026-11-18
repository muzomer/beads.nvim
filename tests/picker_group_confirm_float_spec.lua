-- Bead beads_nvim-05t: in the fzf bead pickers, confirming a group action on more than 5 selected
-- beads opens a float listing every target id with its title next to the "[y/N]" prompt; the
-- float closes on answer or cancel. 5 or fewer: prompt only.
-- Interface under test: :Beads list with fzf-lua replaced by a fake recording fzf_exec (as in
-- picker_fzf_group_spec.lua); the ctrl-x (close) and ctrl-a (action menu -> priority) actions.
-- bd is the fake from tests/picker_fake.lua (three extra open beads are added to its list),
-- wrapped by a script that logs `bd batch -f <file>` lines to $FAKE_DIR/args.log as "BATCH: ...".
--
-- assumption: the list is a floating window (nvim_win_get_config().relative ~= "") already open
--   when vim.ui.input is called with the "[y/N]" prompt; its buffer shows each id with its title.
-- assumption: the confirmation prompt text still contains "[y/N]".

local fake = require("tests.picker_fake")

local EXTRA = {
  fake.bead("op-k", "Open kilo"),
  fake.bead("op-l", "Open lima"),
  fake.bead("op-m", "Open mike"),
}
local SIX = { "op-a", "ip-b", "ep-f", "ot-g", "op-k", "op-l" }
local FIVE = { "op-a", "ip-b", "ep-f", "ot-g", "op-k" }

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
local answer, confirms, menu_choice

local function title(id)
  return assert(fake.by_id(id), "no fixture bead " .. id).title
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

local function log_dump()
  return table.concat(fake.args_log(), "\n")
end

local function has_id(text, id)
  return text:find("%f[%w%-]" .. vim.pesc(id) .. "%f[^%w%-]") ~= nil
end

local function floats()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      local buf = vim.api.nvim_win_get_buf(w)
      out[#out + 1] = { win = w, text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") }
    end
  end
  return out
end

local function lists_all(text, ids)
  for _, id in ipairs(ids) do
    if not has_id(text, id) or not text:find(title(id), 1, true) then
      return false
    end
  end
  return true
end

local function float_naming(list, ids)
  for _, f in ipairs(list) do
    for _, id in ipairs(ids) do
      if has_id(f.text, id) then
        return f
      end
    end
  end
end

local function floats_dump(list)
  local t = {}
  for _, f in ipairs(list) do
    t[#t + 1] = "[float " .. f.win .. "]\n" .. f.text
  end
  return #t > 0 and table.concat(t, "\n") or "(no floats)"
end

local function install_stubs()
  vim.ui.input = function(opts, cb)
    local p = tostring((opts or {}).prompt or "")
    if p:find("[y/N]", 1, true) then
      local fl = floats()
      local c = { prompt = p, floats = fl }
      for _, f in ipairs(fl) do
        if lists_all(f.text, FIVE) then
          c.float, c.text = f.win, f.text
          break
        end
      end
      confirms[#confirms + 1] = c
      return cb(answer)
    end
    cb("")
  end
  local menu_seen = false
  vim.ui.select = function(list, opts, cb)
    local fmt = (opts or {}).format_item or tostring
    if not menu_seen then
      menu_seen = true
      for i, it in ipairs(list) do
        if menu_choice and tostring(fmt(it)):lower():find(menu_choice, 1, true) then
          return cb(it, i)
        end
      end
      return cb(nil)
    end
    for i, it in ipairs(list) do
      if tostring(fmt(it)):lower():find("p1", 1, true) then
        return cb(it, i)
      end
    end
    cb(nil)
  end
end

local function run_list()
  calls = {}
  package.preload["fzf-lua"] = nil
  package.loaded["fzf-lua"] = FAKE_FZF
  require("beads").setup({})
  vim.cmd("Beads list")
  assert(vim.wait(2000, function()
    return #calls > 0
  end, 10), "Beads list never called fzf-lua fzf_exec")
  local call = calls[#calls]
  assert.are.equal("table", type(call.contents), "contents is not a list")
  return call, call.contents
end

local function lines_for(lines, ids)
  local out = {}
  for _, id in ipairs(ids) do
    local found
    for _, l in ipairs(lines) do
      if fake.line_id(l) == id then
        found = l
      end
    end
    assert(found, "no picker line for " .. id .. ":\n" .. table.concat(lines, "\n"))
    out[#out + 1] = found
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

local function only_confirm()
  assert.are.equal(1, #confirms, "expected one [y/N] confirmation, got " .. #confirms)
  return confirms[1]
end

local function assert_listed(c, ids)
  assert(
    c.float and lists_all(c.text, ids),
    "no float listing every target id with its title when '" .. c.prompt .. "' was asked; floats:\n"
      .. floats_dump(c.floats)
  )
end

local function assert_float_closed(c)
  assert(vim.wait(3000, function()
    return not vim.api.nvim_win_is_valid(c.float)
  end, 10), "the id float did not close after the answer (" .. tostring(answer) .. ")")
end

describe("fzf pickers: group confirm lists the ids in a float for more than 5 beads", function()
  before_each(function()
    for _, b in ipairs(EXTRA) do
      table.insert(fake.LIST, b)
    end
    fake.setup()
    install_wrapper()
    answer, confirms, menu_choice = "y", {}, nil
    install_stubs()
  end)

  after_each(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    fake.teardown()
    for _ = 1, #EXTRA do
      table.remove(fake.LIST)
    end
    if wrap_dir then
      vim.fn.delete(wrap_dir, "rf")
    end
  end)

  it("ctrl-x with 6 selected lists the 6 ids with titles in a float, which closes on y", function()
    local call, lines = run_list()
    action(call, "ctrl-x")(lines_for(lines, SIX), call.opts)
    local c = only_confirm()
    assert_listed(c, SIX)
    assert_float_closed(c)
    assert(vim.wait(3000, function()
      return #batch_lines() >= 6
    end, 10), "no bd batch with the 6 closes; log:\n" .. log_dump())
  end)

  it("ctrl-x with 6 selected cancelled (Esc): the float closes and nothing is closed", function()
    answer = nil
    local call, lines = run_list()
    action(call, "ctrl-x")(lines_for(lines, SIX), call.opts)
    local c = only_confirm()
    assert_listed(c, SIX)
    assert_float_closed(c)
    vim.wait(300, function()
      return false
    end, 10)
    assert.are.same({}, batch_lines(), "beads closed after cancel; log:\n" .. log_dump())
  end)

  it("ctrl-a -> priority with 6 selected lists the 6 ids with titles in a float, which closes on y", function()
    menu_choice = "priority"
    local call, lines = run_list()
    action(call, "ctrl-a")(lines_for(lines, SIX), call.opts)
    local c = only_confirm()
    assert_listed(c, SIX)
    assert_float_closed(c)
    assert(vim.wait(3000, function()
      return #batch_lines() >= 6
    end, 10), "no bd batch with the 6 priority updates; log:\n" .. log_dump())
  end)

  -- passes already: 5 or fewer beads keep the prompt-only confirmation.
  it("ctrl-x with 5 selected asks the [y/N] prompt without a float listing the ids", function()
    local call, lines = run_list()
    action(call, "ctrl-x")(lines_for(lines, FIVE), call.opts)
    local c = only_confirm()
    assert.is_nil(float_naming(c.floats, FIVE), "a float named the ids for 5 beads:\n" .. floats_dump(c.floats))
    assert.is_truthy(c.prompt:find("5", 1, true), "prompt does not name 5 beads: " .. c.prompt)
  end)
end)
