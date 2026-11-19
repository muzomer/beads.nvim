-- Bead beads_nvim-i7f, round-2 review findings (tree.layout = "full").
--   1. blocker tree.lua:371/:414/:418/:603: the tree is the user's own window, so winfixheight /
--      winfixwidth must be set with local scope only: after toggle, <CR>, q, q the window's own and
--      the global values are what they were before (both on, both off), and the next buffer
--      opened in that window gets them too.
--      (No :split test: Neovim itself resets winfixheight/winfixwidth in the new window of :split,
--      so the leak through :split the review describes cannot show.)
--   2. nit tree.lua:964: :close / <C-w>c on the tree when the tab has other windows (a vsplit next
--      to it) shows the previous buffer in the column that held the tree (like q and like the
--      single-window case); the other window is left alone.

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


local WINFIX = { "winfixheight", "winfixwidth" }

local function winfix_of(win)
  local out = {}
  for _, o in ipairs(WINFIX) do
    out[o] = vim.wo[win][o]
  end
  return out
end

local function winfix_globals()
  local out = {}
  for _, o in ipairs(WINFIX) do
    out[o] = vim.go[o]
  end
  return out
end

describe("tree.layout = 'full' winfixheight/winfixwidth and :close findings", function()
  local tmpfile, other, orig_notify

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
    other = vim.fn.tempname() .. ".txt"
    vim.fn.writefile({ "other buffer line" }, other)
    orig_notify = vim.notify
    vim.notify = function() end
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
    vim.cmd("set winfixheight& winfixwidth&")
    pcall(vim.fn.delete, cli.get_root(), "rf")
    cli.set_root(nil)
    vim.env.PATH = orig_path
    vim.fn.delete(bin_dir, "rf")
    vim.fn.delete(fake_dir, "rf")
    pcall(vim.fn.delete, tmpfile)
    pcall(vim.fn.delete, other)
    vim.o.columns, vim.o.lines = orig_columns, orig_lines
    require("beads").setup({})
  end)

  -- 1. blocker tree.lua:371 / :414 / :418 / :603
  for _, on in ipairs({ true, false }) do
    local label = on and "on" or "off"
    it("toggle, <CR>, q, q: winfixheight/winfixwidth " .. label .. " before stay " .. label .. " (window and global)", function()
      vim.cmd(on and "set winfixheight winfixwidth" or "set nowinfixheight nowinfixwidth")
      vim.cmd.edit(vim.fn.fnameescape(tmpfile))
      local w0, b0 = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
      local want = { winfixheight = on, winfixwidth = on }
      assert.are.same(want, winfix_of(w0))
      assert.are.same(want, winfix_globals())
      local tree = open_tree()
      on_bead(tree, "ch-b")
      press(tree, "<CR>")
      local d = wait_detail("ch-b")
      settle()
      press(d, "q")
      settle()
      local t = tree_win()
      assert.is_not_nil(t, "q in the detail closed the tree:\n" .. layout_desc())
      press(t, "q")
      settle()
      local desc = layout_desc()
      assert.is_nil(tree_win(), "q did not close the tree:\n" .. desc)
      assert.is_true(vim.api.nvim_win_is_valid(w0), "the original window was closed")
      assert.are.equal(b0, vim.api.nvim_win_get_buf(w0), "the previous buffer was not restored:\n" .. desc)
      vim.api.nvim_set_current_win(w0)
      assert.are.same(want, winfix_of(w0), "window values after the tree closed")
      assert.are.same(want, winfix_globals(), "global values after the tree closed")
      vim.cmd.edit(vim.fn.fnameescape(other))
      assert.are.same(want, winfix_of(w0), "window values for the next buffer opened in the window")
      assert.are.same(want, winfix_globals(), "global values after :e other")
    end)
  end

  -- 2. nit tree.lua:964. Choice: :close / <C-w>c on the tree means "close the tree", exactly like q:
  -- the previous buffer comes back in the column that held the tree (the detail window is reused
  -- for it, as in the single-window case), the detail is gone and the user's other window stays.
  local closers = {
    [":close"] = function(t)
      vim.api.nvim_set_current_win(t)
      vim.cmd("close")
    end,
    ["<C-w>c"] = function(t)
      press(t, "<C-w>c")
    end,
  }
  for _, name in ipairs({ ":close", "<C-w>c" }) do
    it(name .. " on the tree next to another window shows the previous buffer where the tree was", function()
      vim.cmd.edit(vim.fn.fnameescape(other))
      local bo = vim.api.nvim_get_current_buf()
      vim.cmd("vsplit")
      local wo = vim.fn.win_getid(vim.fn.winnr("l"))
      vim.cmd.edit(vim.fn.fnameescape(tmpfile))
      local w0, b0 = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
      assert.are_not.equal(w0, wo)
      local col0 = vim.api.nvim_win_get_position(w0)[2]
      local tree = open_tree()
      assert.are.equal(w0, tree, "the tree is not in the current window:\n" .. layout_desc())
      on_bead(tree, "ch-b")
      press(tree, "<CR>")
      wait_detail("ch-b")
      settle()
      closers[name](tree_win())
      settle()
      local desc = layout_desc()
      assert.is_nil(tree_win(), "the tree is still shown:\n" .. desc)
      assert.is_nil(any_detail(), "the detail is still shown:\n" .. desc)
      assert.are.equal(2, #normal_wins(), "expected the user's two windows back:\n" .. desc)
      assert.is_true(vim.api.nvim_win_is_valid(wo), "the other window was closed:\n" .. desc)
      assert.are.equal(bo, vim.api.nvim_win_get_buf(wo), "the other window changed buffer:\n" .. desc)
      local back
      for _, w in ipairs(normal_wins()) do
        if w ~= wo and vim.api.nvim_win_get_buf(w) == b0 then
          back = w
        end
      end
      assert.is_not_nil(back, "the previous buffer is not shown where the tree was:\n" .. desc)
      assert.are.equal(col0, vim.api.nvim_win_get_position(back)[2], "previous buffer not in the tree's column:\n" .. desc)
    end)
  end
end)
