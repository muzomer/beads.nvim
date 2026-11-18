-- Bead beads_nvim-4u9.4: tree folding by structure, fold text, <Tab>, persistence.
-- Interface under test: lua/beads/views/tree.lua via :Beads tree.
--   * Folds follow the parent-child structure (not indent): folding a bead hides exactly
--     its rendered descendants; beads without visible children start no fold.
--   * Fold text: "▸ <line> (<n> children, <m> open)".
--   * keymaps.tree_view.fold (default "<Tab>") toggles the fold under the cursor; false disables it.
--     za/zc/zo/zR/zM keep working.
--   * Fold state (by bead id) and the cursor bead survive store refreshes and H toggles.
-- Fold state is per window: queried with nvim_win_call on the tree window.
-- `bd` is replaced by a shell script on PATH (test double): `show` prints show.json,
-- anything else prints list.json.

local cli = require("beads.cli")
local store = require("beads.store")

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
  local e = vim.tbl_extend("force", {}, extra or {})
  e.parent = parent
  e.dependencies = { { issue_id = id, depends_on_id = parent, type = "parent-child" } }
  return bead(id, title, e)
end

-- ep-a > { ch-b, ep-s > { gc-x, gc-y } }, ep-t > { tc-1, tc-2, tc-3 (closed) }, root leaf bl-d.
local function base_items()
  return {
    bead("ep-a", "Epic alpha", { issue_type = "epic", priority = 1 }),
    child_of("ch-b", "ep-a", "Child bravo"),
    child_of("ep-s", "ep-a", "Sub epic", { issue_type = "epic" }),
    child_of("gc-x", "ep-s", "Grandchild xray"),
    child_of("gc-y", "ep-s", "Grandchild yankee"),
    bead("ep-t", "Epic tango", { issue_type = "epic", priority = 3 }),
    child_of("tc-1", "ep-t", "Tango one"),
    child_of("tc-2", "ep-t", "Tango two"),
    child_of("tc-3", "ep-t", "Tango three", { status = "closed" }),
    bead("bl-d", "Leaf delta"),
  }
end

local ALL = { "ep-a", "ch-b", "ep-s", "gc-x", "gc-y", "ep-t", "tc-1", "tc-2", "bl-d" }

local function set_list(items)
  vim.fn.writefile({ vim.json.encode(items) }, fake_dir .. "/list.json")
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

-- Row (1-based) of the line that is bead `id`.
local function row_of(win, id)
  for i, l in ipairs(lines_of(win)) do
    local s = l:find(id, 1, true)
    if s and not l:sub(1, s - 1):find("blocked", 1, true) then
      return i
    end
  end
  return nil
end

local function wait_for(win, id)
  return vim.wait(3000, function()
    return vim.api.nvim_win_is_valid(win) and row_of(win, id) ~= nil
  end, 10)
end

local function dump(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return "<no tree window>"
  end
  return table.concat(lines_of(win), "\n")
end

local function wcall(win, fn)
  return vim.api.nvim_win_call(win, fn)
end

local function fclosed(win, row)
  return wcall(win, function()
    return vim.fn.foldclosed(row)
  end)
end

local function flevel(win, row)
  return wcall(win, function()
    return vim.fn.foldlevel(row)
  end)
end

-- Runs normal-mode `cmd` (no mappings) with the cursor on bead `id`.
local function normal_on(win, id, cmd)
  local row = row_of(win, id)
  assert(row, id .. " not rendered:\n" .. dump(win))
  wcall(win, function()
    vim.api.nvim_win_set_cursor(win, { row, 0 })
    vim.cmd("silent! normal! " .. cmd)
  end)
  return row
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

local function ready_tree()
  local tree = open_tree()
  assert.is_not_nil(tree, ":Beads tree opened no window")
  assert(wait_for(tree, "gc-y") and wait_for(tree, "bl-d"), "tree never rendered:\n" .. dump(tree))
  -- wait for the header (the load after open), so rows do not shift under the test
  assert(vim.wait(3000, function()
    return (lines_of(tree)[1] or ""):find("^beads ·") ~= nil
  end, 10), "tree header never rendered:\n" .. dump(tree))
  wcall(tree, function()
    vim.cmd("silent! normal! zR")
  end)
  return tree
end

local function buf_map(buf, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if vim.keycode(m.lhs) == vim.keycode(lhs) then
      return m
    end
  end
  return nil
end

describe(":Beads tree folding", function()
  before_each(function()
    if vim.fn.exists(":Beads") ~= 2 then
      vim.cmd.source(plugin_root .. "/plugin/beads.lua")
    end
    require("beads").setup({})
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
    vim.fn.writefile({ vim.json.encode({ bead("bl-d", "Leaf delta") }) }, fake_dir .. "/show.json")
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
    require("beads").setup({})
  end)

  it("folding a sub-epic hides exactly its descendants", function()
    local tree = ready_tree()
    local rs = normal_on(tree, "ep-s", "zc")
    local out = dump(tree)
    local inside = { ["ep-s"] = true, ["gc-x"] = true, ["gc-y"] = true }
    for _, id in ipairs(ALL) do
      local r = row_of(tree, id)
      if inside[id] then
        assert.are.equal(rs, fclosed(tree, r), id .. " is not in ep-s's closed fold:\n" .. out)
      else
        assert.are.equal(-1, fclosed(tree, r), id .. " was folded with ep-s:\n" .. out)
      end
    end
  end)

  it("folding a top epic hides its children and grandchildren, nothing else", function()
    local tree = ready_tree()
    local ra = normal_on(tree, "ep-a", "zc")
    local out = dump(tree)
    local inside = { ["ep-a"] = true, ["ch-b"] = true, ["ep-s"] = true, ["gc-x"] = true, ["gc-y"] = true }
    for _, id in ipairs(ALL) do
      local r = row_of(tree, id)
      if inside[id] then
        assert.are.equal(ra, fclosed(tree, r), id .. " is not in ep-a's closed fold:\n" .. out)
      else
        assert.are.equal(-1, fclosed(tree, r), id .. " was folded with ep-a:\n" .. out)
      end
    end
  end)

  it("fold text shows ▸, the bead line and '(<n> children, <m> open)'", function()
    local tree = ready_tree()
    press(tree, "H") -- show the closed child so every reading of the counts agrees
    assert(wait_for(tree, "tc-3"), "H did not show the closed child:\n" .. dump(tree))
    local rt = normal_on(tree, "ep-t", "zc")
    assert.are.equal(rt, fclosed(tree, rt), "ep-t did not fold:\n" .. dump(tree))
    local txt = wcall(tree, function()
      return vim.fn.foldtextresult(rt)
    end)
    assert.is_truthy(txt:find("▸", 1, true), "fold text lacks ▸: " .. txt)
    assert.is_truthy(txt:find("ep-t", 1, true), "fold text lacks the bead id: " .. txt)
    assert.is_truthy(txt:find("Epic tango", 1, true), "fold text lacks the title: " .. txt)
    assert.is_truthy(txt:find("(3 children, 2 open)", 1, true), "fold text lacks the counts: " .. txt)
  end)

  it("<Tab> toggles the fold under the cursor", function()
    local tree = ready_tree()
    local ra = row_of(tree, "ep-a")
    vim.api.nvim_set_current_win(tree)
    vim.api.nvim_win_set_cursor(tree, { ra, 0 })
    press(tree, "<Tab>")
    assert.are.equal(ra, fclosed(tree, ra), "<Tab> did not close ep-a's fold:\n" .. dump(tree))
    press(tree, "<Tab>")
    assert.are.equal(-1, fclosed(tree, ra), "second <Tab> did not open ep-a's fold")
  end)

  it("keymaps.tree_view.fold remaps the toggle", function()
    require("beads").setup({ keymaps = { tree_view = { fold = "<F7>" } } })
    local tree = ready_tree()
    local buf = vim.api.nvim_win_get_buf(tree)
    assert.is_not_nil(buf_map(buf, "<F7>"), "<F7> not mapped in the tree")
    assert.is_nil(buf_map(buf, "<Tab>"), "default <Tab> still mapped after remap")
    local ra = row_of(tree, "ep-a")
    vim.api.nvim_set_current_win(tree)
    vim.api.nvim_win_set_cursor(tree, { ra, 0 })
    press(tree, "<F7>")
    assert.are.equal(ra, fclosed(tree, ra), "<F7> did not close ep-a's fold:\n" .. dump(tree))
    press(tree, "<F7>")
    assert.are.equal(-1, fclosed(tree, ra), "second <F7> did not open ep-a's fold")
  end)

  it("keymaps.tree_view.fold = false disables the toggle", function()
    require("beads").setup({ keymaps = { tree_view = { fold = false } } })
    local tree = ready_tree()
    local buf = vim.api.nvim_win_get_buf(tree)
    assert.is_nil(buf_map(buf, "<Tab>"), "<Tab> mapped with fold = false")
    assert.is_not_nil(buf_map(buf, "R"), "other tree keys were lost")
  end)

  it("zM closes and zR opens the structure folds; za toggles", function()
    local tree = ready_tree()
    wcall(tree, function()
      vim.cmd("silent! normal! zM")
    end)
    local ra, rt, rd = row_of(tree, "ep-a"), row_of(tree, "ep-t"), row_of(tree, "bl-d")
    assert.are.equal(ra, fclosed(tree, ra), "zM did not fold ep-a:\n" .. dump(tree))
    assert.are.equal(rt, fclosed(tree, rt), "zM did not fold ep-t:\n" .. dump(tree))
    assert.are.equal(-1, fclosed(tree, rd), "zM folded the leaf bl-d")
    wcall(tree, function()
      vim.cmd("silent! normal! zR")
    end)
    assert.are.equal(-1, fclosed(tree, ra), "zR did not open ep-a")
    normal_on(tree, "ep-t", "za")
    assert.are.equal(rt, fclosed(tree, rt), "za did not close ep-t")
    normal_on(tree, "ep-t", "za")
    assert.are.equal(-1, fclosed(tree, rt), "za did not reopen ep-t")
  end)

  it("beads with no children start no fold", function()
    local tree = ready_tree()
    local out = dump(tree)
    assert.are.equal(0, flevel(tree, row_of(tree, "bl-d")), "root leaf bl-d has a fold:\n" .. out)
    assert.are.equal(
      flevel(tree, row_of(tree, "ep-a")),
      flevel(tree, row_of(tree, "ch-b")),
      "leaf ch-b opens a fold level of its own:\n" .. out
    )
    assert.are.equal(
      flevel(tree, row_of(tree, "ep-s")),
      flevel(tree, row_of(tree, "gc-x")),
      "leaf gc-x opens a fold level of its own:\n" .. out
    )
    local rd = normal_on(tree, "bl-d", "zc")
    assert.are.equal(-1, fclosed(tree, rd), "zc on the root leaf bl-d closed a fold")
  end)

  it("a refresh that adds beads elsewhere keeps folds and the cursor bead", function()
    local tree = ready_tree()
    local ra_old = normal_on(tree, "ep-a", "zc")
    assert.are.equal(ra_old, fclosed(tree, ra_old), "ep-a did not fold:\n" .. dump(tree))
    local rd_old = row_of(tree, "bl-d")
    vim.api.nvim_win_set_cursor(tree, { rd_old, 0 })
    local items = { bead("aa-new", "New root", { priority = 0 }) }
    vim.list_extend(items, base_items())
    set_list(items)
    store.refresh(cli.get_root())
    assert(wait_for(tree, "aa-new"), "tree did not re-render on refresh:\n" .. dump(tree))
    local ra, rt, rd = row_of(tree, "ep-a"), row_of(tree, "ep-t"), row_of(tree, "bl-d")
    assert.are_not.equal(ra_old, ra, "setup: ep-a row did not move:\n" .. dump(tree))
    assert.are.equal(ra, fclosed(tree, ra), "ep-a lost its fold after refresh:\n" .. dump(tree))
    assert.are.equal(-1, fclosed(tree, rt), "ep-t got folded by the refresh:\n" .. dump(tree))
    assert.are.equal(rd, vim.api.nvim_win_get_cursor(tree)[1], "cursor left bl-d:\n" .. dump(tree))
  end)

  it("a refresh keeps the cursor on a folded epic and the fold closed", function()
    local tree = ready_tree()
    local ra_old = normal_on(tree, "ep-a", "zc")
    assert.are.equal(ra_old, fclosed(tree, ra_old), "ep-a did not fold:\n" .. dump(tree))
    local items = { bead("aa-new", "New root", { priority = 0 }) }
    vim.list_extend(items, base_items())
    set_list(items)
    store.refresh(cli.get_root())
    assert(wait_for(tree, "aa-new"), "tree did not re-render on refresh:\n" .. dump(tree))
    local ra = row_of(tree, "ep-a")
    assert.are_not.equal(ra_old, ra, "setup: ep-a row did not move:\n" .. dump(tree))
    assert.are.equal(ra, fclosed(tree, ra), "ep-a lost its fold after refresh:\n" .. dump(tree))
    assert.are.equal(ra, vim.api.nvim_win_get_cursor(tree)[1], "cursor left ep-a:\n" .. dump(tree))
  end)

  it("folds survive H toggles", function()
    local tree = ready_tree()
    local rs = normal_on(tree, "ep-s", "zc")
    assert.are.equal(rs, fclosed(tree, rs), "ep-s did not fold:\n" .. dump(tree))
    vim.api.nvim_win_set_cursor(tree, { row_of(tree, "bl-d"), 0 })
    press(tree, "H")
    assert(wait_for(tree, "tc-3"), "H did not show closed beads:\n" .. dump(tree))
    rs = row_of(tree, "ep-s")
    assert.are.equal(rs, fclosed(tree, rs), "ep-s lost its fold after H:\n" .. dump(tree))
    press(tree, "H")
    rs = row_of(tree, "ep-s")
    assert.are.equal(rs, fclosed(tree, rs), "ep-s lost its fold after H H:\n" .. dump(tree))
    assert.are.equal(row_of(tree, "bl-d"), vim.api.nvim_win_get_cursor(tree)[1], "cursor left bl-d after H H")
  end)
end)
