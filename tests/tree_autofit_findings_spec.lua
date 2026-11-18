-- Findings for bead beads_nvim-4u9.13 (tree auto-fit), reviewer blockers:
--   1. tree.lua:568 - every fold change must refit, not only <Tab> / the mouse fold click: the native
--      fold keys zo/zc/za/zM/zR in the tree and the reveal (zv) done on BufEnter of a beads:// buffer.
--   2. tree.lua:335 - manual-resize detection must compare against the size the window actually got:
--      when the requested size cannot be applied (max_width wider than the screen, a bottom tree on a
--      screen with few lines), a WinResized from another window must not turn auto-fit off.
-- Interface: :Beads tree [left|bottom], fold keys pressed in the tree (feedkeys, remap allowed so the
-- plugin's buffer-local maps run), :edit beads://<id> in the main window, VimResized / WinResized fired
-- with nvim_exec_autocmds (headless nvim never fires WinResized itself).
-- `bd` is replaced by a shell script on PATH (test double): `show <id>` prints show_<id>.json,
-- `list --label ...` prints [], anything else prints list.json.

local cli = require("beads.cli")
local store = require("beads.store")

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local FAKE_BD = [[#!/bin/sh
prev=""
for a in "$@"; do
  if [ "$prev" = "show" ]; then
    if [ -f "$FAKE_DIR/show_$a.json" ]; then
      cat "$FAKE_DIR/show_$a.json"
    else
      echo "[]"
    fi
    exit 0
  fi
  if [ "$a" = "--label" ]; then
    echo "[]"
    exit 0
  fi
  prev="$a"
done
cat "$FAKE_DIR/list.json"
]]

local orig_path, bin_dir, fake_dir, orig_columns, orig_lines

local function bead(id, title, extra)
  local b = {
    id = id,
    title = title,
    status = "open",
    priority = 2,
    issue_type = "task",
    updated_at = "2026-11-17T10:00:00Z",
    created_at = "2026-11-17T10:00:00Z",
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

local function long(word, n)
  return (word .. " "):rep(n):sub(1, -2)
end

local function leaves(n, prefix)
  local out = {}
  for i = 1, n do
    out[#out + 1] = bead(("%s-%02d"):format(prefix or "lf", i), "Leaf " .. i)
  end
  return out
end

local function set_list(items)
  vim.fn.writefile({ vim.json.encode(items) }, fake_dir .. "/list.json")
  for _, b in ipairs(items) do
    vim.fn.writefile({ vim.json.encode({ b }) }, fake_dir .. "/show_" .. b.id .. ".json")
  end
end

local function tree_wins()
  local out = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "beads-tree" then
      out[#out + 1] = w
    end
  end
  return out
end

local function tree_win()
  local ws = tree_wins()
  assert.are.equal(1, #ws, "expected exactly one tree window in this tabpage, got " .. #ws)
  return ws[1]
end

local function lines_of(win)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

local function dump(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return "<no tree window>"
  end
  return table.concat(lines_of(win), "\n")
end

local function row_of(win, id)
  for i, l in ipairs(lines_of(win)) do
    local s = l:find(id, 1, true)
    if s and not l:sub(1, s - 1):find("blocked", 1, true) then
      return i
    end
  end
end

-- Rows the user sees: a closed fold counts as its first row only.
local function visible_rows(win)
  return vim.api.nvim_win_call(win, function()
    local out, l, last = {}, 1, vim.fn.line("$")
    while l <= last do
      out[#out + 1] = vim.fn.getline(l)
      local e = vim.fn.foldclosedend(l)
      l = (e > 0 and e or l) + 1
    end
    return out
  end)
end

local function clamp(n, lo, hi)
  return math.max(lo, math.min(hi, n))
end

local function longest(win)
  local m = 0
  for _, l in ipairs(visible_rows(win)) do
    m = math.max(m, vim.fn.strdisplaywidth(l))
  end
  return m
end

local function expected_width(win, max_width)
  return clamp(longest(win), 24, max_width or math.floor(vim.o.columns / 2))
end

local function expected_height(win, max_height)
  return clamp(#visible_rows(win), 6, max_height or math.floor(vim.o.lines * 0.4))
end

local function width(win)
  return vim.api.nvim_win_get_width(win)
end

local function height(win)
  return vim.api.nvim_win_get_height(win)
end

local function wait_rendered(id)
  assert(
    vim.wait(3000, function()
      local ws = tree_wins()
      return #ws == 1 and row_of(ws[1], id) ~= nil and (lines_of(ws[1])[1] or ""):find("^beads ·") ~= nil
    end, 10),
    "tree never rendered " .. id .. ":\n" .. dump(tree_wins()[1])
  )
  return tree_win()
end

local function wait_gone(id)
  assert(vim.wait(3000, function()
    return row_of(tree_win(), id) == nil
  end, 10), id .. " is still shown:\n" .. dump(tree_win()))
end

-- Polls until the tree's size equals what its content asks for; returns that size.
local function assert_fits(dim, opts)
  opts = opts or {}
  local t = tree_win()
  local get = dim == "width" and width or height
  local want
  vim.wait(1000, function()
    want = dim == "width" and expected_width(t, opts.max) or expected_height(t, opts.max)
    return get(t) == want
  end, 10)
  want = dim == "width" and expected_width(t, opts.max) or expected_height(t, opts.max)
  assert.are.equal(
    want,
    get(t),
    ("tree %s does not fit its content (%d columns x %d lines):\n%s"):format(dim, vim.o.columns, vim.o.lines, dump(t))
  )
  return want
end

local function press(keys)
  vim.api.nvim_set_current_win(tree_win())
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

local function refresh(id)
  store.refresh(cli.get_root())
  return wait_rendered(id)
end

local function fire_win_resized(win)
  vim.api.nvim_exec_autocmds("WinResized", { pattern = tostring(win), modeline = false })
end

local function settle()
  vim.wait(150, function()
    return false
  end, 10)
end


local function main_win()
  local t = tree_win()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= t and vim.api.nvim_win_get_config(w).relative == "" then
      return w
    end
  end
end

local function folded(win, id)
  local r = row_of(win, id)
  return r ~= nil and vim.api.nvim_win_call(win, function()
    return vim.fn.foldclosed(r)
  end) == r
end

-- Epic ep-a with 10 children, plus two root leaves: 14 rows open, 4 rows with ep-a folded.
local function epic_items()
  local items = { bead("ep-a", "Epic alpha", { issue_type = "epic", priority = 1 }) }
  for i = 1, 10 do
    items[#items + 1] = child_of(("ch-%02d"):format(i), "ep-a", "Kid " .. i)
  end
  vim.list_extend(items, leaves(2))
  return items
end

-- Opens a bottom tree on the epic fixture and folds ep-a with <Tab> (which already refits).
local function folded_bottom_tree()
  set_list(epic_items())
  vim.cmd("Beads tree bottom")
  local t = wait_rendered("ch-10")
  assert_fits("height")
  vim.api.nvim_win_set_cursor(t, { row_of(t, "ep-a"), 0 })
  press("<Tab>")
  assert(folded(t, "ep-a"), "setup: <Tab> did not fold ep-a:\n" .. dump(t))
  assert.are.equal(6, assert_fits("height"), "setup: the folded tree should be 6 rows tall")
  return t
end

describe("tree auto-fit findings", function()
  before_each(function()
    if vim.fn.exists(":Beads") ~= 2 then
      vim.cmd.source(plugin_root .. "/plugin/beads.lua")
    end
    require("beads").setup({})
    orig_columns, orig_lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 200, 40
    orig_path = vim.env.PATH
    bin_dir = vim.fn.tempname()
    vim.fn.mkdir(bin_dir, "p")
    vim.fn.writefile(vim.split(FAKE_BD, "\n"), bin_dir .. "/bd")
    vim.fn.setfperm(bin_dir .. "/bd", "rwxr-xr-x")
    fake_dir = vim.fn.tempname()
    vim.fn.mkdir(fake_dir, "p")
    vim.env.FAKE_DIR = fake_dir
    vim.env.PATH = bin_dir .. ":" .. orig_path
    local r = vim.fn.tempname()
    vim.fn.mkdir(r, "p")
    cli.set_root(r)
  end)

  after_each(function()
    pcall(vim.cmd, "silent! tabonly!")
    pcall(vim.cmd, "silent! only!")
    pcall(vim.cmd, "enew!")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if b ~= vim.api.nvim_get_current_buf() then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    vim.wait(100, function()
      return false
    end, 10)
    pcall(vim.fn.delete, cli.get_root(), "rf")
    cli.set_root(nil)
    vim.env.PATH = orig_path
    vim.fn.delete(bin_dir, "rf")
    vim.fn.delete(fake_dir, "rf")
    vim.o.columns, vim.o.lines = orig_columns, orig_lines
    require("beads").setup({})
  end)

  describe("every fold change refits", function()
    it("zo on a folded epic with many children grows a small bottom tree", function()
      local t = folded_bottom_tree()
      vim.api.nvim_win_set_cursor(t, { row_of(t, "ep-a"), 0 })
      press("zo")
      assert(not folded(t, "ep-a"), "zo did not open ep-a:\n" .. dump(t))
      assert.are.equal(14, assert_fits("height"))
    end)

    it("zc and za refit a bottom tree", function()
      set_list(epic_items())
      vim.cmd("Beads tree bottom")
      local t = wait_rendered("ch-10")
      assert.are.equal(14, assert_fits("height"))
      vim.api.nvim_win_set_cursor(t, { row_of(t, "ch-05"), 0 })
      press("zc")
      assert(folded(t, "ep-a"), "zc did not fold ep-a:\n" .. dump(t))
      assert.are.equal(6, assert_fits("height"))
      vim.api.nvim_win_set_cursor(t, { row_of(t, "ep-a"), 0 })
      press("za")
      assert(not folded(t, "ep-a"), "za did not open ep-a:\n" .. dump(t))
      assert.are.equal(14, assert_fits("height"))
    end)

    it("zM and zR refit a bottom tree", function()
      set_list(epic_items())
      vim.cmd("Beads tree bottom")
      wait_rendered("ch-10")
      assert.are.equal(14, assert_fits("height"))
      press("zM")
      assert(folded(tree_win(), "ep-a"), "zM did not fold ep-a:\n" .. dump(tree_win()))
      assert.are.equal(6, assert_fits("height"))
      press("zR")
      assert(not folded(tree_win(), "ep-a"), "zR did not open ep-a:\n" .. dump(tree_win()))
      assert.are.equal(14, assert_fits("height"))
    end)

    it("zc and zo refit a left tree's width", function()
      local items = { bead("ep-a", "Epic alpha", { issue_type = "epic", priority = 1 }) }
      items[2] = child_of("ch-w", "ep-a", long("Wide", 16))
      vim.list_extend(items, leaves(2))
      set_list(items)
      vim.cmd("Beads tree left")
      local t = wait_rendered("ch-w")
      local open_w = assert_fits("width")
      vim.api.nvim_win_set_cursor(t, { row_of(t, "ep-a"), 0 })
      press("zc")
      assert(folded(t, "ep-a"), "zc did not fold ep-a:\n" .. dump(t))
      local folded_w = assert_fits("width")
      assert.are_not.equal(open_w, folded_w, "fixture: folding did not change the wanted width")
      press("zo")
      assert.are.equal(open_w, assert_fits("width"))
    end)

    it("the reveal on entering a beads:// buffer refits the tree", function()
      local t = folded_bottom_tree()
      local main = main_win()
      vim.api.nvim_set_current_win(main)
      vim.cmd.edit(vim.fn.fnameescape("beads://ch-07"))
      -- Checked right after BufEnter, before any event-loop turn: a later store refresh re-renders
      -- (and so refits) the tree anyway, which would hide a reveal that does not refit.
      assert(not folded(t, "ep-a"), "entering beads://ch-07 did not reveal it:\n" .. dump(t))
      assert.are.equal(main, vim.api.nvim_get_current_win(), "focus left the detail window")
      assert.are.equal(14, expected_height(t), "fixture: the revealed tree should want 14 rows")
      assert.are.equal(14, height(t), "the reveal did not refit the tree:\n" .. dump(t))
    end)
  end)

  describe("a size the window could not get is not a manual resize", function()
    it("max_width wider than the screen, then a WinResized from another window", function()
      vim.o.columns = 120
      require("beads").setup({ tree = { max_width = 200 } })
      set_list({ bead("lg-a", long("Wide", 30)), unpack(leaves(2)) })
      vim.cmd("Beads tree left")
      local t = wait_rendered("lg-a")
      settle()
      assert.is_true(width(t) < 120 and width(t) < longest(t), "fixture: the tree should be as wide as the screen allows")
      fire_win_resized(main_win())
      set_list({ bead("lg-a", long("Wide", 14)), unpack(leaves(2)) })
      store.refresh(cli.get_root())
      assert(vim.wait(3000, function()
        return vim.fn.strdisplaywidth(lines_of(t)[row_of(t, "lg-a")]) < 100
      end, 10), "the refresh never shortened lg-a:\n" .. dump(t))
      local w = assert_fits("width", { max = 200 })
      assert.is_true(w < 100, "fixture: the shorter content should want less than 100 columns")
    end)

    it("a bottom tree on a screen with few lines, then a WinResized from another window", function()
      vim.o.lines = 8
      set_list(leaves(12))
      vim.cmd("Beads tree bottom")
      local t = wait_rendered("lf-12")
      settle()
      assert.is_true(height(t) < 6, "fixture: 8 lines should not leave room for 6 tree rows, got " .. height(t))
      fire_win_resized(main_win())
      vim.o.lines = 40
      vim.api.nvim_exec_autocmds("VimResized", { modeline = false })
      assert.are.equal(13, assert_fits("height"))
    end)
  end)
end)
