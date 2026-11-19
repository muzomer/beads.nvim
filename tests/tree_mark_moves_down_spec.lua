-- Bead beads_nvim-wrn: in the tree, m (mark) moves the cursor to the next bead row.
-- Interface under test: :Beads tree and its default keys (m, M, zc, ?) plus README.md.
-- Layout: tree = { layout = "split" } (the old side split, like tree_selection_spec.lua).
--
-- `bd` is replaced by a shell script on PATH (test double for the external binary) that answers
-- `context`, `list` and `ready`; no write verbs are used here.
--
-- Tree order (priority sort): ep-1 > { t-1, t-2 }, t-3, t-4; t-4 is the last bead row.
--
-- assumption: "the next bead row" after a closed fold is the first row after the fold's end
--   (here t-3 after the closed ep-1 fold), the same row the marking count goes on with.
-- assumption: "a count past the end ends on the last row" means the last bead row (t-4).
-- assumption: the help (?) line of the m key and a README line naming `m` say it moves the cursor
--   with the word "down" or "next" (case-insensitive).

local cli = require("beads.cli")

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local FAKE_BD = [[#!/bin/sh
d="$FAKE_DIR"
printf '%s\n' "$*" >> "$d/calls.log"
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
  *)
    printf '{}\n'
    ;;
esac
]]

local dir, orig_path, orig_notify
local tree_win

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

local function child_of(id, parent, title)
  return bead(id, title, {
    parent = parent,
    dependencies = { { issue_id = id, depends_on_id = parent, type = "parent-child" } },
  })
end

local function items()
  return {
    bead("ep-1", "Epic one", { issue_type = "epic", priority = 1 }),
    child_of("t-1", "ep-1", "Task one"),
    child_of("t-2", "ep-1", "Task two"),
    bead("t-3", "Task three", { priority = 3 }),
    bead("t-4", "Task four", { priority = 3 }),
  }
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

local function cursor_row()
  return vim.api.nvim_win_get_cursor(tree_win)[1]
end

-- Asserts the tree cursor is on the row of bead id.
local function assert_cursor_on(id, where)
  local r = row_of(id)
  assert(r, id .. " not rendered:\n" .. dump())
  local got = cursor_row()
  assert.are.equal(
    r,
    got,
    (where or "") .. ": cursor on row " .. got .. " (" .. tostring(lines()[got]) .. "), want " .. id .. "\n" .. dump()
  )
end

local function is_marked(id)
  local r = row_of(id)
  assert(r, id .. " not rendered:\n" .. dump())
  local ems = vim.api.nvim_buf_get_extmarks(tbuf(), -1, { r - 1, 0 }, { r - 1, -1 }, { details = true })
  for _, em in ipairs(ems) do
    local d = em[4] or {}
    for _, k in ipairs({ "hl_group", "line_hl_group", "sign_hl_group", "number_hl_group" }) do
      if d[k] == "BeadsMarked" then
        return true
      end
    end
    for _, chunk in ipairs(d.virt_text or {}) do
      local hl = chunk[2]
      if hl == "BeadsMarked" or (type(hl) == "table" and vim.tbl_contains(hl, "BeadsMarked")) then
        return true
      end
    end
  end
  return false
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
  assert.are.same(ids, marked_set(), (where or "") .. ": marked beads differ\n" .. dump())
end

local function fold_epic()
  on("ep-1")
  press("zc")
  assert.are_not.equal(-1, vim.api.nvim_win_call(tree_win, function()
    return vim.fn.foldclosed(row_of("t-1"))
  end), "zc did not fold ep-1")
  on("ep-1")
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

local function moves_down(s)
  s = s:lower()
  return s:find("down", 1, true) ~= nil or s:find("next", 1, true) ~= nil
end

describe("tree: m moves the cursor down", function()
  before_each(function()
    orig_path = vim.env.PATH
    orig_notify = vim.notify
    vim.notify = function() end
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
    vim.notify = orig_notify
    vim.env.PATH = orig_path
    cli.set_root(nil)
    vim.cmd.cd(vim.fn.fnameescape(plugin_root))
    vim.fn.delete(dir, "rf")
    require("beads").setup({ tree = { layout = "split" } })
  end)

  it("m marks the cursor bead and moves the cursor to the next bead row", function()
    on("t-1")
    press("m")
    assert_marked({ "t-1" }, "after m")
    assert_cursor_on("t-2", "after m on t-1")
  end)

  it("pressing m repeatedly marks consecutive beads", function()
    on("ep-1")
    press("m")
    press("m")
    press("m")
    assert_marked({ "ep-1", "t-1", "t-2" }, "after m m m")
    assert_cursor_on("t-3", "after m m m from ep-1")
  end)

  it("m on a marked bead unmarks it and also moves down", function()
    on("t-2")
    press("m")
    assert_marked({ "t-2" }, "after first m")
    on("t-2")
    press("m")
    assert_marked({}, "after m on the marked bead")
    assert_cursor_on("t-3", "after unmarking t-2")
  end)

  it("3m marks three beads and leaves the cursor on the row after the third", function()
    on("ep-1")
    press("3m")
    assert_marked({ "ep-1", "t-1", "t-2" }, "after 3m")
    assert_cursor_on("t-3", "after 3m from ep-1")
  end)

  it("m on a closed fold marks only its head and the cursor lands after the fold", function()
    fold_epic()
    press("m")
    assert_marked({ "ep-1" }, "after m on the closed fold")
    assert_cursor_on("t-3", "after m on the closed ep-1 fold")
  end)

  it("2m on a closed fold counts the fold as one bead and lands after the second", function()
    fold_epic()
    press("2m")
    assert_marked({ "ep-1", "t-3" }, "after 2m on the closed fold")
    assert_cursor_on("t-4", "after 2m from the closed ep-1 fold")
  end)

  it("m on the last bead marks it and the cursor stays on it (passes already: no row below)", function()
    on("t-4")
    press("m")
    assert_marked({ "t-4" }, "after m on the last bead")
    assert_cursor_on("t-4", "after m on the last bead")
  end)

  it("a count past the end marks to the end and ends on the last row", function()
    on("t-3")
    press("5m")
    assert_marked({ "t-3", "t-4" }, "after 5m from t-3")
    assert_cursor_on("t-4", "after 5m from t-3")
  end)

  it("M clears the marks and does not move the cursor (passes already: M keeps the cursor)", function()
    on("t-1")
    press("m")
    on("t-2")
    press("m")
    on("t-1")
    press("M")
    assert_marked({}, "after M")
    assert_cursor_on("t-1", "after M")
  end)

  it("the tree help (?) says m moves down", function()
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
    local help = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(f), 0, -1, false)
    local mline
    for _, l in ipairs(help) do
      if (" " .. l):find("%sm%s") and l:lower():find("mark", 1, true) and not l:find("▍", 1, true) then
        mline = l
        break
      end
    end
    assert(mline, "help has no line for the m key:\n" .. table.concat(help, "\n"))
    assert.is_true(moves_down(mline), "help line for m does not say it moves down: " .. mline)
  end)

  it("README says m moves down", function()
    local readme = vim.fn.readfile(plugin_root .. "/README.md")
    local found = false
    for _, l in ipairs(readme) do
      local s = l:find("`m`", 1, true)
      if s and moves_down(l) then
        found = true
      end
    end
    assert.is_true(found, "no README line naming `m` says it moves down (or to the next bead)")
  end)
end)
