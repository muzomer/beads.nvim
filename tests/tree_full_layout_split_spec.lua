-- Bead beads_nvim-i7f: guards for today's split behaviour (passes already).
-- Interface under test: setup({ tree = { layout = "split" } }) with a plain :Beads tree, and
-- :Beads tree left|bottom with the default layout: the tree opens as a side/bottom split next to the
-- current window, and <CR> opens the bead in that previous window (window count unchanged).
-- The helpers are copied from tests/tree_full_layout_spec.lua (some are unused here).
-- `bd` is a shell script on PATH (test double): `show <id>` prints a bead with that id, anything
-- else prints list.json.

local cli = require("beads.cli")
local store = require("beads.store")

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local FAKE_BD = [[#!/bin/sh
prev=""
for a in "$@"; do
  if [ "$prev" = "show" ]; then
    printf '[{"id":"%s","title":"Shown %s","status":"open","priority":2,"issue_type":"task","created_at":"2026-11-17T10:00:00Z","updated_at":"2026-11-17T10:00:00Z"}]\n' "$a" "$a"
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

-- ep-a > { ch-b, ep-s > { gc-x } }, root leaf bl-d.
local function items()
  return {
    bead("ep-a", "Epic alpha", { issue_type = "epic", priority = 1 }),
    child_of("ch-b", "ep-a", "Child bravo"),
    child_of("ep-s", "ep-a", "Sub epic", { issue_type = "epic" }),
    child_of("gc-x", "ep-s", "Grandchild xray"),
    bead("bl-d", "Leaf delta"),
  }
end

local function set_list(list)
  vim.fn.writefile({ vim.json.encode(list) }, fake_dir .. "/list.json")
  local done = false
  store.refresh(cli.get_root(), function()
    done = true
  end)
  assert(vim.wait(3000, function()
    return done
  end, 10), "store refresh never completed")
end

local function lines_of(win)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

local function dump(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return "<no window>"
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

-- Non-floating windows of the current tabpage.
local function normal_wins()
  local out = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(w).relative == "" then
      out[#out + 1] = w
    end
  end
  return out
end

local function floats()
  local out = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      out[#out + 1] = w
    end
  end
  return out
end

local function tree_win()
  for _, w in ipairs(normal_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "beads-tree" then
      return w
    end
  end
end

local function detail_win(id)
  for _, w in ipairs(normal_wins()) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)) == "beads://" .. id then
      return w
    end
  end
end

local function any_detail()
  for _, w in ipairs(normal_wins()) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
    if name:find("^beads://") then
      return name
    end
  end
end

local function layout_desc()
  local parts = {}
  for _, w in ipairs(normal_wins()) do
    local p = vim.api.nvim_win_get_position(w)
    parts[#parts + 1] = ("win %d buf %q ft %s row %d col %d %dx%d"):format(
      w,
      vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)),
      vim.bo[vim.api.nvim_win_get_buf(w)].filetype,
      p[1],
      p[2],
      vim.api.nvim_win_get_width(w),
      vim.api.nvim_win_get_height(w)
    )
  end
  return table.concat(parts, "\n")
end

local function settle()
  vim.wait(200, function()
    return false
  end, 10)
end

-- Toggles the tree on and waits until it rendered `wait_id`; returns the tree window.
local function open_tree(wait_id)
  wait_id = wait_id or "bl-d"
  vim.cmd("Beads tree")
  local tree
  assert(vim.wait(3000, function()
    tree = tree_win()
    return tree ~= nil
      and row_of(tree, wait_id) ~= nil
      and (lines_of(tree)[1] or ""):find("^beads ·") ~= nil
  end, 10), ":Beads tree never rendered " .. wait_id .. ":\n" .. layout_desc())
  vim.api.nvim_win_call(tree, function()
    vim.cmd("silent! normal! zR")
  end)
  return tree
end

local function press(win, keys)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

local function on_bead(tree, id)
  local r = row_of(tree, id)
  assert(r, id .. " not in the tree:\n" .. dump(tree))
  vim.api.nvim_set_current_win(tree)
  vim.api.nvim_win_set_cursor(tree, { r, 0 })
  return r
end

-- Waits for beads://<id> in a normal window, loaded in VIEW mode (so its q map exists).
local function wait_detail(id)
  local w
  assert(vim.wait(3000, function()
    w = detail_win(id)
    return w ~= nil and vim.b[vim.api.nvim_win_get_buf(w)].beads_mode == "view"
  end, 10), "beads://" .. id .. " never opened / loaded:\n" .. layout_desc())
  return w
end

-- Asserts the split view: detail above, tree below, both full width; the cursor in the detail.
local function assert_split_view(id)
  local d = wait_detail(id)
  local t = tree_win()
  local desc = layout_desc()
  assert.is_not_nil(t, "the tree window is gone:\n" .. desc)
  assert.are.equal(2, #normal_wins(), "expected exactly detail + tree windows:\n" .. desc)
  assert.is_true(
    vim.api.nvim_win_get_position(d)[1] < vim.api.nvim_win_get_position(t)[1],
    "the detail is not above the tree:\n" .. desc
  )
  assert.are.equal(vim.o.columns, vim.api.nvim_win_get_width(d), "detail is not full width:\n" .. desc)
  assert.are.equal(vim.o.columns, vim.api.nvim_win_get_width(t), "tree is not full width:\n" .. desc)
  assert.are.equal(d, vim.api.nvim_get_current_win(), "the cursor did not go to the detail:\n" .. desc)
  return d, t
end

-- Asserts the tree-only view in a window of height `h` with the cursor on bead `id`.
local function assert_tree_only(h, id)
  local desc = layout_desc()
  assert.are.equal(1, #normal_wins(), "not back to a single window:\n" .. desc)
  local t = tree_win()
  assert.is_not_nil(t, "the remaining window is not the tree:\n" .. desc)
  assert.are.equal(vim.o.columns, vim.api.nvim_win_get_width(t), "tree is not full width:\n" .. desc)
  assert.are.equal(h, vim.api.nvim_win_get_height(t), "tree is not full height:\n" .. desc)
  assert.is_nil(any_detail(), "a detail window is still shown:\n" .. desc)
  if id then
    local line = lines_of(t)[vim.api.nvim_win_get_cursor(t)[1]] or ""
    assert.is_truthy(line:find(id, 1, true), "tree cursor is not on " .. id .. ", but on: " .. line)
  end
  return t
end

-- Feeds mouse `key` at byte `byte_idx` (1-based) of buffer line `row` in the focused window.
local function click(win, row, byte_idx, key)
  vim.api.nvim_set_current_win(win)
  vim.cmd("redraw!")
  local line = vim.fn.getbufline(vim.api.nvim_win_get_buf(win), row)[1] or ""
  local sp = vim.fn.screenpos(win, row, 1)
  assert(sp.row > 0, "row " .. row .. " is not on screen:\n" .. dump(win))
  local info = vim.fn.getwininfo(win)[1]
  local col = info.wincol + info.textoff + vim.fn.strdisplaywidth(line:sub(1, byte_idx - 1))
  vim.api.nvim_input_mouse("left", "press", "", 0, sp.row - 1, col - 1)
  vim.fn.getchar(0)
  vim.api.nvim_feedkeys(vim.keycode(key or "<LeftMouse>"), "xt", false)
end

local function at(win, row, s)
  local i = (lines_of(win)[row] or ""):find(s, 1, true)
  assert(i, ("'%s' not on row %d:\n%s"):format(s, row, dump(win)))
  return i
end

local function leaves(n)
  local out = {}
  for i = 1, n do
    out[#out + 1] = bead(("lf-%02d"):format(i), "Leaf number " .. i)
  end
  return out
end

describe("tree.layout = 'split' and :Beads tree <pos>", function()
  local tmpfile

  before_each(function()
    if vim.fn.exists(":Beads") ~= 2 then
      vim.cmd.source(plugin_root .. "/plugin/beads.lua")
    end
    require("beads").setup({})
    orig_columns, orig_lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 200, 50
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
    set_list(items())
    tmpfile = vim.fn.tempname() .. ".txt"
    vim.fn.writefile({ "previous buffer line" }, tmpfile)
  end)

  after_each(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    pcall(vim.cmd, "silent! tabonly!")
    pcall(vim.cmd, "silent! only!")
    pcall(vim.cmd, "enew!")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if b ~= vim.api.nvim_get_current_buf() then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    settle()
    pcall(vim.fn.delete, cli.get_root(), "rf")
    cli.set_root(nil)
    vim.env.PATH = orig_path
    vim.fn.delete(bin_dir, "rf")
    vim.fn.delete(fake_dir, "rf")
    pcall(vim.fn.delete, tmpfile)
    vim.o.columns, vim.o.lines = orig_columns, orig_lines
    require("beads").setup({})
  end)


  -- passes already: tree.layout = "split" keeps the side split and <CR> in the other window.
  it("tree.layout = 'split': plain toggle opens a left split, <CR> opens in the other window", function()
    require("beads").setup({ tree = { layout = "split" } })
    local w0 = vim.api.nvim_get_current_win()
    local tree = open_tree()
    local desc = layout_desc()
    assert.are.equal(2, #normal_wins(), "split layout did not open a side window:\n" .. desc)
    assert.are_not.equal(w0, tree, "split layout replaced the current window:\n" .. desc)
    assert.are.equal(0, vim.api.nvim_win_get_position(tree)[2], "tree is not at the left edge:\n" .. desc)
    assert.is_true(vim.api.nvim_win_get_width(tree) < vim.o.columns, "tree fills the width:\n" .. desc)
    on_bead(tree, "ch-b")
    press(tree, "<CR>")
    assert(vim.wait(3000, function()
      return detail_win("ch-b") ~= nil
    end, 10), "<CR> did not open beads://ch-b:\n" .. layout_desc())
    desc = layout_desc()
    assert.are.equal(2, #normal_wins(), "<CR> changed the window count:\n" .. desc)
    assert.are.equal(w0, detail_win("ch-b"), "<CR> did not open the bead in the previous window:\n" .. desc)
    assert.are.equal(tree, tree_win(), "the tree window changed:\n" .. desc)
  end)

  -- passes already: :Beads tree <pos> is an explicit split, also with the default layout.
  for _, case in ipairs({ { "left", 1 }, { "bottom", 2 } }) do
    it(":Beads tree " .. case[1] .. " opens a split and <CR> opens in the other window", function()
      local w0 = vim.api.nvim_get_current_win()
      vim.cmd("Beads tree " .. case[1])
      local tree
      assert(vim.wait(3000, function()
        tree = tree_win()
        return tree ~= nil and row_of(tree, "bl-d") ~= nil
      end, 10), "tree never rendered:\n" .. layout_desc())
      local desc = layout_desc()
      assert.are.equal(2, #normal_wins(), ":Beads tree " .. case[1] .. " did not split:\n" .. desc)
      local p = vim.api.nvim_win_get_position(tree)
      if case[1] == "left" then
        assert.are.equal(0, p[2], "tree is not at the left edge:\n" .. desc)
      else
        assert.is_true(p[1] > vim.api.nvim_win_get_position(w0)[1], "tree is not below:\n" .. desc)
      end
      on_bead(tree, "bl-d")
      press(tree, "<CR>")
      assert(vim.wait(3000, function()
        return detail_win("bl-d") ~= nil
      end, 10), "<CR> did not open beads://bl-d:\n" .. layout_desc())
      assert.are.equal(2, #normal_wins(), "<CR> changed the window count:\n" .. layout_desc())
      assert.are.equal(w0, detail_win("bl-d"), "<CR> did not use the previous window:\n" .. layout_desc())
      vim.cmd("Beads tree")
      assert.is_nil(tree_win(), "plain :Beads tree did not close the split tree")
    end)
  end
end)
