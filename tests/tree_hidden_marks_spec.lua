-- Bead beads_nvim-qvs.2: group targets skip hidden marks; m on a closed fold marks only its head.
-- Interface under test: :Beads tree and its default keys (m, x, yy, V, f, H, zc, zo).
--
-- `bd` is replaced by a shell script on PATH (test double for the external binary), same as in
-- tests/tree_selection_spec.lua: every call is logged to $FAKE_DIR/calls.log, batch file lines are
-- logged with a "BATCH: " prefix.
--
-- assumption: the skip notification is one vim.notify message without a newline that contains
--   the word "hidden" and the number of skipped marks as a whitespace-bounded number (e.g.
--   "Beads: skipped 2 hidden marks").
-- assumption: a closed fold counts as one line for m's count: 3m on the closed ep-1 fold marks
--   ep-1, t-3 and t-4 (the count goes on past the fold), never the hidden children t-1 / t-2.
-- assumption: marks on beads inside a closed fold are not "hidden" in the sense of this bead
--   (only filter and H are tested).

local cli = require("beads.cli")

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local FAKE_BD = [[#!/bin/sh
d="$FAKE_DIR"
printf '%s\n' "$*" >> "$d/calls.log"
m="$d/.beads/embeddeddolt/db/.dolt/noms/manifest"
wrote() {
  if [ -f "$d/after.json" ]; then cp "$d/after.json" "$d/list.json"; fi
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
  *" --claim "*)
    if [ -f "$d/fail" ]; then
      for id in $(cat "$d/fail"); do
        case " $* " in *" $id "*) echo "claim failed for $id" >&2; exit 1;; esac
      done
    fi
    wrote
    printf '{}\n'
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

local dir, orig_path, orig_input, orig_select, orig_notify
local notes, prompts, filter_answer

local function bead(id, title, extra)
  local b = {
    id = id,
    title = title,
    status = "open",
    priority = 2,
    issue_type = "task",
    created_at = "2026-11-17T10:00:00Z",
    updated_at = "2026-11-17T10:00:00Z",
  }
  for k, v in pairs(extra or {}) do
    b[k] = v
  end
  return b
end

local function child_of(id, parent, title, extra)
  local e = vim.tbl_extend("force", {}, extra or {})
  e.parent = parent
  e.dependencies = { { issue_id = id, depends_on_id = parent, type = "parent-child" } }
  return bead(id, title, e)
end

-- Tree order (priority sort): ep-1 > { t-1, t-2 }, t-3, t-4, then closed t-5 / t-6 (shown by H).
-- t-3 and t-4 carry label "keep", so filter "label:keep" shows only them (t-1, t-2 hidden).
local function items()
  return {
    bead("ep-1", "Epic one", { issue_type = "epic", priority = 1 }),
    child_of("t-1", "ep-1", "Task one"),
    child_of("t-2", "ep-1", "Task two"),
    bead("t-3", "Task three", { priority = 3, labels = { "keep" } }),
    bead("t-4", "Task four", { priority = 3, labels = { "keep" } }),
    bead("t-5", "Task five", { priority = 4, status = "closed" }),
    bead("t-6", "Task six", { priority = 4, status = "closed" }),
  }
end

local function write_json(name, list)
  vim.fn.writefile({ vim.json.encode(list) }, dir .. "/" .. name)
end

local function log()
  local p = dir .. "/calls.log"
  return vim.fn.filereadable(p) == 1 and vim.fn.readfile(p) or {}
end

local function argv_lines()
  local out = {}
  for _, l in ipairs(log()) do
    if not vim.startswith(l, "BATCH: ") then
      out[#out + 1] = l
    end
  end
  return out
end

local function batch_lines()
  local out = {}
  for _, l in ipairs(log()) do
    if vim.startswith(l, "BATCH: ") then
      out[#out + 1] = l:sub(8)
    end
  end
  return out
end

-- Ids closed so far, through `bd close <ids...>` or `close <id>` lines of a batch file.
local function closed_ids()
  local set = {}
  for _, l in ipairs(batch_lines()) do
    local id = vim.trim(l):match("^close%s+\"?([%w%-%.]+)")
    if id then
      set[id] = true
    end
  end
  for _, l in ipairs(argv_lines()) do
    local rest = (" " .. l):match(" close (.*)$")
    if rest then
      for tok in rest:gmatch("%S+") do
        if tok:sub(1, 1) == "-" then
          break
        end
        set[tok] = true
      end
    end
  end
  local out = vim.tbl_keys(set)
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

local tree_win

local function tbuf()
  return vim.api.nvim_win_get_buf(tree_win)
end

local function lines()
  return vim.api.nvim_buf_get_lines(tbuf(), 0, -1, false)
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

local function hl_names(d)
  local out = {}
  for _, k in ipairs({ "hl_group", "line_hl_group", "sign_hl_group", "number_hl_group", "cursorline_hl_group" }) do
    if type(d[k]) == "string" then
      out[#out + 1] = d[k]
    end
  end
  for _, chunk in ipairs(d.virt_text or {}) do
    local hl = chunk[2]
    if type(hl) == "string" then
      out[#out + 1] = hl
    elseif type(hl) == "table" then
      vim.list_extend(out, hl)
    end
  end
  return out
end

local function is_marked(id)
  local r = row_of(id)
  assert(r, id .. " not rendered:\n" .. dump())
  local glyph = lines()[r]:find("▍", 1, true) ~= nil
  local hl = false
  local ems = vim.api.nvim_buf_get_extmarks(tbuf(), -1, { r - 1, 0 }, { r - 1, -1 }, { details = true })
  for _, em in ipairs(ems) do
    local d = em[4] or {}
    if type(d.sign_text) == "string" and d.sign_text:find("▍", 1, true) then
      glyph = true
    end
    for _, chunk in ipairs(d.virt_text or {}) do
      if type(chunk[1]) == "string" and chunk[1]:find("▍", 1, true) then
        glyph = true
      end
    end
    for _, n in ipairs(hl_names(d)) do
      if n == "BeadsMarked" then
        hl = true
      end
    end
  end
  return glyph and hl
end

local ALL = { "ep-1", "t-1", "t-2", "t-3", "t-4", "t-5", "t-6" }

local function marked_set()
  local out = {}
  for _, id in ipairs(ALL) do
    if row_of(id) and is_marked(id) then
      out[#out + 1] = id
    end
  end
  table.sort(out)
  return out
end

local function mark(id)
  on(id)
  press("m")
end

local function open_tree()
  local before = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    before[w] = true
  end
  vim.cmd("Beads tree")
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if not before[w] then
      tree_win = w
    end
  end
  assert(tree_win, ":Beads tree opened no window")
  wait_for(function()
    return row_of("t-4") ~= nil
  end, "tree to list the beads")
end

-- Applies a tree filter through the f key ("" clears it).
local function set_filter(text)
  filter_answer = text
  vim.api.nvim_set_current_win(tree_win)
  press("f")
  filter_answer = nil
end

local function toggle_closed()
  vim.api.nvim_set_current_win(tree_win)
  press("H")
end

local function notes_dump()
  local t = {}
  for _, n in ipairs(notes) do
    t[#t + 1] = n.msg
  end
  return table.concat(t, "\n---\n")
end

local function hidden_notes()
  local out = {}
  for _, n in ipairs(notes) do
    if n.msg:lower():find("hidden", 1, true) then
      out[#out + 1] = n.msg
    end
  end
  return out
end

-- Exactly one one-line "hidden" note naming the count n.
local function assert_skip_note(n)
  local got = hidden_notes()
  assert.are.equal(1, #got, "expected one note about skipped hidden marks; notes:\n" .. notes_dump())
  assert.is_nil(got[1]:find("\n", 1, true), "skip note is not one line: " .. got[1])
  assert.is_truthy(
    (" " .. got[1] .. " "):find("[%s%(]" .. n .. "[%s%)]"),
    "skip note does not say " .. n .. " marks were skipped: " .. got[1]
  )
end

local function confirm_prompts()
  local out = {}
  for _, p in ipairs(prompts) do
    if p:find("[y/N]", 1, true) then
      out[#out + 1] = p
    end
  end
  return out
end

local function reg_lines()
  local s = vim.fn.getreg('"'):gsub("\n$", "")
  return vim.split(s, "\n", { plain = true })
end

describe("tree group targets with hidden marks", function()
  before_each(function()
    orig_path = vim.env.PATH
    orig_input = vim.ui.input
    orig_select = vim.ui.select
    orig_notify = vim.notify
    notes, prompts, filter_answer = {}, {}, nil
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    vim.ui.input = function(opts, cb)
      local p = tostring((opts or {}).prompt or "")
      if p:lower():find("filter", 1, true) then
        return cb(filter_answer)
      end
      prompts[#prompts + 1] = p
      if p:find("[y/N]", 1, true) then
        return cb("y")
      end
      if p:lower():find("reason", 1, true) then
        return cb("done")
      end
      cb(nil)
    end
    vim.ui.select = function(_, _, cb)
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
    write_json("list.json", items())
    vim.env.FAKE_DIR = dir
    vim.env.PATH = dir .. ":" .. orig_path
    vim.cmd.cd(vim.fn.fnameescape(dir))
    cli.set_root(dir)
    if vim.fn.exists(":Beads") == 0 then
      vim.cmd.source(plugin_root .. "/plugin/beads.lua")
    end
    require("beads").setup({ tree = { layout = "split" } })
    tree_win = nil
    open_tree()
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
    require("beads").setup({ tree = { layout = "split" } })
  end)

  -- ── hidden marks are not targets ─────────────────────────────────────────────────────────────
  it("x on the cursor bead ignores a mark hidden by the filter (closes only the cursor bead)", function()
    mark("t-1")
    set_filter("label:keep")
    assert.is_nil(row_of("t-1"), "filter did not hide t-1:\n" .. dump())
    on("t-3")
    press("x")
    wait_for(function()
      return #closed_ids() >= 1
    end, "the close; log:\n" .. table.concat(log(), "\n"))
    sleep(300)
    assert.are.same({ "t-3" }, closed_ids(), "hidden mark was closed:\n" .. table.concat(log(), "\n"))
    assert.are.same({}, confirm_prompts(), "single visible target was confirmed")
  end)

  it("yy with only hidden marks yanks the cursor bead", function()
    mark("t-1")
    mark("t-2")
    set_filter("label:keep")
    vim.fn.setreg('"', "")
    on("t-4")
    press("yy")
    assert.are.same({ "t-4" }, reg_lines())
  end)

  it("visible marks are used and marks hidden by H are skipped", function()
    toggle_closed()
    wait_for(function()
      return row_of("t-5") ~= nil
    end, "H to show closed beads")
    mark("t-5")
    mark("t-3")
    mark("t-4")
    toggle_closed()
    wait_for(function()
      return row_of("t-5") == nil
    end, "H to hide closed beads")
    on("t-2")
    press("x")
    local c = confirm_prompts()
    assert.are.equal(1, #c, "expected one [y/N] confirmation; prompts:\n" .. table.concat(prompts, "\n"))
    assert.is_truthy(c[1]:find("Close 2 beads? [y/N]", 1, true), "confirmation text: " .. c[1])
    wait_for(function()
      return #closed_ids() >= 2
    end, "the two closes; log:\n" .. table.concat(log(), "\n"))
    sleep(300)
    assert.are.same({ "t-3", "t-4" }, closed_ids())
  end)

  it("with only hidden marks, V over two lines then x closes exactly those two", function()
    mark("t-1")
    set_filter("label:keep")
    on("t-3")
    press("Vjx")
    pcall(vim.cmd, "stopinsert")
    vim.wait(3000, function()
      return #closed_ids() >= 2
    end, 10)
    sleep(300)
    assert.are.same({ "t-3", "t-4" }, closed_ids(), "log:\n" .. table.concat(log(), "\n"))
  end)

  -- ── notification ─────────────────────────────────────────────────────────────────────────────
  it("one one-line note says how many hidden marks were skipped", function()
    toggle_closed()
    wait_for(function()
      return row_of("t-6") ~= nil
    end, "H to show closed beads")
    mark("t-5")
    mark("t-6")
    toggle_closed()
    wait_for(function()
      return row_of("t-5") == nil
    end, "H to hide closed beads")
    vim.fn.setreg('"', "")
    on("t-3")
    press("yy")
    assert.are.same({ "t-3" }, reg_lines())
    assert_skip_note(2)
  end)

  -- ── hidden marks are kept ────────────────────────────────────────────────────────────────────
  it("skipped hidden marks stay and apply again once visible", function()
    mark("t-1")
    set_filter("label:keep")
    on("t-3")
    press("x")
    wait_for(function()
      return #closed_ids() >= 1
    end, "the close; log:\n" .. table.concat(log(), "\n"))
    sleep(300)
    set_filter("")
    wait_for(function()
      return row_of("t-1") ~= nil
    end, "clearing the filter")
    assert.is_true(is_marked("t-1"), "hidden mark on t-1 was dropped:\n" .. dump())
    vim.fn.setreg('"', "")
    on("t-4")
    press("yy")
    assert.are.same({ "t-1" }, reg_lines(), "mark on t-1 did not apply again once visible")
  end)

  -- ── m on a closed fold ───────────────────────────────────────────────────────────────────────
  local function fold_epic()
    on("ep-1")
    press("zc")
    assert.are_not.equal(-1, vim.api.nvim_win_call(tree_win, function()
      return vim.fn.foldclosed(row_of("t-1"))
    end), "zc did not fold ep-1")
    on("ep-1")
  end

  it("m on a closed fold marks only the fold head (passes already)", function()
    fold_epic()
    press("m")
    assert.are.same({ "ep-1" }, marked_set(), "marked beads differ\n" .. dump())
  end)

  it("3m on a closed fold marks the head, skips the hidden children and goes on past the fold", function()
    fold_epic()
    press("3m")
    assert.is_false(is_marked("t-1"), "3m marked hidden child t-1")
    assert.is_false(is_marked("t-2"), "3m marked hidden child t-2")
    assert.are.same({ "ep-1", "t-3", "t-4" }, marked_set(), "marked beads differ\n" .. dump())
  end)
end)
