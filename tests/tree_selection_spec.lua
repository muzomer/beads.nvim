-- Bead beads_nvim-2qo.1: tree selection (marks, visual range) and group-aware close / claim /
-- reopen / yank, run by a shared group executor.
-- Interface under test: :Beads tree and its default keys (m, M, V, x, C, A, yy, yr, ?).
--
-- `bd` is replaced by a shell script on PATH (test double for the external binary). Every call is
-- logged to $FAKE_DIR/calls.log; for `batch -f <file>` the file's lines are logged too, prefixed
-- with "BATCH: " (cli.batch deletes the file afterwards). Write verbs (batch, update, close, reopen)
-- behave like real bd for the watcher: list.json is replaced by after.json (if any), then
-- .beads/last-touched and the Dolt manifest are rewritten. `update <id> --claim` exits 1 for ids
-- listed in $FAKE_DIR/fail. `context` reports an embedded backend so the watcher runs.
--
-- assumption: the confirmation for >1 bead is asked through vim.ui.input with a prompt containing
--   "Close 3 beads? [y/N]" (stub answers "y"); the close reason is asked through vim.ui.input
--   with a prompt containing "reason". The stub dispatches on prompt text, not call order.
-- assumption: a marked line shows ▍ either in its text or in an extmark on its row (sign_text /
--   virt_text), and BeadsMarked as hl_group / line_hl_group / sign_hl_group / virt_text hl.
-- assumption: the action menu (A) is vim.ui.select; the reopen entry's text contains "reopen".
-- assumption: yy / yr with marks put the ids / commands in tree order, one per line, in the "
--   register (one trailing newline allowed).
-- assumption: after a partly failed per-bead action the beads that succeeded are unmarked.

local cli = require("beads.cli")
local store = require("beads.store")

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
local notes, prompts

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

-- Tree order (priority sort): ep-1 > { t-1, t-2 }, t-3, t-4.
local function items(stamp)
  local list = {
    bead("ep-1", "Epic one", { issue_type = "epic", priority = 1 }),
    child_of("t-1", "ep-1", "Task one"),
    child_of("t-2", "ep-1", "Task two"),
    bead("t-3", "Task three", { priority = 3 }),
    bead("t-4", "Task four", { priority = 3 }),
  }
  if stamp then
    for _, b in ipairs(list) do
      b.updated_at = stamp
    end
  end
  return list
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

local function count_calls(pat)
  local n = 0
  for _, l in ipairs(argv_lines()) do
    if (" " .. l .. " "):find(pat) then
      n = n + 1
    end
  end
  return n
end

local function has_word(s, w)
  return (" " .. s .. " "):find("[%s\"']" .. vim.pesc(w) .. "[%s\"']") ~= nil
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

-- { glyph = bool, hl = bool } for the row of bead id.
local function mark_state(id)
  local r = row_of(id)
  assert(r, id .. " not rendered:\n" .. dump())
  local line = lines()[r]
  local glyph = line:find("▍", 1, true) ~= nil
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
  return { glyph = glyph, hl = hl }
end

local function is_marked(id)
  local s = mark_state(id)
  return s.glyph and s.hl
end

local function marked_set()
  local out = {}
  for _, id in ipairs({ "ep-1", "t-1", "t-2", "t-3", "t-4" }) do
    if row_of(id) and is_marked(id) then
      out[#out + 1] = id
    end
  end
  return out
end

local function assert_marked(ids, where)
  local want = vim.list_slice(ids)
  table.sort(want)
  local got = marked_set()
  table.sort(got)
  assert.are.same(want, got, (where or "") .. ": marked beads differ\n" .. dump())
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

local function notes_with(s)
  local out = {}
  for _, n in ipairs(notes) do
    if n.msg:find(s, 1, true) then
      out[#out + 1] = n
    end
  end
  return out
end

local function notes_dump()
  local t = {}
  for _, n in ipairs(notes) do
    t[#t + 1] = n.msg
  end
  return table.concat(t, "\n---\n")
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

describe("tree selection and group actions", function()
  before_each(function()
    orig_path = vim.env.PATH
    orig_input = vim.ui.input
    orig_select = vim.ui.select
    orig_notify = vim.notify
    notes, prompts = {}, {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    vim.ui.input = function(opts, cb)
      local p = tostring((opts or {}).prompt or "")
      prompts[#prompts + 1] = p
      if p:find("[y/N]", 1, true) then
        return cb("y")
      end
      if p:lower():find("reason", 1, true) then
        return cb("done")
      end
      cb(nil)
    end
    vim.ui.select = function(list, opts, cb)
      local fmt = (opts or {}).format_item or tostring
      for i, it in ipairs(list) do
        if tostring(fmt(it)):lower():find("reopen", 1, true) then
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
    write_json("list.json", items())
    vim.env.FAKE_DIR = dir
    vim.env.PATH = dir .. ":" .. orig_path
    vim.cmd.cd(vim.fn.fnameescape(dir))
    cli.set_root(dir)
    if vim.fn.exists(":Beads") == 0 then
      vim.cmd.source(plugin_root .. "/plugin/beads.lua")
    end
    require("beads").setup({})
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
    require("beads").setup({})
  end)

  -- ── marks ────────────────────────────────────────────────────────────────────────────────────
  it("m toggles a mark (▍ + BeadsMarked) on the cursor bead", function()
    assert_marked({}, "before m")
    mark("t-3")
    local s = mark_state("t-3")
    assert.is_true(s.glyph, "marked line shows no ▍:\n" .. dump())
    assert.is_true(s.hl, "marked line has no BeadsMarked highlight")
    assert_marked({ "t-3" }, "after m")
    mark("t-3")
    assert_marked({}, "after second m")
  end)

  it("3m marks three beads from the cursor down; M clears all", function()
    on("t-1")
    press("3m")
    assert_marked({ "t-1", "t-2", "t-3" }, "after 3m")
    press("M")
    assert_marked({}, "after M")
  end)

  it("marks survive a store refresh, folding, a filter change and moving the tree", function()
    mark("t-1")
    mark("t-4")
    assert_marked({ "t-1", "t-4" }, "after marking")

    local done = false
    store.refresh(dir, function()
      done = true
    end)
    wait_for(function()
      return done
    end, "store refresh")
    sleep(50)
    assert_marked({ "t-1", "t-4" }, "after store refresh")

    on("ep-1")
    press("zc")
    assert.are_not.equal(-1, vim.api.nvim_win_call(tree_win, function()
      return vim.fn.foldclosed(row_of("t-1"))
    end), "zc did not fold ep-1")
    press("zo")
    assert_marked({ "t-1", "t-4" }, "after fold / unfold")

    local orig = vim.ui.input
    vim.ui.input = function(opts, cb)
      if tostring((opts or {}).prompt or ""):lower():find("filter", 1, true) then
        return cb("Task")
      end
      return orig(opts, cb)
    end
    vim.api.nvim_set_current_win(tree_win)
    press("f")
    assert.is_truthy(lines()[1]:find("filter: Task", 1, true), "filter not applied:\n" .. dump())
    assert_marked({ "t-1", "t-4" }, "after filter")
    vim.ui.input = function(opts, cb)
      if tostring((opts or {}).prompt or ""):lower():find("filter", 1, true) then
        return cb("")
      end
      return orig(opts, cb)
    end
    press("f")
    vim.ui.input = orig
    assert_marked({ "t-1", "t-4" }, "after clearing the filter")

    local pos = vim.api.nvim_win_get_position(tree_win)
    vim.api.nvim_set_current_win(tree_win)
    press("L")
    assert.is_true(vim.api.nvim_win_is_valid(tree_win), "L closed the tree window")
    assert.are_not.same(pos, vim.api.nvim_win_get_position(tree_win), "L did not move the tree")
    assert_marked({ "t-1", "t-4" }, "after moving the tree")
  end)

  -- ── close ────────────────────────────────────────────────────────────────────────────────────
  it("x with 3 marks confirms 'Close 3 beads? [y/N]' and closes them in one bd batch", function()
    mark("t-1")
    mark("t-3")
    mark("t-4")
    on("t-2")
    press("x")
    local c = confirm_prompts()
    assert.are.equal(1, #c, "expected one [y/N] confirmation; prompts:\n" .. table.concat(prompts, "\n"))
    assert.is_truthy(c[1]:find("Close 3 beads? [y/N]", 1, true), "confirmation text: " .. c[1])
    wait_for(function()
      return #closed_ids() >= 3
    end, "the three closes")
    sleep(200)
    assert.are.equal(1, count_calls(" batch "), "expected one bd batch call:\n" .. table.concat(log(), "\n"))
    assert.are.equal(0, count_calls(" close "), "beads closed outside the batch:\n" .. table.concat(log(), "\n"))
    assert.are.same({ "t-1", "t-3", "t-4" }, closed_ids())
    for _, l in ipairs(batch_lines()) do
      if vim.trim(l):match("^close") then
        assert.is_true(has_word(l, "done"), "batch close line lacks the reason: " .. l)
      end
    end
    wait_for(function()
      return #marked_set() == 0
    end, "marks cleared after the close (" .. table.concat(marked_set(), ",") .. ")")
  end)

  it("without marks, V over 2 lines then x closes exactly those 2", function()
    on("t-3")
    press("Vjx")
    pcall(vim.cmd, "stopinsert")
    wait_for(function()
      return #closed_ids() >= 2
    end, "the two closes; log:\n" .. table.concat(log(), "\n"))
    sleep(200)
    assert.are.same({ "t-3", "t-4" }, closed_ids())
    for _, l in ipairs(batch_lines()) do
      if vim.trim(l):match("^close") then
        assert.is_true(has_word(l, "done"), "batch close line lacks the reason: " .. l)
      end
    end
  end)

  it("x on a single bead (no marks) closes it without confirmation", function()
    on("t-3")
    press("x")
    wait_for(function()
      return #closed_ids() >= 1
    end, "the close")
    sleep(200)
    assert.are.same({}, confirm_prompts(), "single bead was confirmed")
    assert.are.same({ "t-3" }, closed_ids())
  end)

  -- ── claim / reopen ───────────────────────────────────────────────────────────────────────────
  it("C on marked beads claims each", function()
    mark("t-1")
    mark("t-2")
    mark("t-4")
    on("t-3")
    press("C")
    wait_for(function()
      return count_calls(" %-%-claim ") >= 3
    end, "three claims; log:\n" .. table.concat(log(), "\n"))
    for _, id in ipairs({ "t-1", "t-2", "t-4" }) do
      local n = 0
      for _, l in ipairs(argv_lines()) do
        if l:find("--claim", 1, true) and has_word(l, id) then
          n = n + 1
        end
      end
      assert.are.equal(1, n, id .. " not claimed exactly once:\n" .. table.concat(log(), "\n"))
    end
    for _, l in ipairs(argv_lines()) do
      if l:find("--claim", 1, true) then
        assert.is_false(has_word(l, "t-3"), "cursor bead t-3 claimed despite marks")
      end
    end
  end)

  it("reopen from the A menu reopens all marked beads with one 'bd reopen <ids...>'", function()
    mark("t-1")
    mark("t-3")
    mark("t-4")
    local menu
    local orig = vim.ui.select
    vim.ui.select = function(list, opts, cb)
      menu = list
      return orig(list, opts, cb)
    end
    press("A")
    assert(menu, "A opened no vim.ui.select menu")
    wait_for(function()
      return count_calls(" reopen ") >= 1
    end, "bd reopen; log:\n" .. table.concat(log(), "\n"))
    sleep(200)
    assert.are.equal(1, count_calls(" reopen "), "expected one bd reopen call:\n" .. table.concat(log(), "\n"))
    local l
    for _, x in ipairs(argv_lines()) do
      if (" " .. x .. " "):find(" reopen ") then
        l = x
      end
    end
    for _, id in ipairs({ "t-1", "t-3", "t-4" }) do
      assert.is_true(has_word(l, id), "reopen call does not name " .. id .. ": " .. l)
    end
    assert.is_false(has_word(l, "t-2"), "reopen call names unmarked t-2: " .. l)
  end)

  -- ── yank ─────────────────────────────────────────────────────────────────────────────────────
  it("yy with marks yanks all ids, one per line", function()
    vim.fn.setreg('"', "")
    mark("t-4")
    mark("ep-1")
    mark("t-2")
    on("t-3")
    press("yy")
    assert.are.same({ "ep-1", "t-2", "t-4" }, reg_lines())
  end)

  it("yr with marks yanks all run commands (run-epic for epics), one per line", function()
    vim.fn.setreg('"', "")
    mark("ep-1")
    mark("t-3")
    on("t-4")
    press("yr")
    assert.are.same({ "/beads-workflow:run-epic ep-1", "/beads-workflow:run-bead t-3" }, reg_lines())
  end)

  -- ── failures ─────────────────────────────────────────────────────────────────────────────────
  it("a failing per-bead call gives one 'Beads: n of m failed: <ids>' note and keeps it marked", function()
    vim.fn.writefile({ "t-2" }, dir .. "/fail")
    mark("t-1")
    mark("t-2")
    mark("t-4")
    press("C")
    wait_for(function()
      return #notes_with("failed") > 0
    end, "a failure notification; notes:\n" .. notes_dump())
    sleep(500)
    local got = {}
    for _, n in ipairs(notes) do
      if n.msg:find("failed", 1, true) or n.msg:find("exited", 1, true) then
        got[#got + 1] = n
      end
    end
    assert.are.equal(1, #got, "expected one failure notification:\n" .. notes_dump())
    assert.is_truthy(got[1].msg:find("Beads: 1 of 3 failed: t-2", 1, true), "failure note: " .. got[1].msg)
    wait_for(function()
      return #marked_set() == 1
    end, "only the failed bead marked (" .. table.concat(marked_set(), ",") .. ")")
    assert_marked({ "t-2" }, "after the partial failure")
  end)

  -- ── self-write ───────────────────────────────────────────────────────────────────────────────
  it("the plugin's own group action emits no external-change notification", function()
    -- let the watcher start and settle
    wait_for(function()
      return count_calls(" context ") > 0
    end, "bd context (watcher start)")
    sleep(600)
    write_json("after.json", items("2026-11-17T11:00:00Z"))
    mark("t-1")
    mark("t-2")
    mark("t-4")
    press("C")
    wait_for(function()
      return count_calls(" %-%-claim ") >= 3
    end, "three claims; log:\n" .. table.concat(log(), "\n"))
    sleep(2500)
    assert.are.same({}, notes_with("changed externally"), "own action notified:\n" .. notes_dump())
    -- control: a real external change is still notified (the watcher was live)
    vim.fn.delete(dir .. "/after.json")
    local list = items("2026-11-17T11:00:00Z")
    list[5].updated_at = "2026-11-17T12:00:00Z"
    write_json("list.json", list)
    vim.fn.writefile({ "ext" }, dir .. "/.beads/last-touched")
    vim.fn.writefile({ "ext" }, dir .. "/.beads/embeddeddolt/db/.dolt/noms/manifest")
    wait_for(function()
      return #notes_with("changed externally") > 0
    end, "external-change notification (control); notes:\n" .. notes_dump(), 5000)
  end)

  -- ── legend / highlight ───────────────────────────────────────────────────────────────────────
  it("BeadsMarked highlight group exists", function()
    assert.are.equal(1, vim.fn.hlexists("BeadsMarked"))
  end)

  it("tree ? legend lists ▍ with a meaning", function()
    vim.api.nvim_set_current_win(tree_win)
    local before = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      before[w] = true
    end
    press("?")
    local f
    vim.wait(1000, function()
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if not before[w] and vim.api.nvim_win_get_config(w).relative ~= "" then
          f = w
          return true
        end
      end
      return false
    end, 10)
    assert(f, "? opened no help float")
    local found = false
    for _, l in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(f), 0, -1, false)) do
      local s, e = l:find("▍", 1, true)
      if s and (l:sub(1, s - 1) .. l:sub(e + 1)):find("%a") then
        found = true
      end
    end
    assert.is_true(found, "tree legend has no ▍ line with a meaning")
  end)
end)
