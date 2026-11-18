-- Bead beads_nvim-4u9.7: tree filter (f) and sort (s).
-- Interface under test: lua/beads/views/tree.lua via :Beads tree.
--   * keymaps.tree_view.filter (default "f") prompts with vim.ui.input. Free text matches the
--     id or title; tokens status:<s>, label:<l>, assignee:<a>, type:<t> narrow further (all
--     must match). Empty input clears the filter. Ancestors of matching beads stay visible;
--     ancestors that do not match themselves are dimmed (BeadsDim over the bead text).
--   * keymaps.tree_view.sort (default "s") cycles priority -> updated -> id -> priority.
--     "updated" puts the most recently updated bead first; "id" is ascending by id.
--     Order among siblings follows the sort.
--   * The header (line 1, still starting "beads · <root> · ...") shows the active filter text
--     verbatim and "sort: <name>" for the current sort.
--   * Filter and sort survive store refreshes.
-- `bd` is replaced by a shell script on PATH (test double): `show` prints show.json,
-- anything else prints list.json. vim.ui.input is replaced by a stub that answers at once.

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

local orig_path, bin_dir, fake_dir, orig_columns, orig_input
local input_answer, input_calls

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

-- Filter fixture. With "status:open label:ui":
--   ep-a (no ui)      > ch-b (open, ui) MATCH; ch-c (open, no ui) hidden; ch-d (in_progress, ui) hidden
--   ep-t (open, ui)   MATCH > tc-1 (open, no ui) hidden
--   bl-d (open, ui)   MATCH
--   bl-e (open, no ui) hidden
--   ep-g (no ui) > ep-h (no ui) > gc-z (open, ui) MATCH
local function filter_items()
  return {
    bead("ep-a", "Epic alpha", { issue_type = "epic", priority = 1 }),
    child_of("ch-b", "ep-a", "Child bravo", { labels = { "ui" } }),
    child_of("ch-c", "ep-a", "Child charlie"),
    child_of("ch-d", "ep-a", "Child dingo", { status = "in_progress", labels = { "ui" } }),
    bead("ep-t", "Epic tango", { issue_type = "epic", priority = 3, labels = { "ui" } }),
    child_of("tc-1", "ep-t", "Tango one", { assignee = "zed" }),
    bead("bl-d", "Leaf delta", { labels = { "ui" }, assignee = "kim" }),
    bead("bl-e", "Leaf echo", { issue_type = "bug" }),
    bead("ep-g", "Epic golf", { issue_type = "epic" }),
    child_of("ep-h", "ep-g", "Epic hotel", { issue_type = "epic" }),
    child_of("gc-z", "ep-h", "Grandchild zulu", { labels = { "ui" } }),
  }
end

local ALL = { "ep-a", "ch-b", "ch-c", "ch-d", "ep-t", "tc-1", "bl-d", "bl-e", "ep-g", "ep-h", "gc-z" }

-- Sort fixture: siblings under ep-q whose three orders all differ.
--   priority: sb-c (P0), sb-b (P1), sb-a (P2)
--   updated (newest first): sb-b (11-17), sb-a (11-10), sb-c (11-01)
--   id: sb-a, sb-b, sb-c
local function sort_items()
  return {
    bead("ep-q", "Epic quebec", { issue_type = "epic", priority = 1 }),
    child_of("sb-a", "ep-q", "Sib one", { priority = 2, updated_at = "2026-11-10T10:00:00Z" }),
    child_of("sb-b", "ep-q", "Sib two", { priority = 1, updated_at = "2026-11-17T10:00:00Z" }),
    child_of("sb-c", "ep-q", "Sib three", { priority = 0, updated_at = "2026-11-01T10:00:00Z" }),
  }
end

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

local function header(win)
  return lines_of(win)[1] or ""
end

-- Row (1-based) of bead `id`; skips the header (it echoes the filter text).
local function row_of(win, id)
  for i, l in ipairs(lines_of(win)) do
    if i > 1 and not l:find("^beads ·") then
      local s = l:find(id, 1, true)
      if s and not l:sub(1, s - 1):find("blocked", 1, true) then
        return i
      end
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

local function wait_until(fn)
  return vim.wait(3000, fn, 10)
end

local function wait_for(win, id)
  return wait_until(function()
    return vim.api.nvim_win_is_valid(win) and row_of(win, id) ~= nil
  end)
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
  assert(wait_until(function()
    return done
  end), "store refresh never completed")
end

local function ready_tree(last_id)
  local tree = open_tree()
  assert.is_not_nil(tree, ":Beads tree opened no window")
  assert(wait_for(tree, last_id), "tree never rendered:\n" .. dump(tree))
  assert(wait_until(function()
    return header(tree):find("^beads ·") ~= nil
  end), "tree header never rendered:\n" .. dump(tree))
  return tree
end

-- Presses the filter key with `text` as the prompt answer.
local function filter(tree, text, key)
  input_answer = text
  local before = input_calls
  press(tree, key or "f")
  assert.are.equal(before + 1, input_calls, "the filter key did not prompt via vim.ui.input:\n" .. dump(tree))
end

local function visible_set(tree)
  local set = {}
  for _, id in ipairs(ALL) do
    if row_of(tree, id) then
      set[id] = true
    end
  end
  return set
end

local function assert_visible_exactly(tree, want, what)
  local got = visible_set(tree)
  for _, id in ipairs(ALL) do
    assert.are.equal(want[id] == true, got[id] == true, ("%s: %s %s:\n%s"):format(
      what,
      id,
      want[id] and "should be visible" or "should be hidden",
      dump(tree)
    ))
  end
end

-- True when a BeadsDim extmark (any namespace) covers the first byte of `text` on `row`.
local function dimmed(tree, row, text)
  local buf = vim.api.nvim_win_get_buf(tree)
  local line = lines_of(tree)[row]
  local col = assert(line:find(text, 1, true), text .. " not on row " .. row) - 1
  local marks = vim.api.nvim_buf_get_extmarks(buf, -1, { row - 1, 0 }, { row - 1, -1 }, { details = true })
  for _, m in ipairs(marks) do
    local d = m[4]
    if d.hl_group == "BeadsDim" and m[3] <= col and (d.end_col or 0) > col then
      return true
    end
  end
  return false
end

local function order(tree, ids)
  local rows = {}
  for _, id in ipairs(ids) do
    rows[#rows + 1] = { id = id, row = assert(row_of(tree, id), id .. " not rendered:\n" .. dump(tree)) }
  end
  table.sort(rows, function(a, b)
    return a.row < b.row
  end)
  return table.concat(
    vim.tbl_map(function(r)
      return r.id
    end, rows),
    " "
  )
end

local SIBS = { "sb-a", "sb-b", "sb-c" }

local function buf_map(buf, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if vim.keycode(m.lhs) == vim.keycode(lhs) then
      return m
    end
  end
  return nil
end

describe(":Beads tree filter and sort", function()
  before_each(function()
    if vim.fn.exists(":Beads") ~= 2 then
      vim.cmd.source(plugin_root .. "/plugin/beads.lua")
    end
    require("beads").setup({})
    orig_columns = vim.o.columns
    vim.o.columns = 200
    orig_input = vim.ui.input
    input_calls = 0
    input_answer = nil
    vim.ui.input = function(_, on_confirm)
      input_calls = input_calls + 1
      on_confirm(input_answer)
    end
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
    set_list(filter_items())
    vim.fn.writefile({ vim.json.encode({ bead("bl-d", "Leaf delta") }) }, fake_dir .. "/show.json")
    prefill()
  end)

  after_each(function()
    vim.ui.input = orig_input
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

  describe("filter", function()
    it("'status:open label:ui' shows only matching beads plus their ancestors", function()
      local tree = ready_tree("gc-z")
      filter(tree, "status:open label:ui")
      assert(wait_until(function()
        return row_of(tree, "bl-e") == nil
      end), "filter did not hide the non-matching root bl-e:\n" .. dump(tree))
      assert_visible_exactly(tree, {
        ["ep-a"] = true,
        ["ch-b"] = true,
        ["ep-t"] = true,
        ["bl-d"] = true,
        ["ep-g"] = true,
        ["ep-h"] = true,
        ["gc-z"] = true,
      }, "status:open label:ui")
    end)

    it("the header shows the active filter and keeps its prefix", function()
      local tree = ready_tree("gc-z")
      filter(tree, "status:open label:ui")
      assert(wait_until(function()
        return header(tree):find("status:open label:ui", 1, true) ~= nil
      end), "header does not show the filter:\n" .. dump(tree))
      assert.is_truthy(header(tree):find("^beads ·"), "header lost its 'beads ·' prefix:\n" .. dump(tree))
    end)

    it("ancestors that do not match are dimmed, matches are not", function()
      local tree = ready_tree("gc-z")
      filter(tree, "status:open label:ui")
      assert(wait_until(function()
        return row_of(tree, "bl-e") == nil
      end), "filter not applied:\n" .. dump(tree))
      assert.is_true(dimmed(tree, row_of(tree, "ep-a"), "Epic alpha"), "ancestor ep-a not dimmed:\n" .. dump(tree))
      assert.is_true(dimmed(tree, row_of(tree, "ep-g"), "Epic golf"), "ancestor ep-g not dimmed:\n" .. dump(tree))
      assert.is_true(dimmed(tree, row_of(tree, "ep-h"), "Epic hotel"), "ancestor ep-h not dimmed:\n" .. dump(tree))
      assert.is_false(dimmed(tree, row_of(tree, "ch-b"), "Child bravo"), "match ch-b is dimmed:\n" .. dump(tree))
      assert.is_false(dimmed(tree, row_of(tree, "bl-d"), "Leaf delta"), "match bl-d is dimmed:\n" .. dump(tree))
      assert.is_false(dimmed(tree, row_of(tree, "gc-z"), "Grandchild zulu"), "match gc-z is dimmed:\n" .. dump(tree))
    end)

    it("empty filter input restores the full tree and clears the header", function()
      local tree = ready_tree("gc-z")
      filter(tree, "status:open label:ui")
      assert(wait_until(function()
        return row_of(tree, "bl-e") == nil
      end), "filter not applied:\n" .. dump(tree))
      filter(tree, "")
      assert(wait_until(function()
        return row_of(tree, "bl-e") ~= nil
      end), "empty filter did not restore bl-e:\n" .. dump(tree))
      local want = {}
      for _, id in ipairs(ALL) do
        want[id] = true
      end
      assert_visible_exactly(tree, want, "after clearing")
      assert.is_nil(header(tree):find("label:ui", 1, true), "header still shows the cleared filter:\n" .. dump(tree))
    end)

    it("free text matches the title", function()
      local tree = ready_tree("gc-z")
      filter(tree, "Leaf")
      assert(wait_until(function()
        return row_of(tree, "ep-a") == nil
      end), "free-text filter not applied:\n" .. dump(tree))
      assert_visible_exactly(tree, { ["bl-d"] = true, ["bl-e"] = true }, "free text 'Leaf'")
    end)

    it("free text matches the id; ancestors stay visible", function()
      local tree = ready_tree("gc-z")
      filter(tree, "gc-z")
      assert(wait_until(function()
        return row_of(tree, "bl-d") == nil
      end), "id filter not applied:\n" .. dump(tree))
      assert_visible_exactly(tree, { ["ep-g"] = true, ["ep-h"] = true, ["gc-z"] = true }, "free text 'gc-z'")
    end)

    it("assignee: and type: tokens narrow the tree", function()
      local tree = ready_tree("gc-z")
      filter(tree, "assignee:kim")
      assert(wait_until(function()
        return row_of(tree, "ep-a") == nil
      end), "assignee filter not applied:\n" .. dump(tree))
      assert_visible_exactly(tree, { ["bl-d"] = true }, "assignee:kim")
      filter(tree, "type:bug")
      assert(wait_until(function()
        return row_of(tree, "bl-e") ~= nil and row_of(tree, "bl-d") == nil
      end), "type filter not applied:\n" .. dump(tree))
      assert_visible_exactly(tree, { ["bl-e"] = true }, "type:bug")
    end)

    it("free text combines with tokens", function()
      local tree = ready_tree("gc-z")
      filter(tree, "label:ui Child")
      assert(wait_until(function()
        return row_of(tree, "bl-d") == nil
      end), "combined filter not applied:\n" .. dump(tree))
      assert_visible_exactly(tree, { ["ep-a"] = true, ["ch-b"] = true, ["ch-d"] = true }, "label:ui Child")
    end)

    it("the filter survives a store refresh", function()
      local tree = ready_tree("gc-z")
      filter(tree, "status:open label:ui")
      assert(wait_until(function()
        return row_of(tree, "bl-e") == nil
      end), "filter not applied:\n" .. dump(tree))
      local items = filter_items()
      items[#items + 1] = bead("nw-m", "New match", { labels = { "ui" } })
      items[#items + 1] = bead("nw-x", "New other")
      set_list(items)
      store.refresh(cli.get_root())
      assert(wait_for(tree, "nw-m"), "tree did not re-render with the new match:\n" .. dump(tree))
      assert.is_nil(row_of(tree, "nw-x"), "refresh dropped the filter (nw-x shown):\n" .. dump(tree))
      assert.is_nil(row_of(tree, "bl-e"), "refresh dropped the filter (bl-e shown):\n" .. dump(tree))
      assert.is_truthy(header(tree):find("status:open label:ui", 1, true), "header lost the filter:\n" .. dump(tree))
    end)

    it("keymaps.tree_view.filter remaps the key", function()
      require("beads").setup({ keymaps = { tree_view = { filter = "<F8>" } } })
      local tree = ready_tree("gc-z")
      local buf = vim.api.nvim_win_get_buf(tree)
      assert.is_not_nil(buf_map(buf, "<F8>"), "<F8> not mapped in the tree")
      assert.is_nil(buf_map(buf, "f"), "default f still mapped after remap")
      filter(tree, "label:ui", "<F8>")
      assert(wait_until(function()
        return row_of(tree, "bl-e") == nil
      end), "<F8> filter not applied:\n" .. dump(tree))
    end)
  end)

  describe("sort", function()
    before_each(function()
      set_list(sort_items())
      prefill()
    end)

    it("defaults to priority order among siblings", function()
      local tree = ready_tree("sb-c")
      assert.are.equal("sb-c sb-b sb-a", order(tree, SIBS), "default order is not by priority:\n" .. dump(tree))
    end)

    it("'s' cycles priority -> updated -> id -> priority; header and sibling order follow", function()
      local tree = ready_tree("sb-c")
      press(tree, "s")
      assert(wait_until(function()
        return header(tree):find("sort:%s*updated") ~= nil
      end), "header does not name the 'updated' sort after one s:\n" .. dump(tree))
      assert.are.equal("sb-b sb-a sb-c", order(tree, SIBS), "siblings not newest-updated first:\n" .. dump(tree))
      press(tree, "s")
      assert(wait_until(function()
        return header(tree):find("sort:%s*id%f[%W]") ~= nil
      end), "header does not name the 'id' sort after two s:\n" .. dump(tree))
      assert.are.equal("sb-a sb-b sb-c", order(tree, SIBS), "siblings not in id order:\n" .. dump(tree))
      press(tree, "s")
      assert(wait_until(function()
        return header(tree):find("sort:%s*priority") ~= nil
      end), "header does not name the 'priority' sort after three s:\n" .. dump(tree))
      assert.are.equal("sb-c sb-b sb-a", order(tree, SIBS), "siblings not back in priority order:\n" .. dump(tree))
      assert.is_truthy(header(tree):find("^beads ·"), "header lost its 'beads ·' prefix:\n" .. dump(tree))
    end)

    it("the sort survives a store refresh", function()
      local tree = ready_tree("sb-c")
      press(tree, "s")
      assert(wait_until(function()
        return header(tree):find("sort:%s*updated") ~= nil
      end), "header does not name the 'updated' sort:\n" .. dump(tree))
      local items = sort_items()
      items[#items + 1] = child_of("sb-d", "ep-q", "Sib four", { priority = 4, updated_at = "2026-11-18T10:00:00Z" })
      set_list(items)
      store.refresh(cli.get_root())
      assert(wait_for(tree, "sb-d"), "tree did not re-render on refresh:\n" .. dump(tree))
      assert.are.equal(
        "sb-d sb-b sb-a sb-c",
        order(tree, { "sb-a", "sb-b", "sb-c", "sb-d" }),
        "refresh dropped the updated sort:\n" .. dump(tree)
      )
      assert.is_truthy(header(tree):find("sort:%s*updated"), "header lost the sort after refresh:\n" .. dump(tree))
    end)

    it("keymaps.tree_view.sort remaps the key", function()
      require("beads").setup({ keymaps = { tree_view = { sort = "<F9>" } } })
      local tree = ready_tree("sb-c")
      local buf = vim.api.nvim_win_get_buf(tree)
      assert.is_not_nil(buf_map(buf, "<F9>"), "<F9> not mapped in the tree")
      assert.is_nil(buf_map(buf, "s"), "default s still mapped after remap")
      press(tree, "<F9>")
      assert(wait_until(function()
        return order(tree, SIBS) == "sb-b sb-a sb-c"
      end), "<F9> did not switch to the updated sort:\n" .. dump(tree))
    end)
  end)
end)
