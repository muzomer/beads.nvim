-- Findings for bead beads_nvim-4u9.13 (tree auto-fit), reviewer blocker:
--   tree.lua:590 - the buffer-local z-fold refit maps are set after keys.bind and overwrite any
--   tree_view action the user mapped to zc/zo/za/zA/zC/zO/zM/zR. A z key the user mapped to a tree
--   action must keep that action; z keys not mapped by the user keep the native fold + refit.
-- Interface: setup({ keymaps = { tree_view = { <action> = "<z key>" } } }), :Beads tree bottom,
-- keys pressed in the tree with feedkeys (remap allowed so the plugin's buffer-local maps run).
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

local function expected_height(win, max_height)
  return clamp(#visible_rows(win), 6, max_height or math.floor(vim.o.lines * 0.4))
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

-- Polls until the tree's height equals what its content asks for; returns that height.
local function assert_fits_height()
  local t = tree_win()
  vim.wait(1000, function()
    return height(t) == expected_height(t)
  end, 10)
  local want = expected_height(t)
  assert.are.equal(want, height(t), ("tree height does not fit its content (%d lines):\n%s"):format(vim.o.lines, dump(t)))
  return want
end

local function press(keys)
  vim.api.nvim_set_current_win(tree_win())
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

local function settle()
  vim.wait(150, function()
    return false
  end, 10)
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

describe("tree z keys the user mapped to tree actions", function()
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

  it("keymaps.tree_view.fold = 'zc' toggles: a second zc opens the fold again", function()
    require("beads").setup({ keymaps = { tree_view = { fold = "zc" } } })
    set_list(epic_items())
    vim.cmd("Beads tree bottom")
    local t = wait_rendered("ch-10")
    vim.api.nvim_win_set_cursor(t, { row_of(t, "ep-a"), 0 })
    press("zc")
    assert(folded(t, "ep-a"), "first zc did not fold ep-a:\n" .. dump(t))
    vim.api.nvim_win_set_cursor(t, { row_of(t, "ep-a"), 0 })
    press("zc")
    assert(not folded(t, "ep-a"), "zc is mapped to the fold toggle, but a second zc left ep-a folded:\n" .. dump(t))
    assert.are.equal(14, assert_fits_height())
  end)

  it("keymaps.tree_view.fold = 'zc': the zc map is the tree's fold action", function()
    require("beads").setup({ keymaps = { tree_view = { fold = "zc" } } })
    set_list(epic_items())
    vim.cmd("Beads tree bottom")
    local t = wait_rendered("ch-10")
    local km = vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(t), function()
      return vim.fn.maparg("zc", "n", false, true)
    end)
    assert.are.equal(1, km.buffer, "zc is not a buffer-local map in the tree")
    assert.is_truthy((km.desc or ""):lower():find("toggle fold", 1, true), "zc desc is not the fold action: " .. tostring(km.desc))
  end)

  it("keymaps.tree_view.refresh = 'zR' refreshes the tree", function()
    require("beads").setup({ keymaps = { tree_view = { refresh = "zR" } } })
    set_list(epic_items())
    vim.cmd("Beads tree bottom")
    vim.api.nvim_set_current_win(wait_rendered("ch-10"))
    settle()
    local items = epic_items()
    items[#items + 1] = bead("nw-1", "Brand new bead")
    set_list(items)
    settle()
    assert.is_nil(row_of(tree_win(), "nw-1"), "setup: nw-1 shows up without a refresh:\n" .. dump(tree_win()))
    press("zR")
    assert(vim.wait(2000, function()
      return row_of(tree_win(), "nw-1") ~= nil
    end, 10), "zR is mapped to refresh, but the tree never showed nw-1:\n" .. dump(tree_win()))
  end)

  it("keymaps.tree_view.refresh = 'zR' keeps zM as a native fold with refit", function()
    require("beads").setup({ keymaps = { tree_view = { refresh = "zR" } } })
    set_list(epic_items())
    vim.cmd("Beads tree bottom")
    wait_rendered("ch-10")
    assert.are.equal(14, assert_fits_height())
    press("zM")
    assert(folded(tree_win(), "ep-a"), "zM did not fold ep-a:\n" .. dump(tree_win()))
    assert.are.equal(6, assert_fits_height())
  end)
end)
