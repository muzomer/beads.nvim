-- Bead beads_nvim-4u9.11: mouse support in the tree.
-- Interface under test: setup({ mouse = true|false }) (default true) and :Beads tree.
--   * mouse = true: normal maps for <LeftMouse> and <2-LeftMouse> are active in the tree buffer
--     (buffer-local or global).
--     <LeftMouse> on a bead line selects it (cursor on that row, nothing opens); <LeftMouse> on the
--     title opens the bead (like <CR>: beads://<id> in the previous window); <2-LeftMouse> anywhere
--     on a bead line opens it; <LeftMouse> on the fold marker ▾/▸ toggles that bead's fold.
--   * mouse = false: no mouse maps, neither buffer-local in the tree nor global with a "Beads" desc.
-- Clicks are simulated with the tree window focused: nvim_input_mouse sets the mouse position
-- (consumed with getchar(0)), then the mouse key is fed as typed.
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

local function fclosed(win, row)
  return vim.api.nvim_win_call(win, function()
    return vim.fn.foldclosed(row)
  end)
end

local function open_tree()
  local before = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    before[w] = true
  end
  vim.cmd("Beads tree")
  local tree
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if not before[w] then
      tree = w
    end
  end
  assert.is_not_nil(tree, ":Beads tree opened no window")
  assert(vim.wait(3000, function()
    return vim.api.nvim_win_is_valid(tree)
      and row_of(tree, "gc-x") ~= nil
      and row_of(tree, "bl-d") ~= nil
      and (lines_of(tree)[1] or ""):find("^beads ·") ~= nil
  end, 10), "tree never rendered:\n" .. dump(tree))
  vim.api.nvim_win_call(tree, function()
    vim.cmd("silent! normal! zR")
  end)
  return tree
end

-- Feeds mouse `key` at byte `byte_idx` (1-based) of buffer line `row` in the focused tree window.
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

-- Byte index of the plain text `s` in tree line `row`.
local function at(win, row, s)
  local i = (lines_of(win)[row] or ""):find(s, 1, true)
  assert(i, ("'%s' not on row %d:\n%s"):format(s, row, dump(win)))
  return i
end

-- Byte index of the fold marker (▾ or ▸) on row `row`.
local function marker(win, row)
  local l = lines_of(win)[row] or ""
  local i = l:find("▾", 1, true) or l:find("▸", 1, true)
  assert(i, ("no fold marker on row %d:\n%s"):format(row, dump(win)))
  return i
end

local function detail_win(id)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)) == "beads://" .. id then
      return w
    end
  end
end

local function any_detail()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find("^beads://") then
      return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
    end
  end
end

local function wait_detail(id)
  return vim.wait(3000, function()
    return detail_win(id) ~= nil
  end, 10)
end

local function settle()
  vim.wait(200, function()
    return false
  end, 10)
end

local function mouse_maps(buf)
  local out = {}
  for _, mode in ipairs({ "n", "v", "x", "i" }) do
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
      if m.lhs:lower():find("mouse", 1, true) or m.lhs:lower():find("release", 1, true) then
        out[#out + 1] = mode .. " " .. m.lhs
      end
    end
  end
  return out
end

-- Global normal maps on mouse keys whose desc starts with "Beads".
local function global_mouse_maps()
  local out = {}
  for _, mode in ipairs({ "n", "v", "x", "i" }) do
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
      local l = m.lhs:lower()
      if (l:find("mouse", 1, true) or l:find("release", 1, true)) and (m.desc or ""):find("^Beads") then
        out[#out + 1] = mode .. " " .. m.lhs
      end
    end
  end
  return out
end

local function global_map(lhs)
  local want = vim.fn.keytrans(vim.keycode(lhs))
  for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
    if vim.fn.keytrans(vim.keycode(m.lhs)) == want then
      return m
    end
  end
end

local function buf_map(buf, lhs)
  local want = vim.fn.keytrans(vim.keycode(lhs))
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if vim.fn.keytrans(vim.keycode(m.lhs)) == want then
      return m
    end
  end
end

describe(":Beads tree mouse", function()
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
    vim.fn.writefile({ vim.json.encode(items()) }, fake_dir .. "/list.json")
    local done = false
    store.refresh(r, function()
      done = true
    end)
    assert(vim.wait(3000, function()
      return done
    end, 10), "store refresh never completed")
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
    settle()
    pcall(vim.fn.delete, cli.get_root(), "rf")
    cli.set_root(nil)
    vim.env.PATH = orig_path
    vim.fn.delete(bin_dir, "rf")
    vim.fn.delete(fake_dir, "rf")
    vim.o.columns, vim.o.lines = orig_columns, orig_lines
    require("beads").setup({})
  end)

  it("mouse defaults to on: <LeftMouse> and <2-LeftMouse> are mapped in the tree", function()
    local tree = open_tree()
    local buf = vim.api.nvim_win_get_buf(tree)
    for _, k in ipairs({ "<LeftMouse>", "<2-LeftMouse>" }) do
      assert.is_not_nil(buf_map(buf, k) or global_map(k), "no " .. k .. " map active in the tree")
    end
  end)

  it("<LeftMouse> on a bead's id selects it and opens nothing", function()
    local tree = open_tree()
    local rb = row_of(tree, "bl-d")
    vim.api.nvim_win_set_cursor(tree, { 1, 0 })
    click(tree, rb, at(tree, rb, "bl-d"))
    settle()
    assert.equals(tree, vim.api.nvim_get_current_win(), "the click moved focus out of the tree")
    assert.equals(rb, vim.api.nvim_win_get_cursor(tree)[1], "click did not select bl-d:\n" .. dump(tree))
    assert.is_nil(any_detail(), "a click on the id opened a bead")
  end)

  it("<LeftMouse> on the title opens the bead", function()
    local tree = open_tree()
    local rb = row_of(tree, "ch-b")
    click(tree, rb, at(tree, rb, "Child bravo") + 2)
    assert(wait_detail("ch-b"), "click on the title did not open beads://ch-b:\n" .. dump(tree))
  end)

  it("<2-LeftMouse> on a bead's id opens the bead", function()
    local tree = open_tree()
    local rb = row_of(tree, "bl-d")
    local col = at(tree, rb, "bl-d")
    click(tree, rb, col, "<LeftMouse>")
    click(tree, rb, col, "<2-LeftMouse>")
    assert(wait_detail("bl-d"), "double-click did not open beads://bl-d:\n" .. dump(tree))
  end)

  it("<LeftMouse> on ▾/▸ toggles the fold of a top-level epic and opens nothing", function()
    local tree = open_tree()
    local ra = row_of(tree, "ep-a")
    click(tree, ra, marker(tree, ra))
    assert.equals(ra, fclosed(tree, ra), "click on ▾ did not fold ep-a:\n" .. dump(tree))
    click(tree, ra, marker(tree, ra))
    assert.equals(-1, fclosed(tree, ra), "click on ▸ did not unfold ep-a:\n" .. dump(tree))
    settle()
    assert.is_nil(any_detail(), "a click on the fold marker opened a bead")
  end)

  it("<LeftMouse> on the ▾ of a nested epic toggles only that fold", function()
    local tree = open_tree()
    local rs, ra = row_of(tree, "ep-s"), row_of(tree, "ep-a")
    click(tree, rs, marker(tree, rs))
    assert.equals(rs, fclosed(tree, rs), "click on ▾ did not fold ep-s:\n" .. dump(tree))
    assert.equals(-1, fclosed(tree, ra), "click on ep-s's ▾ folded ep-a:\n" .. dump(tree))
    click(tree, rs, marker(tree, rs))
    assert.equals(-1, fclosed(tree, rs), "second click did not unfold ep-s:\n" .. dump(tree))
  end)

  it("mouse = false installs no mouse maps in the tree (passes already)", function()
    require("beads").setup({ mouse = false })
    local tree = open_tree()
    local buf = vim.api.nvim_win_get_buf(tree)
    local got = mouse_maps(buf)
    assert.are.same({}, got, "mouse maps with mouse = false: " .. vim.inspect(got))
    local glob = global_mouse_maps()
    assert.are.same({}, glob, "global Beads mouse maps with mouse = false: " .. vim.inspect(glob))
    assert.is_not_nil(buf_map(buf, "R"), "other tree keys were lost")
  end)

  it("mouse = false: a click on the title only moves the cursor (passes already)", function()
    require("beads").setup({ mouse = false })
    local tree = open_tree()
    local rb = row_of(tree, "ch-b")
    click(tree, rb, at(tree, rb, "Child bravo") + 2)
    settle()
    assert.equals(rb, vim.api.nvim_win_get_cursor(tree)[1], "click did not move the cursor:\n" .. dump(tree))
    assert.is_nil(any_detail(), "a click with mouse = false opened a bead")
  end)
end)
