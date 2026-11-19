-- Bead beads_nvim-bbv finding (tree.lua:345): a start buffer that ALREADY was beads://<id> before
-- the tree opened (:e beads://bl-d / :Beads show bl-d) is the user's buffer: closing the tree must
-- show it again (same buffer, still loaded), not a fresh empty buffer that leaves it hidden.
-- Only a name gained after the tree opened (the detail's :edit reusing the start buffer) is skipped.

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

local function items()
  return {
    bead("ep-a", "Epic alpha", { issue_type = "epic", priority = 1 }),
    bead("ch-b", "Child bravo", {
      parent = "ep-a",
      dependencies = { { issue_id = "ch-b", depends_on_id = "ep-a", type = "parent-child" } },
    }),
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

local function normal_wins()
  local out = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(w).relative == "" then
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

local function layout_desc()
  local parts = {}
  for _, w in ipairs(normal_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    parts[#parts + 1] = ("win %d buf %d %q ft %s"):format(w, b, vim.api.nvim_buf_get_name(b), vim.bo[b].filetype)
  end
  return table.concat(parts, "\n")
end

local function settle()
  vim.wait(200, function()
    return false
  end, 10)
end

local function row_of(win, id)
  for i, l in ipairs(lines_of(win)) do
    if l:find(id, 1, true) then
      return i
    end
  end
end

local function open_tree()
  vim.cmd("Beads tree")
  local tree
  assert(vim.wait(3000, function()
    tree = tree_win()
    return tree ~= nil and row_of(tree, "bl-d") ~= nil and row_of(tree, "ch-b") ~= nil
  end, 10), ":Beads tree never rendered:\n" .. layout_desc())
  vim.api.nvim_win_call(tree, function()
    vim.cmd("silent! normal! zR")
  end)
  return tree
end

-- Presses keys in `win` through the real (remappable) mappings.
local function press(win, keys)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false)
end

-- Waits until the buffer in the current window is beads://<id>, loaded in view mode.
local function wait_loaded(id)
  local buf
  assert(vim.wait(3000, function()
    local w = detail_win(id)
    if not w then
      return false
    end
    buf = vim.api.nvim_win_get_buf(w)
    return vim.b[buf].beads_mode == "view" and table.concat(lines_of(w), "\n"):find("Shown " .. id, 1, true) ~= nil
  end, 10), "beads://" .. id .. " never opened / loaded:\n" .. layout_desc())
  return buf
end

-- <CR> on bead `id` in the tree; waits until beads://<id> has loaded; returns the detail window.
local function open_detail(tree, id)
  vim.api.nvim_set_current_win(tree)
  vim.api.nvim_win_set_cursor(tree, { assert(row_of(tree, id), id .. " not in the tree"), 0 })
  press(tree, "<CR>")
  wait_loaded(id)
  return detail_win(id)
end

local function main_win()
  for _, w in ipairs(normal_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype ~= "beads-tree" then
      return w
    end
  end
end

-- The start: one window showing beads://bl-d, as after :e beads://bl-d (or :Beads show bl-d).
local function start_on_detail()
  vim.cmd("edit beads://bl-d")
  local b = wait_loaded("bl-d")
  assert.are.equal(b, vim.api.nvim_get_current_buf())
  assert.are.equal(1, #normal_wins())
  return b
end

-- Exactly one window left, showing the original beads://bl-d buffer, still loaded with its content.
local function assert_start_back(start_buf)
  local desc = layout_desc()
  assert.is_nil(tree_win(), "the tree is still open:\n" .. desc)
  local wins = normal_wins()
  assert.are.equal(1, #wins, "expected one window back:\n" .. desc)
  local b = vim.api.nvim_win_get_buf(wins[1])
  assert.are.equal(start_buf, b, "the window does not show the original beads://bl-d buffer:\n" .. desc)
  assert.are.equal("beads://bl-d", vim.api.nvim_buf_get_name(b), desc)
  assert.is_truthy(table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"):find("Shown bl-d", 1, true), "beads://bl-d lost its content:\n" .. desc)
end

describe("bead bbv finding: closing the tree opened from a beads://<id> buffer gives it back", function()
  local orig_notify

  before_each(function()
    if vim.fn.exists(":Beads") ~= 2 then
      vim.cmd.source(plugin_root .. "/plugin/beads.lua")
    end
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
    orig_notify = vim.notify
    vim.notify = function() end
    pcall(vim.cmd, "silent! tabonly!")
    pcall(vim.cmd, "silent! only!")
    vim.cmd("enew!")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if b ~= vim.api.nvim_get_current_buf() then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    assert.are.equal(1, #normal_wins())
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
    pcall(vim.fn.delete, cli.get_root(), "rf")
    cli.set_root(nil)
    vim.env.PATH = orig_path
    vim.fn.delete(bin_dir, "rf")
    vim.fn.delete(fake_dir, "rf")
    vim.o.columns, vim.o.lines = orig_columns, orig_lines
    require("beads").setup({})
  end)

  describe("full layout", function()
    it("q in the tree right after opening it: beads://bl-d is back", function()
      require("beads").setup({ tree = { layout = "full" } })
      local start_buf = start_on_detail()
      local tree = open_tree()
      assert.are.equal(1, #normal_wins(), "full layout should replace the window:\n" .. layout_desc())
      press(tree, "q")
      settle()
      assert_start_back(start_buf)
    end)

    it("<CR> on ch-b opens the detail, q in the tree: beads://bl-d is back", function()
      require("beads").setup({ tree = { layout = "full" } })
      local start_buf = start_on_detail()
      local tree = open_tree()
      open_detail(tree, "ch-b")
      press(tree, "q")
      settle()
      assert_start_back(start_buf)
    end)

    it("<CR> on ch-b opens the detail, :close in the tree: beads://bl-d is back", function()
      require("beads").setup({ tree = { layout = "full" } })
      local start_buf = start_on_detail()
      local tree = open_tree()
      open_detail(tree, "ch-b")
      vim.api.nvim_set_current_win(tree)
      vim.cmd("close")
      settle()
      assert_start_back(start_buf)
    end)
  end)

  for _, pos in ipairs({ "bottom", "left" }) do
    describe("split " .. pos, function()
      local cfg = { tree = { layout = "split", position = pos } }

      it("q in the tree: the main window still shows beads://bl-d (passes already)", function()
        require("beads").setup(cfg)
        local start_buf = start_on_detail()
        local tree = open_tree()
        press(tree, "q")
        settle()
        assert_start_back(start_buf)
      end)

      it(":close in the tree: the main window still shows beads://bl-d (passes already)", function()
        require("beads").setup(cfg)
        local start_buf = start_on_detail()
        local tree = open_tree()
        vim.api.nvim_set_current_win(tree)
        vim.cmd("close")
        settle()
        assert_start_back(start_buf)
      end)

      it("main window closed, q in the tree (last window): beads://bl-d is back", function()
        require("beads").setup(cfg)
        local start_buf = start_on_detail()
        local tree = open_tree()
        local main = assert(main_win(), "no main window:\n" .. layout_desc())
        vim.api.nvim_set_current_win(main)
        vim.cmd("close")
        settle()
        assert.are.equal(1, #normal_wins(), "the main window did not close:\n" .. layout_desc())
        assert.are.equal(tree, tree_win())
        press(tree, "q")
        settle()
        assert_start_back(start_buf)
      end)
    end)
  end
end)
