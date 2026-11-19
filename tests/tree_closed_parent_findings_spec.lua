-- Findings test (bead beads_nvim-ge7.12, blocker lua/beads/views/tree.lua:43):
-- an open bead whose parent is closed must still appear in :Beads tree while
-- closed beads are hidden (H off). Only closed beads are hidden.
-- `bd` is a shell script on PATH (test double): prints $FAKE_DIR/list.json.

local cli = require("beads.cli")
local store = require("beads.store")

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local FAKE_BD = [[#!/bin/sh
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
  local e = vim.tbl_extend("force", {}, extra or {})
  e.parent = parent
  e.dependencies = { { issue_id = id, depends_on_id = parent, type = "parent-child" } }
  return bead(id, title, e)
end

local function items()
  return {
    -- closed epic with an open child
    bead("ep-x", "Closed epic", { issue_type = "epic", status = "closed", priority = 1 }),
    child_of("oc-y", "ep-x", "Open child of closed epic"),
    -- open epic > closed child > open grandchild
    bead("ep-p", "Open epic", { issue_type = "epic", priority = 1 }),
    child_of("cc-q", "ep-p", "Closed middle", { status = "closed" }),
    child_of("gc-r", "cc-q", "Open grandchild"),
  }
end

local function wins()
  return vim.api.nvim_tabpage_list_wins(0)
end

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

local function item_pos(win, id)
  for i, l in ipairs(lines_of(win)) do
    local s = l:find(id, 1, true)
    if s and not l:sub(1, s - 1):find("blocked", 1, true) then
      return i, vim.fn.strdisplaywidth(l:sub(1, s - 1)), l
    end
  end
  return nil
end

local function dump(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return "<no tree window>"
  end
  return table.concat(lines_of(win), "\n")
end

local function wait_for(win, id)
  return vim.wait(3000, function()
    return vim.api.nvim_win_is_valid(win) and item_pos(win, id) ~= nil
  end, 10)
end

local function press(win, keys)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

describe(":Beads tree with closed parents", function()
  before_each(function()
    if vim.fn.exists(":Beads") ~= 2 then
      vim.cmd.source(plugin_root .. "/plugin/beads.lua")
    end
    require("beads").setup({ tree = { layout = "split" } })
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
    vim.fn.writefile({ vim.json.encode(items()) }, fake_dir .. "/list.json")
    local done = false
    store.refresh(cli.get_root(), function()
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

  it("shows open descendants of closed beads while closed beads are hidden", function()
    local tree = open_tree()
    assert.is_not_nil(tree, ":Beads tree opened no window")
    assert(wait_for(tree, "ep-p"), "tree never rendered:\n" .. dump(tree))
    local out = dump(tree)
    assert.is_nil(item_pos(tree, "ep-x"), "closed epic shown with H off:\n" .. out)
    assert.is_nil(item_pos(tree, "cc-q"), "closed middle bead shown with H off:\n" .. out)
    assert.is_not_nil(item_pos(tree, "oc-y"), "open child of a closed epic is hidden:\n" .. out)
    assert.is_not_nil(item_pos(tree, "gc-r"), "open grandchild under a closed bead is hidden:\n" .. out)
  end)

  it("with H on, nests open children under their closed parents", function()
    local tree = open_tree()
    assert.is_not_nil(tree, ":Beads tree opened no window")
    assert(wait_for(tree, "ep-p"), "tree never rendered:\n" .. dump(tree))
    press(tree, "H")
    assert(wait_for(tree, "ep-x"), "H did not show closed beads:\n" .. dump(tree))
    local out = dump(tree)
    local rx, cx = item_pos(tree, "ep-x")
    local ry, cy = item_pos(tree, "oc-y")
    local rq, cq = item_pos(tree, "cc-q")
    local rr, cr = item_pos(tree, "gc-r")
    assert.is_not_nil(ry, out)
    assert.is_not_nil(rq, out)
    assert.is_not_nil(rr, out)
    assert.is_true(ry > rx and cy > cx, "oc-y not nested under ep-x:\n" .. out)
    assert.is_true(rr > rq and cr > cq, "gc-r not nested under cc-q:\n" .. out)
    -- each open bead is rendered exactly once
    for _, id in ipairs({ "oc-y", "gc-r" }) do
      local n = 0
      for _, l in ipairs(lines_of(tree)) do
        if l:find(id, 1, true) then
          n = n + 1
        end
      end
      assert.are.equal(1, n, id .. " rendered more than once:\n" .. out)
    end
  end)
end)
