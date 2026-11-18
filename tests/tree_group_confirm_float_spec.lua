-- Bead beads_nvim-05t: confirming a group action on more than 5 beads opens a float that lists
-- every target id with its title next to the "[y/N]" prompt; the float closes on answer or cancel.
-- 5 or fewer beads: prompt only, no float.
-- Interface under test: :Beads tree with marks (m), x (close) and A (action menu -> priority).
--
-- `bd` is replaced by a shell script on PATH (test double for the external binary), as in
-- tree_selection_spec.lua: every call is logged to $FAKE_DIR/calls.log, batch file lines are
-- logged prefixed with "BATCH: ".
--
-- assumption: the list is a floating window (nvim_win_get_config().relative ~= "") that is already
--   open when vim.ui.input is called with the "[y/N]" prompt; its buffer shows each id with its
--   title (order and layout not asserted; position relative to the prompt not asserted).
-- assumption: the confirmation prompt text still contains "[y/N]".

local cli = require("beads.cli")

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local FAKE_BD = [[#!/bin/sh
d="$FAKE_DIR"
printf '%s\n' "$*" >> "$d/calls.log"
m="$d/.beads/embeddeddolt/db/.dolt/noms/manifest"
wrote() {
  echo "w$$-$(date +%s%N)" > "$d/.beads/last-touched"
  echo "w$$-$(date +%s%N)" > "$m"
}
case " $* " in
  *" context "*)
    printf '{"backend":"dolt","beads_dir":"%s/.beads","database":"db","dolt_mode":"embedded","repo_root":"%s","is_redirected":false,"is_worktree":false,"schema_version":1}\n' "$d" "$d"
    ;;
  *" list "*)
    cat "$d/list.json"
    ;;
  *" ready "*)
    printf '[]\n'
    ;;
  *" batch "*)
    prev=""
    for a in "$@"; do
      if [ "$prev" = "-f" ] || [ "$prev" = "--file" ]; then sed 's/^/BATCH: /' "$a" >> "$d/calls.log"; fi
      prev="$a"
    done
    wrote
    printf 'ok\n'
    ;;
  *" update "*|*" close "*|*" reopen "*)
    wrote
    printf '{}\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
]]

-- id -> title; short, distinctive titles so truncation cannot hide them.
local TITLES = {
  ["fb-1"] = "Apple pie",
  ["fb-2"] = "Banana split",
  ["fb-3"] = "Cherry tart",
  ["fb-4"] = "Date loaf",
  ["fb-5"] = "Elder jam",
  ["fb-6"] = "Fig roll",
  ["fb-7"] = "Grape soda",
}
local SIX = { "fb-1", "fb-2", "fb-3", "fb-4", "fb-5", "fb-6" }
local FIVE = { "fb-1", "fb-2", "fb-3", "fb-4", "fb-5" }

local dir, orig_path, orig_input, orig_select, orig_notify
local tree_win
local answer -- answer to the [y/N] prompt
local confirms -- { prompt = string, float = winid|nil, floats = { text } } per [y/N] prompt
local reason_floats -- float texts seen when the close reason was asked
local menu_choice -- "priority" or nil

local function items()
  local list = {}
  for i = 1, 7 do
    local id = "fb-" .. i
    list[#list + 1] = {
      id = id,
      title = TITLES[id],
      status = "open",
      priority = 2,
      issue_type = "task",
      created_at = "2026-11-17T10:00:00Z",
      updated_at = "2026-11-17T10:00:00Z",
    }
  end
  return list
end

local function log()
  local p = dir .. "/calls.log"
  return vim.fn.filereadable(p) == 1 and vim.fn.readfile(p) or {}
end

local function batch_lines()
  local out = {}
  for _, l in ipairs(log()) do
    if vim.startswith(l, "BATCH: ") then
      out[#out + 1] = vim.trim(l:sub(8))
    end
  end
  table.sort(out)
  return out
end

local function sleep(ms)
  vim.wait(ms, function()
    return false
  end, 10)
end

local function wait_for(pred, what, timeout)
  assert(vim.wait(timeout or 3000, function()
    local ok, v = pcall(pred)
    return ok and v
  end, 10), "timed out waiting for " .. what)
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

local function lines()
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(tree_win), 0, -1, false)
end

local function dump()
  return table.concat(lines(), "\n")
end

local function row_of(id)
  for i, l in ipairs(lines()) do
    if l:find("%f[%w%-]" .. vim.pesc(id) .. "%f[^%w%-]") then
      return i
    end
  end
end

local function on(id)
  local r = row_of(id)
  assert(r, id .. " not rendered:\n" .. dump())
  vim.api.nvim_set_current_win(tree_win)
  vim.api.nvim_win_set_cursor(tree_win, { r, 0 })
end

local function mark_all(ids)
  for _, id in ipairs(ids) do
    on(id)
    press("m")
  end
  -- cursor on an unmarked bead: the targets are the marks
  on("fb-7")
end

-- Floating windows other than the tree: list of { win, text }.
local function floats()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= tree_win and vim.api.nvim_win_get_config(w).relative ~= "" then
      local buf = vim.api.nvim_win_get_buf(w)
      out[#out + 1] = { win = w, text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") }
    end
  end
  return out
end

local function has_id(text, id)
  return text:find("%f[%w%-]" .. vim.pesc(id) .. "%f[^%w%-]") ~= nil
end

local function lists_all(text, ids)
  for _, id in ipairs(ids) do
    if not has_id(text, id) or not text:find(TITLES[id], 1, true) then
      return false
    end
  end
  return true
end

-- A float whose text names any of ids.
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

local function only_confirm()
  assert.are.equal(1, #confirms, "expected one [y/N] confirmation, got " .. #confirms)
  return confirms[1]
end

-- The [y/N] prompt was shown with a float listing every id of ids with its title.
local function assert_listed(c, ids)
  assert(
    c.float,
    "no float listing every target id with its title when '" .. c.prompt .. "' was asked; floats:\n"
      .. floats_dump(c.floats)
  )
  for _, id in ipairs(ids) do
    assert(has_id(c.text, id), "float lacks " .. id .. ":\n" .. c.text)
    assert(c.text:find(TITLES[id], 1, true), "float lacks the title of " .. id .. ":\n" .. c.text)
  end
end

local function assert_float_closed(c)
  wait_for(function()
    return not vim.api.nvim_win_is_valid(c.float)
  end, "the id float to close after the answer (" .. tostring(answer) .. ")")
end

describe("tree group confirm lists the ids in a float for more than 5 beads", function()
  before_each(function()
    orig_path = vim.env.PATH
    orig_input = vim.ui.input
    orig_select = vim.ui.select
    orig_notify = vim.notify
    confirms, reason_floats, answer, menu_choice = {}, nil, "y", nil
    vim.notify = function() end
    vim.ui.input = function(opts, cb)
      local p = tostring((opts or {}).prompt or "")
      if p:find("[y/N]", 1, true) then
        local fl = floats()
        local c = { prompt = p, floats = fl }
        for _, f in ipairs(fl) do
          if lists_all(f.text, SIX) or lists_all(f.text, FIVE) then
            c.float, c.text = f.win, f.text
            break
          end
        end
        confirms[#confirms + 1] = c
        return cb(answer)
      end
      if p:lower():find("reason", 1, true) then
        reason_floats = floats()
        return cb("done")
      end
      cb(nil)
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
    local d = vim.fn.tempname()
    vim.fn.mkdir(d .. "/.beads/embeddeddolt/db/.dolt/noms", "p")
    dir = vim.fn.resolve(d)
    vim.fn.writefile({ "x" }, dir .. "/.beads/last-touched")
    vim.fn.writefile({ "manifest-v1" }, dir .. "/.beads/embeddeddolt/db/.dolt/noms/manifest")
    vim.fn.writefile({ "" }, dir .. "/.beads/issues.jsonl")
    vim.fn.writefile(vim.split(FAKE_BD, "\n"), dir .. "/bd")
    vim.fn.setfperm(dir .. "/bd", "rwxr-xr-x")
    vim.fn.writefile({ vim.json.encode(items()) }, dir .. "/list.json")
    vim.env.FAKE_DIR = dir
    vim.env.PATH = dir .. ":" .. orig_path
    vim.cmd.cd(vim.fn.fnameescape(dir))
    cli.set_root(dir)
    if vim.fn.exists(":Beads") == 0 then
      vim.cmd.source(plugin_root .. "/plugin/beads.lua")
    end
    require("beads").setup({})
    local before = {}
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      before[w] = true
    end
    tree_win = nil
    vim.cmd("Beads tree")
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if not before[w] then
        tree_win = w
      end
    end
    assert(tree_win, ":Beads tree opened no window")
    wait_for(function()
      return row_of("fb-7") ~= nil
    end, "tree to list the beads", 10000)
  end)

  after_each(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    pcall(vim.cmd, "silent! only!")
    pcall(vim.cmd, "silent! %bwipeout!")
    sleep(300)
    vim.ui.input = orig_input
    vim.ui.select = orig_select
    vim.notify = orig_notify
    vim.env.PATH = orig_path
    cli.set_root(nil)
    vim.cmd.cd(vim.fn.fnameescape(plugin_root))
    vim.fn.delete(dir, "rf")
    require("beads").setup({})
  end)

  it("x on 6 marks lists the 6 ids with titles in a float; y closes it and closes the beads", function()
    mark_all(SIX)
    press("x")
    local c = only_confirm()
    assert_listed(c, SIX)
    assert.is_not_nil(reason_floats, "the close reason was not asked after y")
    assert.is_nil(
      float_naming(reason_floats, SIX),
      "the id float was still open when the close reason was asked:\n" .. floats_dump(reason_floats)
    )
    assert_float_closed(c)
    wait_for(function()
      return #batch_lines() >= 6
    end, "the six closes in a bd batch:\n" .. table.concat(log(), "\n"))
    local want = {}
    for _, id in ipairs(SIX) do
      want[#want + 1] = "close " .. id .. ' "done"'
    end
    table.sort(want)
    assert.are.same(want, batch_lines())
  end)

  it("x on 6 marks answered n: the float closes and nothing is closed", function()
    answer = "n"
    mark_all(SIX)
    press("x")
    local c = only_confirm()
    assert_listed(c, SIX)
    assert_float_closed(c)
    sleep(300)
    assert.are.same({}, batch_lines(), "beads closed after n:\n" .. table.concat(log(), "\n"))
  end)

  it("x on 6 marks cancelled (Esc): the float closes and nothing is closed", function()
    answer = nil
    mark_all(SIX)
    press("x")
    local c = only_confirm()
    assert_listed(c, SIX)
    assert_float_closed(c)
    sleep(300)
    assert.are.same({}, batch_lines(), "beads closed after cancel:\n" .. table.concat(log(), "\n"))
  end)

  it("A -> priority on 6 marks lists the 6 ids with titles in a float, which closes on y", function()
    menu_choice = "priority"
    mark_all(SIX)
    vim.api.nvim_set_current_win(tree_win)
    press("A")
    local c = only_confirm()
    assert_listed(c, SIX)
    assert_float_closed(c)
    wait_for(function()
      return #batch_lines() >= 6
    end, "the six priority updates in a bd batch:\n" .. table.concat(log(), "\n"))
  end)

  -- passes already: 5 or fewer beads keep the prompt-only confirmation.
  it("x on 5 marks asks the [y/N] prompt without a float listing the ids", function()
    mark_all(FIVE)
    press("x")
    local c = only_confirm()
    assert.is_nil(
      float_naming(c.floats, FIVE),
      "a float named the ids for 5 beads:\n" .. floats_dump(c.floats)
    )
    assert.is_truthy(c.prompt:find("5", 1, true), "prompt does not name 5 beads: " .. c.prompt)
  end)
end)
