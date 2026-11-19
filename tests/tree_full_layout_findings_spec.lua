-- Bead beads_nvim-i7f, review findings (tree.layout = "full" and the split layout's q).
--   1. Window options: the tree sets its options locally; the detail window gets the user's own
--      defaults and the original window keeps its options after the tree closes.
--   2. Auto height: after <CR>, q in the detail, <CR> again the tree is about 40% of the lines again.
--   3. :Beads tree left from the detail leaves the cursor in the new tree window.
--   4. A listed previous buffer stays listed when restored.
--   5. Closing the tree by any means (q, :close, <C-w>c, :only) restores the previous buffer and
--      closes the detail; a detail with unsaved edits stays open and a "Beads: " notification says why.
--   6. tree.layout = "split" (bottom, left): q in the detail closes it and keeps the tree (bead bbv).

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

local OPTS = { "number", "wrap", "signcolumn", "foldmethod" }

local function opts_of(win)
  local out = {}
  for _, o in ipairs(OPTS) do
    out[o] = vim.wo[win][o]
  end
  return out
end

local function globals()
  local out = {}
  for _, o in ipairs(OPTS) do
    out[o] = vim.go[o]
  end
  return out
end

local function enter_edit_and_modify(d)
  local dbuf = vim.api.nvim_win_get_buf(d)
  assert(vim.wait(3000, function()
    return table.concat(vim.api.nvim_buf_get_lines(dbuf, 0, -1, false), "\n"):find("Shown", 1, true) ~= nil
  end, 10), "the detail never loaded:\n" .. table.concat(vim.api.nvim_buf_get_lines(dbuf, 0, -1, false), "\n"))
  settle()
  require("beads.views.detail").enter_edit(dbuf)
  vim.bo[dbuf].modifiable = true
  vim.api.nvim_buf_set_lines(dbuf, -1, -1, false, { "unsaved edit" })
  assert.is_true(vim.bo[dbuf].modified, "the detail buffer is not modified")
  return dbuf
end

describe("tree.layout = 'full' review findings", function()
  local tmpfile, notes, orig_notify

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
    notes = {}
    orig_notify = vim.notify
    vim.notify = function(msg, level, o)
      notes[#notes + 1] = tostring(msg)
    end
  end)

  after_each(function()
    vim.notify = orig_notify
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
    vim.cmd("set number& wrap& signcolumn& foldmethod& foldexpr& foldtext& foldlevel& relativenumber&")
    pcall(vim.fn.delete, cli.get_root(), "rf")
    cli.set_root(nil)
    vim.env.PATH = orig_path
    vim.fn.delete(bin_dir, "rf")
    vim.fn.delete(fake_dir, "rf")
    pcall(vim.fn.delete, tmpfile)
    vim.o.columns, vim.o.lines = orig_columns, orig_lines
    require("beads").setup({})
  end)

  -- 1. tree.lua:869 / :580-582
  it("the detail window gets the user's own window options, not the tree's", function()
    vim.cmd("set number wrap signcolumn=yes foldmethod=indent")
    vim.cmd.edit(vim.fn.fnameescape(tmpfile))
    local want = opts_of(0)
    local tree = open_tree()
    on_bead(tree, "ch-b")
    press(tree, "<CR>")
    local d = assert_split_view("ch-b")
    settle()
    assert.are.same(want, opts_of(d), "detail window options:\n" .. layout_desc())
  end)

  it("after the tree closes the original window and the global options are unchanged", function()
    vim.cmd("set number wrap signcolumn=yes foldmethod=indent")
    vim.cmd.edit(vim.fn.fnameescape(tmpfile))
    local w0 = vim.api.nvim_get_current_win()
    local want, want_g = opts_of(w0), globals()
    local tree = open_tree()
    on_bead(tree, "ch-b")
    press(tree, "<CR>")
    assert_split_view("ch-b")
    vim.cmd("Beads tree")
    settle()
    assert.is_nil(tree_win(), "the tree is still open:\n" .. layout_desc())
    assert.is_true(vim.api.nvim_win_is_valid(w0), "the original window was closed")
    assert.are.same(want, opts_of(w0), "original window options after the tree closed")
    assert.are.same(want_g, globals(), "global option values changed")
    local other = vim.fn.tempname() .. ".txt"
    vim.fn.writefile({ "other" }, other)
    vim.api.nvim_set_current_win(w0)
    vim.cmd.edit(vim.fn.fnameescape(other))
    local got = opts_of(w0)
    vim.fn.delete(other)
    assert.are.same(want, got, "window options after :e other.txt")
    assert.are_not.equal("v:lua.require'beads.views.tree'.foldexpr(v:lnum)", vim.wo[w0].foldexpr, "tree foldexpr leaked")
  end)

  -- 2. tree.lua:587 / :913
  it("auto height: <CR>, q in the detail, <CR> again keeps the tree at about 40% of the lines", function()
    set_list(leaves(30))
    local h0 = vim.api.nvim_win_get_height(0)
    local tree = open_tree("lf-30")
    on_bead(tree, "lf-05")
    press(tree, "<CR>")
    local d = assert_split_view("lf-05")
    settle()
    press(d, "q")
    -- The main loop fires WinResized (normal_check) before scheduled callbacks run; headless
    -- tests never reach normal_check, so fire it here, in that order.
    vim.api.nvim_exec_autocmds("WinResized", {})
    settle()
    local t = assert_tree_only(h0, "lf-05")
    settle()
    on_bead(t, "lf-05")
    press(t, "<CR>")
    local _, t2 = assert_split_view("lf-05")
    settle()
    local want, got = math.floor(vim.o.lines * 0.4), vim.api.nvim_win_get_height(t2)
    assert.is_true(math.abs(got - want) <= 2, ("tree height %d, want about %d:\n%s"):format(got, want, layout_desc()))
  end)

  -- 3. tree.lua:592
  it(":Beads tree left from the detail window leaves the cursor in the new tree window", function()
    local tree = open_tree()
    on_bead(tree, "ch-b")
    press(tree, "<CR>")
    local d = assert_split_view("ch-b")
    vim.api.nvim_set_current_win(d)
    vim.cmd("Beads tree left")
    local t
    assert(vim.wait(3000, function()
      t = tree_win()
      return t ~= nil and row_of(t, "bl-d") ~= nil
    end, 10), ":Beads tree left never rendered:\n" .. layout_desc())
    settle()
    t = tree_win()
    local desc = layout_desc()
    assert.are.equal(0, vim.api.nvim_win_get_position(t)[2], "tree is not at the left edge:\n" .. desc)
    assert.are.equal(t, vim.api.nvim_get_current_win(), "the cursor is not in the new tree window:\n" .. desc)
  end)

  -- 4. nit tree.lua:553
  it("a listed previous buffer stays listed when the tree restores it", function()
    vim.cmd.edit(vim.fn.fnameescape(tmpfile))
    local w0, b0 = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    assert.is_true(vim.bo[b0].buflisted)
    local tree = open_tree()
    on_bead(tree, "ch-b")
    press(tree, "<CR>")
    assert_split_view("ch-b")
    press(tree_win(), "q")
    settle()
    assert.are.equal(b0, vim.api.nvim_win_get_buf(w0), "the previous buffer was not restored:\n" .. layout_desc())
    assert.is_true(vim.bo[b0].buflisted, "the restored buffer is no longer listed")
  end)

  -- assumption: a previous buffer :bd-ed while the tree was open is not brought back unlisted
  -- (re-listing it or falling back to a new buffer both pass).
  it("closing the tree never shows an unlisted or unloaded buffer when the previous one was :bd-ed", function()
    vim.cmd.edit(vim.fn.fnameescape(tmpfile))
    local b0 = vim.api.nvim_get_current_buf()
    local tree = open_tree()
    vim.api.nvim_set_current_win(tree)
    vim.cmd("bdelete " .. b0)
    settle()
    tree = tree_win()
    assert.is_not_nil(tree, ":bdelete of the previous buffer closed the tree:\n" .. layout_desc())
    press(tree, "q")
    settle()
    local desc = layout_desc()
    assert.is_nil(tree_win(), "q did not close the tree:\n" .. desc)
    local shown = vim.api.nvim_win_get_buf(normal_wins()[1])
    assert.is_true(vim.bo[shown].buflisted, "the window shows an unlisted buffer:\n" .. desc)
    assert.is_true(vim.api.nvim_buf_is_loaded(shown), "the window shows an unloaded buffer:\n" .. desc)
  end)

  -- 5. nit tree.lua:891 / :548
  local closers = {
    q = function(t)
      press(t, "q")
    end,
    [":close"] = function(t)
      vim.api.nvim_set_current_win(t)
      vim.cmd("close")
    end,
    ["<C-w>c"] = function(t)
      press(t, "<C-w>c")
    end,
  }
  for _, name in ipairs({ "q", ":close", "<C-w>c" }) do
    it("closing the tree with " .. name .. " restores the previous buffer and closes the detail", function()
      vim.cmd.edit(vim.fn.fnameescape(tmpfile))
      local b0 = vim.api.nvim_get_current_buf()
      local tree = open_tree()
      on_bead(tree, "ch-b")
      press(tree, "<CR>")
      local d, t = assert_split_view("ch-b")
      closers[name](t, d)
      settle()
      local desc = layout_desc()
      assert.is_nil(tree_win(), "the tree is still shown:\n" .. desc)
      assert.is_nil(any_detail(), "the detail is still shown:\n" .. desc)
      assert.are.equal(1, #normal_wins(), "expected a single window:\n" .. desc)
      assert.are.equal(b0, vim.api.nvim_win_get_buf(normal_wins()[1]), "the previous buffer was not restored:\n" .. desc)
    end)
  end

  -- :only in the detail means "keep this window": the detail stays; no error, and the tree can be
  -- toggled again afterwards.
  it(":only in the detail window keeps the detail without error and a later :Beads tree works", function()
    vim.cmd.edit(vim.fn.fnameescape(tmpfile))
    local tree = open_tree()
    on_bead(tree, "ch-b")
    press(tree, "<CR>")
    local d = assert_split_view("ch-b")
    vim.api.nvim_set_current_win(d)
    local ok, err = pcall(vim.cmd, "only")
    assert.is_true(ok, ":only errored: " .. tostring(err))
    settle()
    local desc = layout_desc()
    assert.are.equal(1, #normal_wins(), "expected a single window:\n" .. desc)
    assert.is_nil(tree_win(), "the tree is still shown:\n" .. desc)
    assert.are.equal("beads://ch-b", any_detail(), "the detail did not stay:\n" .. desc)
    local t
    ok, err = pcall(function()
      t = open_tree()
    end)
    assert.is_true(ok, ":Beads tree after :only failed: " .. tostring(err))
    assert.are.equal(t, vim.api.nvim_get_current_win(), "the tree is not in the current window:\n" .. layout_desc())
    assert.are.equal(1, #normal_wins(), "the tree opened a new window:\n" .. layout_desc())
  end)

  for _, name in ipairs({ "q", ":close" }) do
    it("closing the tree with " .. name .. " keeps a detail with unsaved edits open and says why", function()
      vim.cmd.edit(vim.fn.fnameescape(tmpfile))
      local tree = open_tree()
      on_bead(tree, "ch-b")
      press(tree, "<CR>")
      local d, t = assert_split_view("ch-b")
      local dbuf = enter_edit_and_modify(d)
      notes = {}
      closers[name](t)
      settle()
      local desc = layout_desc()
      assert.is_nil(tree_win(), "the tree is still shown:\n" .. desc)
      assert.is_true(vim.api.nvim_buf_is_valid(dbuf), "the detail buffer was deleted")
      assert.is_true(vim.bo[dbuf].modified, "the unsaved edits are gone")
      local shown = false
      for _, w in ipairs(normal_wins()) do
        shown = shown or vim.api.nvim_win_get_buf(w) == dbuf
      end
      assert.is_true(shown, "the detail with unsaved edits was closed:\n" .. desc)
      local said = false
      for _, m in ipairs(notes) do
        said = said or m:find("^Beads: ") ~= nil
      end
      assert.is_true(said, "no 'Beads: ' notification, got: " .. vim.inspect(notes))
    end)
  end

  -- 6. bead beads_nvim-bbv (split layout)
  for _, pos in ipairs({ "bottom", "left" }) do
    it("split layout (" .. pos .. "): q in the detail closes it, the tree stays; q in the tree restores the buffer", function()
      require("beads").setup({ tree = { layout = "split", position = pos } })
      vim.cmd.edit(vim.fn.fnameescape(tmpfile))
      local b0 = vim.api.nvim_get_current_buf()
      local tree = open_tree()
      on_bead(tree, "ch-b")
      press(tree, "<CR>")
      local d = wait_detail("ch-b")
      press(d, "q")
      settle()
      local desc = layout_desc()
      assert.is_nil(any_detail(), "q did not close the detail:\n" .. desc)
      local t = tree_win()
      assert.is_not_nil(t, "the tree is gone:\n" .. desc)
      press(t, "q")
      settle()
      desc = layout_desc()
      assert.is_nil(tree_win(), "q did not close the tree:\n" .. desc)
      assert.is_nil(any_detail(), "a beads:// window is left over:\n" .. desc)
      local back = false
      for _, w in ipairs(normal_wins()) do
        back = back or vim.api.nvim_win_get_buf(w) == b0
      end
      assert.is_true(back, "the original buffer is not back:\n" .. desc)
    end)
  end
end)
