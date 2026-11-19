-- Bead beads_nvim-4u9.5: tree layout left / right / bottom / top.
-- Interface under test: lua/beads/views/tree.lua via :Beads tree [left|right|bottom|top]
-- and the tree key keymaps.tree_view.layout (default "L").
--   * config: tree = { position = "left"|"right"|"bottom"|"top", width = nil, height = nil }.
--     Default width (left/right) since beads_nvim-4u9.13: "auto", the longest visible line clamped
--     24..floor(columns / 2). Default height (bottom/top): "auto", the visible line count clamped
--     6..floor(lines * 0.4). Expected auto sizes are computed from the rendered tree.
--     Explicit width / height are used as given.
--   * :Beads tree <pos> opens the tree at <pos>, or moves an open tree there (it does not toggle
--     it closed). Plain :Beads tree still toggles, opening at the last used position.
--   * Moving keeps the tree buffer (same buffer id), its folds and its cursor bead, keeps exactly one
--     tree per tabpage and does not change the watcher acquisition (never released mid-move).
--   * L cycles left -> bottom -> right -> top -> left.
-- The tree window is found fresh each time as "the window of this tabpage showing a beads-tree
-- buffer": moving may keep the window (wincmd H/J/K/L) or create a new one.
-- `bd` is replaced by a shell script on PATH (test double): `show` prints show.json, anything else
-- prints list.json. watch.acquire is wrapped by a delegating spy that counts acquire/release.

local cli = require("beads.cli")
local store = require("beads.store")
local watch = require("beads.watch")

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

local orig_path, bin_dir, fake_dir, orig_columns, orig_lines, orig_acquire
local spy -- { acquired, released, min_net }

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

-- ep-a > { ch-b, ep-s > { gc-x, gc-y } }, root leaf bl-d.
local function base_items()
  return {
    bead("ep-a", "Epic alpha", { issue_type = "epic", priority = 1 }),
    child_of("ch-b", "ep-a", "Child bravo"),
    child_of("ep-s", "ep-a", "Sub epic", { issue_type = "epic" }),
    child_of("gc-x", "ep-s", "Grandchild xray"),
    child_of("gc-y", "ep-s", "Grandchild yankee"),
    bead("bl-d", "Leaf delta"),
  }
end

local function net()
  return spy.acquired - spy.released
end

-- Tree windows of the current tabpage.
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

local function other_win()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if
      vim.bo[vim.api.nvim_win_get_buf(w)].filetype ~= "beads-tree"
      and vim.api.nvim_win_get_config(w).relative == ""
    then
      return w
    end
  end
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

local function geom(w)
  local p = vim.api.nvim_win_get_position(w)
  return { row = p[1], col = p[2], width = vim.api.nvim_win_get_width(w), height = vim.api.nvim_win_get_height(w) }
end

-- The auto size (beads_nvim-4u9.13) the tree's current content asks for at `pos`.
local function auto_size(t, pos)
  local rows = vim.api.nvim_win_call(t, function()
    local out, l, last = {}, 1, vim.fn.line("$")
    while l <= last do
      out[#out + 1] = vim.fn.getline(l)
      local e = vim.fn.foldclosedend(l)
      l = (e > 0 and e or l) + 1
    end
    return out
  end)
  if pos == "left" or pos == "right" then
    local m = 0
    for _, l in ipairs(rows) do
      m = math.max(m, vim.fn.strdisplaywidth(l))
    end
    return math.max(24, math.min(math.floor(vim.o.columns / 2), m))
  end
  return math.max(6, math.min(math.floor(vim.o.lines * 0.4), #rows))
end

-- Asserts the tree window sits at `pos` with the given size (width for left/right, height for bottom/top).
local function assert_at(pos, size)
  local t = tree_win()
  if size == "auto" then
    local horiz = pos == "left" or pos == "right"
    vim.wait(1000, function()
      local cur = horiz and vim.api.nvim_win_get_width(t) or vim.api.nvim_win_get_height(t)
      return cur == auto_size(t, pos)
    end, 10)
    size = auto_size(t, pos)
  end
  local o = other_win()
  assert.is_not_nil(o, "no editor window next to the tree")
  local tg, og = geom(t), geom(o)
  local desc = ("%s: tree %s, other %s"):format(pos, vim.inspect(tg), vim.inspect(og))
  if pos == "left" then
    assert.are.equal(0, tg.col, "tree is not at the left edge; " .. desc)
    assert.is_true(og.col > tg.col, "editor window is not right of the tree; " .. desc)
    assert.are.equal(og.height, tg.height, "tree does not span the full height; " .. desc)
    assert.are.equal(size, tg.width, "tree width; " .. desc)
  elseif pos == "right" then
    assert.are.equal(vim.o.columns, tg.col + tg.width, "tree is not at the right edge; " .. desc)
    assert.are.equal(0, og.col, "editor window is not left of the tree; " .. desc)
    assert.are.equal(og.height, tg.height, "tree does not span the full height; " .. desc)
    assert.are.equal(size, tg.width, "tree width; " .. desc)
  elseif pos == "bottom" then
    assert.are.equal(vim.o.columns, tg.width, "tree does not span the full width; " .. desc)
    assert.is_true(tg.row > og.row, "tree is not below the editor window; " .. desc)
    assert.are.equal(size, tg.height, "tree height; " .. desc)
  elseif pos == "top" then
    assert.are.equal(vim.o.columns, tg.width, "tree does not span the full width; " .. desc)
    assert.are.equal(0, tg.row, "tree is not at the top; " .. desc)
    assert.is_true(og.row > tg.row, "editor window is not below the tree; " .. desc)
    assert.are.equal(size, tg.height, "tree height; " .. desc)
  end
  return t
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

local function press(keys)
  vim.api.nvim_set_current_win(tree_win())
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

-- Default sizes are "auto" (beads_nvim-4u9.13): computed from the rendered tree by assert_at.
local W, H = "auto", "auto"

describe(":Beads tree layout", function()
  before_each(function()
    if vim.fn.exists(":Beads") ~= 2 then
      vim.cmd.source(plugin_root .. "/plugin/beads.lua")
    end
    require("beads").setup({ tree = { layout = "split" } })
    orig_columns, orig_lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 120, 40
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
    vim.fn.writefile({ vim.json.encode(base_items()) }, fake_dir .. "/list.json")
    vim.fn.writefile({ vim.json.encode({ bead("bl-d", "Leaf delta") }) }, fake_dir .. "/show.json")
    prefill()
    spy = { acquired = 0, released = 0, min_net = math.huge }
    orig_acquire = watch.acquire
    watch.acquire = function(root)
      local rel = orig_acquire(root)
      spy.acquired = spy.acquired + 1
      return function(...)
        spy.released = spy.released + 1
        spy.min_net = math.min(spy.min_net, spy.acquired - spy.released)
        return rel(...)
      end
    end
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
    watch.acquire = orig_acquire
    vim.wait(100, function()
      return false
    end, 10)
    pcall(vim.fn.delete, cli.get_root(), "rf")
    cli.set_root(nil)
    vim.env.PATH = orig_path
    vim.fn.delete(bin_dir, "rf")
    vim.fn.delete(fake_dir, "rf")
    vim.o.columns, vim.o.lines = orig_columns, orig_lines
    require("beads").setup({ tree = { layout = "split" } })
  end)

  describe("opening at each position with the default size", function()
    for _, case in ipairs({ { "left", W }, { "right", W }, { "bottom", H }, { "top", H } }) do
      it(":Beads tree " .. case[1], function()
        vim.cmd("Beads tree " .. case[1])
        wait_rendered("bl-d")
        assert_at(case[1], case[2])
      end)
    end
  end)

  describe("default sizes are clamped", function()
    it("width is at least 24 (80 columns)", function()
      vim.o.columns = 80
      vim.cmd("Beads tree left")
      assert_at("left", W)
    end)

    it("width is at most 42 (200 columns)", function()
      vim.o.columns = 200
      vim.cmd("Beads tree right")
      assert_at("right", W)
    end)

    it("height is at least 6 (16 lines)", function()
      vim.o.lines = 16
      vim.cmd("Beads tree bottom")
      assert_at("bottom", H)
    end)

    it("height is at most 15 (60 lines)", function()
      vim.o.lines = 60
      vim.cmd("Beads tree top")
      assert_at("top", H)
    end)
  end)

  describe("explicit sizes", function()
    it("width is honoured on the left and right", function()
      require("beads").setup({ tree = { layout = "split", width = 37 } })
      vim.cmd("Beads tree right")
      assert_at("right", 37)
      vim.cmd("Beads tree left")
      assert_at("left", 37)
    end)

    it("height is honoured at the bottom and top", function()
      require("beads").setup({ tree = { layout = "split", height = 9 } })
      vim.cmd("Beads tree bottom")
      assert_at("bottom", 9)
      vim.cmd("Beads tree top")
      assert_at("top", 9)
    end)
  end)

  describe("moving an open tree", function()
    it(":Beads tree bottom keeps the buffer, folds, cursor bead and the watcher", function()
      vim.cmd("Beads tree left")
      local t = wait_rendered("gc-y")
      local buf = vim.api.nvim_win_get_buf(t)
      assert.are.equal(1, net(), "opening the tree must acquire the watcher once")
      vim.api.nvim_win_call(t, function()
        vim.cmd("silent! normal! zR")
        vim.api.nvim_win_set_cursor(t, { row_of(t, "ep-s"), 0 })
        vim.cmd("silent! normal! zc")
      end)
      local rs = row_of(t, "ep-s")
      assert.are.equal(rs, vim.api.nvim_win_call(t, function()
        return vim.fn.foldclosed(rs)
      end), "setup: ep-s fold did not close")
      vim.api.nvim_win_set_cursor(t, { row_of(t, "bl-d"), 0 })

      vim.cmd("Beads tree bottom")

      local nt = assert_at("bottom", H)
      assert.is_true(vim.api.nvim_buf_is_valid(buf), "the tree buffer was wiped by the move")
      assert.are.equal(buf, vim.api.nvim_win_get_buf(nt), "the tree buffer was recreated by the move")
      local nrs = row_of(nt, "ep-s")
      assert.are.equal(nrs, vim.api.nvim_win_call(nt, function()
        return vim.fn.foldclosed(nrs)
      end), "ep-s fold was not kept closed:\n" .. dump(nt))
      local line = lines_of(nt)[vim.api.nvim_win_get_cursor(nt)[1]] or ""
      assert.is_truthy(line:find("bl-d", 1, true), "cursor left bl-d, now on: " .. line)
      assert.are.equal(1, net(), "moving changed the watcher acquisition")
      assert.is_true(spy.min_net >= 1, "the watcher was released during the move")
      -- the moved tree still re-renders from the store (still subscribed)
      vim.fn.writefile(
        { vim.json.encode(vim.list_extend(base_items(), { bead("nw-z", "New zulu") })) },
        fake_dir .. "/list.json"
      )
      store.refresh(cli.get_root())
      assert(vim.wait(3000, function()
        return row_of(tree_win(), "nw-z") ~= nil
      end, 10), "the moved tree no longer re-renders on store updates:\n" .. dump(tree_win()))
    end)

    it(":Beads tree <pos> on an open tree moves it instead of closing it", function()
      vim.cmd("Beads tree left")
      wait_rendered("bl-d")
      vim.cmd("Beads tree right")
      assert_at("right", W)
      vim.cmd("Beads tree top")
      assert_at("top", H)
      vim.cmd("Beads tree left")
      assert_at("left", W)
      assert.are.equal(1, #tree_wins())
    end)

    it("keeps exactly one tree per tabpage and moves only this tabpage's tree", function()
      vim.cmd("Beads tree left")
      wait_rendered("bl-d")
      local tab1 = vim.api.nvim_get_current_tabpage()
      vim.cmd("tabnew")
      vim.cmd("Beads tree right")
      wait_rendered("bl-d")
      vim.cmd("Beads tree bottom")
      assert_at("bottom", H)
      assert.are.equal(2, net(), "two tabpage trees must hold two acquisitions")
      vim.api.nvim_set_current_tabpage(tab1)
      assert_at("left", W)
      assert.is_true(spy.min_net >= 2, "a watcher acquisition was released while moving")
    end)

    it("closing a moved tree releases the watcher exactly once", function()
      vim.cmd("Beads tree left")
      wait_rendered("bl-d")
      vim.cmd("Beads tree bottom")
      assert_at("bottom", H)
      vim.cmd("Beads tree top")
      assert_at("top", H)
      assert.are.equal(1, net())
      assert.is_true(spy.min_net >= 1, "the watcher was released while moving")
      vim.cmd("Beads tree")
      assert.are.equal(0, #tree_wins(), "plain :Beads tree did not close the open tree")
      assert.are.equal(0, net(), "closing the moved tree did not release the watcher")
    end)
  end)

  describe("L cycles positions", function()
    it("left -> bottom -> right -> top -> left", function()
      vim.cmd("Beads tree left")
      local t = wait_rendered("bl-d")
      local buf = vim.api.nvim_win_get_buf(t)
      for _, step in ipairs({ { "bottom", H }, { "right", W }, { "top", H }, { "left", W } }) do
        press("L")
        local nt = assert_at(step[1], step[2])
        assert.are.equal(buf, vim.api.nvim_win_get_buf(nt), "L recreated the tree buffer")
      end
      assert.are.equal(1, net())
      assert.is_true(spy.min_net >= 1, "the watcher was released while cycling")
    end)

    it("the next :Beads tree reopens at the last position chosen with L", function()
      vim.cmd("Beads tree left")
      wait_rendered("bl-d")
      press("L")
      assert_at("bottom", H)
      vim.cmd("Beads tree")
      assert.are.equal(0, #tree_wins())
      vim.cmd("Beads tree")
      wait_rendered("bl-d")
      assert_at("bottom", H)
      press("L")
      assert_at("right", W)
    end)

    it("the next :Beads tree reopens at the last position chosen with :Beads tree <pos>", function()
      vim.cmd("Beads tree top")
      wait_rendered("bl-d")
      vim.cmd("Beads tree right")
      vim.cmd("Beads tree")
      assert.are.equal(0, #tree_wins())
      vim.cmd("Beads tree")
      assert_at("right", W)
    end)

    it("keymaps.tree_view.layout rebinds the cycle key", function()
      require("beads").setup({ tree = { layout = "split" }, keymaps = { tree_view = { layout = "gL" } } })
      vim.cmd("Beads tree left")
      wait_rendered("bl-d")
      press("gL")
      assert_at("bottom", H)
    end)
  end)
end)
