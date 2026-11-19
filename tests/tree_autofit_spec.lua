-- Bead beads_nvim-4u9.13: the tree sizes itself to its content by default.
-- Interface under test: lua/beads/views/tree.lua via :Beads tree [left|right|bottom|top], the tree
-- keys (<Tab> fold, f filter, H closed, L layout) and require("beads").setup({ tree = ... }).
--   * tree.width = "auto" (default), left/right: width = longest visible line (strdisplaywidth),
--     clamped to [24, tree.max_width], max_width default floor(columns / 2).
--   * tree.height = "auto" (default), bottom/top: height = visible line count, clamped to
--     [6, tree.max_height], max_height default floor(lines * 0.4).
--   * Refit after every render (refresh, fold/unfold, filter, sort, H, layout change) and on VimResized.
--   * A number in tree.width / tree.height keeps a fixed size.
--   * A manual resize of the tree window stops auto-fit until the tree is reopened.
-- Expected sizes are computed from the rendered buffer: a closed fold counts as one visible row.
-- Fixtures keep closed-fold rows shorter than the longest row, so the foldtext suffix never matters.
-- Headless nvim never fires WinResized by itself (no UI loop), so the tests fire it explicitly with
-- nvim_exec_autocmds after a resize, the way a UI would. v:event is not set by that call.
-- `bd` is replaced by a shell script on PATH (test double): `show` prints show.json, anything else
-- prints list.json. vim.ui.input is replaced by a stub for the filter prompt.

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

local orig_path, bin_dir, fake_dir, orig_columns, orig_lines, orig_input
local input_answer

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

local function long(word, n)
  return (word .. " "):rep(n):sub(1, -2)
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

local function longest(win)
  local m = 0
  for _, l in ipairs(visible_rows(win)) do
    m = math.max(m, vim.fn.strdisplaywidth(l))
  end
  return m
end

local function expected_width(win, max_width)
  return clamp(longest(win), 24, max_width or math.floor(vim.o.columns / 2))
end

local function expected_height(win, max_height)
  return clamp(#visible_rows(win), 6, max_height or math.floor(vim.o.lines * 0.4))
end

local function width(win)
  return vim.api.nvim_win_get_width(win)
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

local function wait_gone(id)
  assert(vim.wait(3000, function()
    return row_of(tree_win(), id) == nil
  end, 10), id .. " is still shown:\n" .. dump(tree_win()))
end

-- Polls until the tree's size equals what its content asks for; returns that size.
local function assert_fits(dim, opts)
  opts = opts or {}
  local t = tree_win()
  local get = dim == "width" and width or height
  local want
  vim.wait(1000, function()
    want = dim == "width" and expected_width(t, opts.max) or expected_height(t, opts.max)
    return get(t) == want
  end, 10)
  want = dim == "width" and expected_width(t, opts.max) or expected_height(t, opts.max)
  assert.are.equal(
    want,
    get(t),
    ("tree %s does not fit its content (%d columns x %d lines):\n%s"):format(dim, vim.o.columns, vim.o.lines, dump(t))
  )
  return want
end

local function press(keys)
  vim.api.nvim_set_current_win(tree_win())
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

local function refresh(id)
  store.refresh(cli.get_root())
  return wait_rendered(id)
end

local function fire_win_resized(win)
  vim.api.nvim_exec_autocmds("WinResized", { pattern = tostring(win), modeline = false })
end

local function settle()
  vim.wait(150, function()
    return false
  end, 10)
end

describe("tree auto-fit", function()
  before_each(function()
    if vim.fn.exists(":Beads") ~= 2 then
      vim.cmd.source(plugin_root .. "/plugin/beads.lua")
    end
    require("beads").setup({ tree = { layout = "split" } })
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
    vim.fn.writefile({ vim.json.encode({ bead("lf-01", "Leaf 1") }) }, fake_dir .. "/show.json")
    orig_input = vim.ui.input
    input_answer = nil
    vim.ui.input = function(_, on_confirm)
      on_confirm(input_answer)
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
    vim.ui.input = orig_input
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

  it('defaults tree.width and tree.height to "auto"', function()
    require("beads").setup({ tree = { layout = "split" } })
    assert.are.equal("auto", require("beads").config.tree.width)
    assert.are.equal("auto", require("beads").config.tree.height)
  end)

  describe("default width (left / right)", function()
    it("a left tree is as wide as its longest visible line", function()
      set_list({ bead("lg-a", long("Wide", 14)), unpack(leaves(2)) })
      vim.cmd("Beads tree left")
      local t = wait_rendered("lg-a")
      local w = assert_fits("width")
      assert.is_true(
        vim.fn.strdisplaywidth(lines_of(t)[row_of(t, "lg-a")]) == w,
        "fixture: the lg-a row should be the longest line:\n" .. dump(t)
      )
      assert.is_true(w > 42 and w < 100, "fixture: width " .. w .. " should be inside the clamp")
    end)

    it("a right tree never grows past floor(columns / 2)", function()
      vim.o.columns = 120
      set_list({ bead("lg-a", long("Wide", 22)), unpack(leaves(2)) })
      vim.cmd("Beads tree right")
      wait_rendered("lg-a")
      assert.are.equal(60, assert_fits("width"))
    end)

    it("tree.max_width caps the auto width", function()
      require("beads").setup({ tree = { layout = "split", max_width = 70 } })
      set_list({ bead("lg-a", long("Wide", 22)), unpack(leaves(2)) })
      vim.cmd("Beads tree left")
      wait_rendered("lg-a")
      assert.are.equal(70, assert_fits("width", { max = 70 }))
    end)
  end)

  describe("default height (bottom / top)", function()
    it("a bottom tree is as tall as its visible line count", function()
      set_list(leaves(8))
      vim.cmd("Beads tree bottom")
      wait_rendered("lf-08")
      local h = assert_fits("height")
      assert.is_true(h > 6 and h < 16, "fixture: height " .. h .. " should be inside the clamp")
    end)

    it("a top tree is never shorter than 6 lines", function()
      set_list(leaves(2))
      vim.cmd("Beads tree top")
      wait_rendered("lf-02")
      assert.are.equal(6, assert_fits("height"))
    end)

    it("a bottom tree never grows past floor(lines * 0.4), or tree.max_height", function()
      set_list(leaves(30))
      vim.cmd("Beads tree bottom")
      wait_rendered("lf-30")
      assert.are.equal(16, assert_fits("height"))
      vim.cmd("Beads tree")
      require("beads").setup({ tree = { layout = "split", max_height = 10 } })
      vim.cmd("Beads tree bottom")
      wait_rendered("lf-30")
      assert.are.equal(10, assert_fits("height", { max = 10 }))
    end)
  end)

  describe("refit", function()
    it("after a refresh that adds a longer title", function()
      set_list(leaves(3))
      vim.cmd("Beads tree left")
      wait_rendered("lf-03")
      local before = assert_fits("width")
      set_list({ bead("lg-a", long("Wide", 16)), unpack(leaves(3)) })
      refresh("lg-a")
      local after = assert_fits("width")
      assert.are_not.equal(before, after, "fixture: the new title did not change the wanted width")
    end)

    it("after folding and unfolding with <Tab> (height at the bottom, width on the left)", function()
      local kids = {}
      for i = 1, 5 do
        kids[i] = child_of(("ch-%d"):format(i), "ep-a", "Kid " .. i)
      end
      kids[6] = child_of("ch-w", "ep-a", long("Wide", 16))
      local items = { bead("ep-a", "Epic alpha", { issue_type = "epic", priority = 1 }) }
      vim.list_extend(items, kids)
      vim.list_extend(items, leaves(5))
      set_list(items)
      vim.cmd("Beads tree bottom")
      local t = wait_rendered("ch-w")
      local open_h = assert_fits("height")
      vim.api.nvim_win_set_cursor(t, { row_of(t, "ep-a"), 0 })
      press("<Tab>")
      local r = row_of(t, "ep-a")
      assert.are.equal(r, vim.api.nvim_win_call(t, function()
        return vim.fn.foldclosed(r)
      end), "<Tab> did not fold ep-a:\n" .. dump(t))
      local folded_h = assert_fits("height")
      assert.are_not.equal(open_h, folded_h, "fixture: folding did not change the wanted height")
      press("<Tab>")
      assert.are.equal(open_h, assert_fits("height"))

      vim.cmd("Beads tree left")
      t = tree_win()
      local open_w = assert_fits("width")
      vim.api.nvim_win_set_cursor(t, { row_of(t, "ep-a"), 0 })
      press("<Tab>")
      local folded_w = assert_fits("width")
      assert.are_not.equal(open_w, folded_w, "fixture: folding did not change the wanted width")
      press("<Tab>")
      assert.are.equal(open_w, assert_fits("width"))
    end)

    it("after filtering", function()
      set_list({ bead("lg-a", long("Wide", 18)), bead("sh-b", "Short bravo"), bead("sh-c", "Short charlie") })
      vim.cmd("Beads tree left")
      wait_rendered("lg-a")
      local before = assert_fits("width")
      input_answer = "bravo"
      press("f")
      wait_gone("lg-a")
      local after = assert_fits("width")
      assert.are_not.equal(before, after, "fixture: filtering did not change the wanted width")
    end)

    it("after toggling closed beads with H", function()
      set_list({ bead("cl-z", long("Wide", 18), { status = "closed" }), unpack(leaves(3)) })
      vim.cmd("Beads tree left")
      wait_rendered("lf-03")
      local before = assert_fits("width")
      press("H")
      assert(row_of(tree_win(), "cl-z"), "H did not show the closed bead:\n" .. dump(tree_win()))
      local after = assert_fits("width")
      assert.are_not.equal(before, after, "fixture: H did not change the wanted width")
    end)

    it("on VimResized (width and height)", function()
      vim.o.columns = 120
      set_list({ bead("lg-a", long("Wide", 16)), unpack(leaves(29)) })
      vim.cmd("Beads tree left")
      wait_rendered("lg-a")
      assert.are.equal(60, assert_fits("width"))
      vim.o.columns = 200
      vim.api.nvim_exec_autocmds("VimResized", { modeline = false })
      local w = assert_fits("width")
      assert.is_true(w > 60, "fixture: the content should be wider than 60 columns")

      vim.cmd("Beads tree bottom")
      assert.are.equal(16, assert_fits("height"))
      vim.o.lines = 60
      vim.api.nvim_exec_autocmds("VimResized", { modeline = false })
      assert.are.equal(24, assert_fits("height"))
    end)
  end)

  describe("numeric sizes", function()
    -- passes already: tree.width / tree.height numbers are fixed sizes (beads_nvim-4u9.5).
    it("tree.width = 37 and tree.height = 9 never refit", function()
      require("beads").setup({ tree = { layout = "split", width = 37, height = 9 } })
      set_list(leaves(2))
      vim.cmd("Beads tree left")
      local t = wait_rendered("lf-02")
      assert.are.equal(37, width(t))
      set_list({ bead("lg-a", long("Wide", 18)), unpack(leaves(12)) })
      refresh("lg-a")
      vim.o.columns = 180
      vim.api.nvim_exec_autocmds("VimResized", { modeline = false })
      settle()
      assert.are.equal(37, width(tree_win()))
      vim.cmd("Beads tree bottom")
      settle()
      assert.are.equal(9, height(tree_win()))
      press("H")
      settle()
      assert.are.equal(9, height(tree_win()))
    end)
  end)

  describe("manual resize", function()
    it("stops auto-fit until the tree is reopened", function()
      set_list(leaves(3))
      vim.cmd("Beads tree left")
      local t = wait_rendered("lf-03")
      assert_fits("width")
      vim.api.nvim_win_call(t, function()
        vim.cmd("vertical resize 50")
      end)
      fire_win_resized(t)
      assert.are.equal(50, width(t))
      set_list({ bead("lg-a", long("Wide", 18)), unpack(leaves(3)) })
      refresh("lg-a")
      vim.o.columns = 180
      vim.api.nvim_exec_autocmds("VimResized", { modeline = false })
      settle()
      assert.are.equal(50, width(tree_win()), "auto-fit changed a hand-resized tree")
      vim.cmd("Beads tree")
      assert.are.equal(0, #tree_wins(), "plain :Beads tree did not close the tree")
      vim.cmd("Beads tree")
      wait_rendered("lg-a")
      local w = assert_fits("width")
      assert.are_not.equal(50, w, "fixture: the reopened tree should want another width than 50")
    end)

    it("the plugin's own resizes do not count as a manual resize", function()
      set_list(leaves(3))
      vim.cmd("Beads tree left")
      local t = wait_rendered("lf-03")
      assert_fits("width")
      fire_win_resized(t)
      set_list({ bead("lg-a", long("Wide", 16)), unpack(leaves(3)) })
      refresh("lg-a")
      local w = assert_fits("width")
      fire_win_resized(tree_win())
      press("L")
      local h = assert_fits("height")
      fire_win_resized(tree_win())
      set_list({ bead("lg-a", long("Wide", 16)), unpack(leaves(9)) })
      refresh("lf-09")
      assert.are_not.equal(h, assert_fits("height"), "fixture: more beads should want more height")
      assert.is_true(w > 0)
    end)
  end)
end)
