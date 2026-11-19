-- Bead beads_nvim-4u9.11, review finding (blocker) on lua/beads/views/tree.lua:532:
-- with the tree focused, its buffer-local <LeftMouse> map must not swallow clicks outside the
-- tree's text: a click in another window moves focus (and the cursor) there, like Vim's default.
-- Clicks are simulated as in tree_mouse_spec: nvim_input_mouse sets the mouse position (consumed
-- with getchar(0)), then <LeftMouse> is fed as typed.
-- `bd` is a shell script on PATH (test double).

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

local function settle()
  vim.wait(200, function()
    return false
  end, 10)
end

-- A window in the tab that is neither the tree nor a float.
local function other_win(tree)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= tree and vim.api.nvim_win_get_config(w).relative == "" then
      return w
    end
  end
end

describe(":Beads tree mouse (findings 4u9.11)", function()
  before_each(function()
    if vim.fn.exists(":Beads") ~= 2 then
      vim.cmd.source(plugin_root .. "/plugin/beads.lua")
    end
    require("beads").setup({ tree = { layout = "split" } })
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
    require("beads").setup({ tree = { layout = "split" } })
  end)

  -- finding lua/beads/views/tree.lua:532: the tree's <LeftMouse> map swallows clicks outside the tree.
  it("with the tree focused, <LeftMouse> in another window moves focus there", function()
    local tree = open_tree()
    local other = other_win(tree)
    assert.is_not_nil(other, "no other window next to the tree")
    local obuf = vim.api.nvim_win_get_buf(other)
    vim.api.nvim_buf_set_lines(obuf, 0, -1, false, { "one", "two", "three", "four" })
    vim.api.nvim_win_set_cursor(other, { 1, 0 })
    vim.api.nvim_set_current_win(tree)
    vim.cmd("redraw!")
    local info = vim.fn.getwininfo(other)[1]
    -- third text line, third column of the other window (0-based screen coords for nvim_input_mouse)
    local srow = info.winrow - 1 + 2
    local scol = info.wincol - 1 + info.textoff + 2
    vim.api.nvim_input_mouse("left", "press", "", 0, srow, scol)
    vim.fn.getchar(0)
    vim.api.nvim_feedkeys(vim.keycode("<LeftMouse>"), "xt", false)
    settle()
    assert.equals(other, vim.api.nvim_get_current_win(), "click in another window left focus in the tree")
    assert.equals(3, vim.api.nvim_win_get_cursor(other)[1], "click did not place the cursor in the other window")
  end)
end)
