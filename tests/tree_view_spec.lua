-- Interface under test (bead beads_nvim-ge7.12): lua/beads/views/tree.lua via :Beads tree
--   :Beads tree toggles a left vsplit tree (width from require("beads").config.tree.width,
--   default since beads_nvim-4u9.5: a quarter of the screen clamped 24..42, so 42 at 200 columns), one per tabpage. The tree reads require("beads.store") for cli.get_root()
--   and re-renders on store notifications.
--   Lines: indent by parent-child depth, id, priority, status, title, workflow badges,
--   "⛔ blocked by X" markers for open blockers. Closed beads hidden until H.
--   Keys (buffer-local in the tree): <CR> opens beads://<id> in the previous window, H toggles closed.
--
-- The tree window is found as "the window that appeared after :Beads tree"; no tree API is assumed.
-- `bd` is replaced by a shell script on PATH (test double for the external binary):
--   `show <id>` prints $FAKE_DIR/show.json, anything else prints $FAKE_DIR/list.json.

local cli = require("beads.cli")
local store = require("beads.store")
local model = require("beads.model")
local workflow = require("beads.workflow")

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local FAKE_BD = [[#!/bin/sh
for a in "$@"; do
  if [ "$a" = "show" ]; then
    cat "$FAKE_DIR/show.json"
    exit 0
  fi
done
cat "$FAKE_DIR/list.json"
]]

local orig_path, bin_dir, fake_dir, orig_columns

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
  local deps = { { issue_id = id, depends_on_id = parent, type = "parent-child" } }
  for _, d in ipairs((extra or {}).deps or {}) do
    deps[#deps + 1] = d
  end
  local e = vim.tbl_extend("force", {}, extra or {})
  e.deps = nil
  e.parent = parent
  e.dependencies = deps
  return bead(id, title, e)
end

local BADGE_ITEM = bead("bg-f", "Badged bead", { metadata = { verdict = "CLEAN" }, labels = { "human" } })

local function base_items()
  return {
    bead("ep-a", "Epic alpha", { issue_type = "epic", priority = 1 }),
    child_of("ch-b", "ep-a", "Child bravo", {
      deps = { { issue_id = "ch-b", depends_on_id = "bl-d", type = "blocks" } },
    }),
    child_of("ch-c", "ep-a", "Child charlie"),
    bead("bl-d", "Blocker delta"),
    bead("cl-e", "Closed echo", { status = "closed" }),
    BADGE_ITEM,
  }
end

local function set_list(items)
  vim.fn.writefile({ vim.json.encode(items) }, fake_dir .. "/list.json")
end

local function set_show(item)
  vim.fn.writefile({ vim.json.encode({ item }) }, fake_dir .. "/show.json")
end

local function wins()
  return vim.api.nvim_tabpage_list_wins(0)
end

-- Runs :Beads tree and returns the window that appeared (nil if none).
local function open_tree()
  local before = {}
  for _, w in ipairs(wins()) do
    before[w] = true
  end
  vim.cmd("Beads tree")
  for _, w in ipairs(wins()) do
    if not before[w] then
      return w
    end
  end
  return nil
end

local function lines_of(win)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

-- Row (1-based) and display column of the line that *is* bead id (not a "blocked by" marker).
local function item_pos(win, id)
  for i, l in ipairs(lines_of(win)) do
    local s = l:find(id, 1, true)
    if s and not l:sub(1, s - 1):find("blocked", 1, true) then
      return i, vim.fn.strdisplaywidth(l:sub(1, s - 1)), l
    end
  end
  return nil
end

local function wait_for(win, id, present)
  if present == nil then
    present = true
  end
  return vim.wait(3000, function()
    return vim.api.nvim_win_is_valid(win) and ((item_pos(win, id) ~= nil) == present)
  end, 10)
end

local function dump(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return "<no tree window>"
  end
  return table.concat(lines_of(win), "\n")
end

local function press(win, keys)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

local function prefill()
  local done = false
  store.refresh(cli.get_root(), function()
    done = true
  end)
  assert(vim.wait(3000, function()
    return done
  end, 10), "store refresh never completed")
end

describe(":Beads tree", function()
  before_each(function()
    if vim.fn.exists(":Beads") ~= 2 then
      vim.cmd.source(plugin_root .. "/plugin/beads.lua")
    end
    orig_columns = vim.o.columns
    vim.o.columns = 200
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
    set_list(base_items())
    set_show(bead("ch-c", "Child charlie", { parent = "ep-a" }))
    prefill()
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
    vim.o.columns = orig_columns
  end)

  it("toggles one left tree window of width 42 (200 columns): second :Beads tree closes it", function()
    local n = #wins()
    local tree = open_tree()
    assert.is_not_nil(tree, ":Beads tree opened no window")
    assert.are.equal(n + 1, #wins())
    assert.are.equal(1, vim.fn.win_screenpos(tree)[2], "tree window is not at the left edge")
    assert.are.equal(42, vim.api.nvim_win_get_width(tree))
    assert(wait_for(tree, "ep-a"), "tree never rendered:\n" .. dump(tree))
    vim.cmd("Beads tree")
    assert.is_false(vim.api.nvim_win_is_valid(tree), "second :Beads tree did not close the tree window")
    assert.are.equal(n, #wins())
  end)

  it("gives a second tabpage its own tree, independent of the first", function()
    local tree1 = open_tree()
    assert.is_not_nil(tree1, ":Beads tree opened no window in tab 1")
    local tab1 = vim.api.nvim_get_current_tabpage()
    vim.cmd("tabnew")
    local tab2 = vim.api.nvim_get_current_tabpage()
    local tree2 = open_tree()
    assert.is_not_nil(tree2, ":Beads tree opened no window in tab 2")
    assert.are.equal(tab2, vim.api.nvim_win_get_tabpage(tree2))
    assert.are_not.equal(tree1, tree2)
    assert.is_true(vim.api.nvim_win_is_valid(tree1), "opening tab 2's tree closed tab 1's")
    assert.are.equal(tab1, vim.api.nvim_win_get_tabpage(tree1))
    assert(wait_for(tree2, "ep-a"), "tab 2 tree never rendered:\n" .. dump(tree2))
    -- toggling in tab 2 leaves tab 1's tree alone
    vim.cmd("Beads tree")
    assert.is_false(vim.api.nvim_win_is_valid(tree2), "second :Beads tree in tab 2 did not close its tree")
    assert.is_true(vim.api.nvim_win_is_valid(tree1), "toggling tab 2's tree closed tab 1's")
  end)

  it("renders children indented under their epic and blockers as markers, not nesting", function()
    local tree = open_tree()
    assert.is_not_nil(tree, ":Beads tree opened no window")
    assert(wait_for(tree, "ch-c"), "tree never rendered children:\n" .. dump(tree))
    local out = dump(tree)
    local re, ce = item_pos(tree, "ep-a")
    local rb, cb, lb = item_pos(tree, "ch-b")
    local rc, cc = item_pos(tree, "ch-c")
    local rd, cd = item_pos(tree, "bl-d")
    assert.is_not_nil(re, out)
    assert.is_not_nil(rb, out)
    assert.is_not_nil(rc, out)
    assert.is_not_nil(rd, out)
    assert.is_true(cb > ce, "ch-b not indented under ep-a:\n" .. out)
    assert.is_true(cc > ce, "ch-c not indented under ep-a:\n" .. out)
    assert.is_true(rb > re and rc > re, "children not below their epic:\n" .. out)
    -- children sit directly in the epic's block (no other root between epic and children)
    assert.is_true(not (rd > re and rd < math.max(rb, rc)), "blocker bl-d rendered inside the epic block:\n" .. out)
    assert.are.equal(ce, cd, "blocker bl-d is not at root level:\n" .. out)
    assert.is_truthy(lb:find("blocked by bl-d", 1, true), "ch-b line lacks 'blocked by bl-d': " .. lb)
    assert.is_truthy(lb:find("⛔", 1, true), "ch-b line lacks the ⛔ marker: " .. lb)
    -- bl-d appears once as an item, never nested as a child of ch-b
    local items = 0
    for _, l in ipairs(lines_of(tree)) do
      local s = l:find("bl-d", 1, true)
      if s and not l:sub(1, s - 1):find("blocked", 1, true) then
        items = items + 1
      end
    end
    assert.are.equal(1, items, "bl-d should be rendered as exactly one item line:\n" .. out)
  end)

  it("hides closed beads until H, and H again hides them", function()
    local tree = open_tree()
    assert.is_not_nil(tree, ":Beads tree opened no window")
    assert(wait_for(tree, "ep-a"), "tree never rendered:\n" .. dump(tree))
    assert.is_nil(item_pos(tree, "cl-e"), "closed bead shown by default:\n" .. dump(tree))
    press(tree, "H")
    assert(wait_for(tree, "cl-e", true), "H did not show the closed bead:\n" .. dump(tree))
    press(tree, "H")
    assert(wait_for(tree, "cl-e", false), "second H did not hide the closed bead:\n" .. dump(tree))
    assert.is_not_nil(item_pos(tree, "ep-a"), "open beads disappeared after H H:\n" .. dump(tree))
  end)

  it("keeps the cursor on the same bead id after a store refresh", function()
    local tree = open_tree()
    assert.is_not_nil(tree, ":Beads tree opened no window")
    assert(wait_for(tree, "ch-c"), "tree never rendered:\n" .. dump(tree))
    local row = item_pos(tree, "ch-c")
    vim.api.nvim_win_set_cursor(tree, { row, 0 })
    -- new beads that sort before ch-c by id, priority and input order, so its row shifts
    local items = {
      bead("aa-new", "New root", { priority = 0 }),
      child_of("ab-kid", "ep-a", "New child", { priority = 0 }),
    }
    vim.list_extend(items, base_items())
    set_list(items)
    store.refresh(cli.get_root())
    assert(wait_for(tree, "aa-new") and wait_for(tree, "ab-kid"), "tree did not re-render on refresh:\n" .. dump(tree))
    local new_row = item_pos(tree, "ch-c")
    assert.are_not.equal(row, new_row, "test setup: ch-c row did not move:\n" .. dump(tree))
    local cur = vim.api.nvim_win_get_cursor(tree)[1]
    local line = lines_of(tree)[cur]
    assert.are.equal(new_row, cur, "cursor left ch-c; now on: " .. tostring(line) .. "\n" .. dump(tree))
  end)

  it("<CR> opens beads://<id> in the previous window, not the tree window", function()
    vim.cmd("enew")
    vim.cmd("split")
    local other = vim.api.nvim_get_current_win()
    vim.cmd("wincmd j")
    local main = vim.api.nvim_get_current_win()
    local other_buf = vim.api.nvim_win_get_buf(other)
    local tree = open_tree()
    assert.is_not_nil(tree, ":Beads tree opened no window")
    assert(wait_for(tree, "ch-c"), "tree never rendered:\n" .. dump(tree))
    local tree_buf = vim.api.nvim_win_get_buf(tree)
    vim.api.nvim_set_current_win(main)
    vim.api.nvim_set_current_win(tree)
    vim.api.nvim_win_set_cursor(tree, { (item_pos(tree, "ch-c")), 0 })
    press(tree, "<CR>")
    assert(vim.wait(3000, function()
      return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(main)) == "beads://ch-c"
    end, 10), "previous window shows " .. vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(main)))
    assert.is_true(vim.api.nvim_win_is_valid(tree))
    assert.are.equal(tree_buf, vim.api.nvim_win_get_buf(tree), "tree window no longer shows the tree")
    assert.are.equal(other_buf, vim.api.nvim_win_get_buf(other), "a non-previous window was changed")
  end)

  it("shows workflow badges on bead lines", function()
    local tree = open_tree()
    assert.is_not_nil(tree, ":Beads tree opened no window")
    assert(wait_for(tree, "bg-f"), "tree never rendered:\n" .. dump(tree))
    local _, _, line = item_pos(tree, "bg-f")
    local badges = workflow.badges(model.normalize(BADGE_ITEM))
    assert.is_true(#badges >= 2, "test setup: expected badges for verdict CLEAN and label human")
    for _, g in ipairs(badges) do
      assert.is_truthy(line:find(g, 1, true), "badge " .. g .. " missing from: " .. line)
    end
  end)
end)
