-- Bead beads_nvim-i7f: tree-first view (default tree.layout = "full").
-- Interface under test: require("beads").setup({ tree = { layout = "full"|"split", height = ... } }),
-- :Beads tree (toggle) and the tree keys <CR>, K, q, mouse clicks; q / :bd in the detail.
--   * Default (layout "full"): toggling the tree shows it in the current window (same window id,
--     no new window, full width and height); no detail window opens.
--   * <CR> / mouse open on a bead: detail window above, tree below (full width each); the tree
--     height is tree.height (a number), or about 40% of the lines by default; the cursor goes to
--     the detail. Opening another bead reuses the same detail window.
--   * K shows the peek float and does not change the layout.
--   * q or :bd in the detail returns to the tree-only view with the cursor on the same bead.
--   * Closing the tree (toggle or q) restores the window's previous buffer in the same window.
-- assumption: with the default tree.height ("auto") and more beads than fit, the tree below the
--   detail is floor(lines * 0.4) rows high, +-2.
-- assumption: the tree keeps the window it was opened in (the "current window").
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

describe("tree.layout = 'full' (default)", function()
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

  it("toggling the tree fills the current window and opens no detail", function()
    local w0 = vim.api.nvim_get_current_win()
    local h0 = vim.api.nvim_win_get_height(w0)
    local tree = open_tree()
    local desc = layout_desc()
    assert.are.equal(1, #normal_wins(), "the tree opened a new window:\n" .. desc)
    assert.are.equal(w0, tree, "the tree is not in the current window:\n" .. desc)
    assert.are.equal(vim.o.columns, vim.api.nvim_win_get_width(tree), "tree is not full width:\n" .. desc)
    assert.are.equal(h0, vim.api.nvim_win_get_height(tree), "tree is not full height:\n" .. desc)
    settle()
    assert.is_nil(any_detail(), "a detail window opened with the tree:\n" .. layout_desc())
  end)

  it("toggling the tree off restores the window's previous buffer", function()
    vim.cmd.edit(vim.fn.fnameescape(tmpfile))
    local w0, b0 = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    assert.are.equal(w0, open_tree(), "the tree is not in the current window:\n" .. layout_desc())
    vim.cmd("Beads tree")
    local desc = layout_desc()
    assert.is_nil(tree_win(), "the tree is still open:\n" .. desc)
    assert.are.equal(1, #normal_wins(), "expected the single original window:\n" .. desc)
    assert.is_true(vim.api.nvim_win_is_valid(w0), "the original window was closed")
    assert.are.equal(b0, vim.api.nvim_win_get_buf(w0), "the previous buffer was not restored:\n" .. desc)
  end)

  it("q in the tree restores the window's previous buffer", function()
    vim.cmd.edit(vim.fn.fnameescape(tmpfile))
    local w0, b0 = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    local tree = open_tree()
    assert.are.equal(w0, tree, "the tree is not in the current window:\n" .. layout_desc())
    press(tree, "q")
    local desc = layout_desc()
    assert.is_nil(tree_win(), "q did not close the tree:\n" .. desc)
    assert.are.equal(1, #normal_wins(), "expected the single original window:\n" .. desc)
    assert.is_true(vim.api.nvim_win_is_valid(w0), "the original window was closed")
    assert.are.equal(b0, vim.api.nvim_win_get_buf(w0), "the previous buffer was not restored:\n" .. desc)
  end)

  it("<CR> opens the detail above and the tree below; the cursor goes to the detail", function()
    local tree = open_tree()
    on_bead(tree, "ch-b")
    press(tree, "<CR>")
    assert_split_view("ch-b")
  end)

  it("the tree below the detail is tree.height rows high when it is a number", function()
    require("beads").setup({ tree = { height = 10 } })
    local tree = open_tree()
    on_bead(tree, "ch-b")
    press(tree, "<CR>")
    local _, t = assert_split_view("ch-b")
    assert.are.equal(10, vim.api.nvim_win_get_height(t), "tree height:\n" .. layout_desc())
  end)

  it("by default the tree below the detail is about 40% of the lines", function()
    set_list(leaves(30))
    local tree = open_tree("lf-30")
    on_bead(tree, "lf-05")
    press(tree, "<CR>")
    local _, t = assert_split_view("lf-05")
    local want, got = math.floor(vim.o.lines * 0.4), vim.api.nvim_win_get_height(t)
    assert.is_true(math.abs(got - want) <= 2, ("tree height %d, want about %d:\n%s"):format(got, want, layout_desc()))
  end)

  it("opening another bead from the tree reuses the same detail window", function()
    local tree = open_tree()
    on_bead(tree, "ch-b")
    press(tree, "<CR>")
    local d1, t = assert_split_view("ch-b")
    on_bead(t, "bl-d")
    press(t, "<CR>")
    local d2 = assert_split_view("bl-d")
    assert.are.equal(d1, d2, "a second detail window was opened:\n" .. layout_desc())
  end)

  it("K shows the details float and does not change the layout", function()
    local tree = open_tree()
    on_bead(tree, "ch-b")
    press(tree, "K")
    assert(vim.wait(2000, function()
      return #floats() > 0
    end, 10), "K opened no float")
    local desc = layout_desc()
    assert.are.equal(1, #normal_wins(), "K changed the layout:\n" .. desc)
    assert.are.equal(tree, tree_win(), "the tree window changed:\n" .. desc)
    assert.are.equal(vim.o.columns, vim.api.nvim_win_get_width(tree), "tree is not full width:\n" .. desc)
    assert.is_nil(any_detail(), "K opened a detail window:\n" .. desc)
  end)

  it("q in the detail returns to the tree-only view on the same bead", function()
    local h0 = vim.api.nvim_win_get_height(0)
    local tree = open_tree()
    on_bead(tree, "ch-b")
    press(tree, "<CR>")
    local d = assert_split_view("ch-b")
    press(d, "q")
    local t = assert_tree_only(h0, "ch-b")
    assert.are.equal(t, vim.api.nvim_get_current_win(), "the cursor is not in the tree")
  end)

  it(":bd in the detail returns to the tree-only view on the same bead", function()
    local h0 = vim.api.nvim_win_get_height(0)
    local tree = open_tree()
    on_bead(tree, "bl-d")
    press(tree, "<CR>")
    local d = assert_split_view("bl-d")
    vim.api.nvim_set_current_win(d)
    vim.cmd("bd")
    local t = assert_tree_only(h0, "bl-d")
    assert.are.equal(t, vim.api.nvim_get_current_win(), "the cursor is not in the tree")
  end)

  it("<2-LeftMouse> on a bead behaves like <CR>", function()
    local tree = open_tree()
    local rb = row_of(tree, "bl-d")
    local col = at(tree, rb, "bl-d")
    click(tree, rb, col, "<LeftMouse>")
    click(tree, rb, col, "<2-LeftMouse>")
    assert_split_view("bl-d")
  end)

  it("<LeftMouse> on a bead's title behaves like <CR>", function()
    local tree = open_tree()
    local rb = row_of(tree, "ch-b")
    click(tree, rb, at(tree, rb, "Child bravo") + 2)
    assert_split_view("ch-b")
  end)
end)
