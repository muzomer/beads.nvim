-- Bead beads_nvim-bbv: q in the detail opened from the tree closes it; q in the tree then closes the
-- tree and the original buffer is back, with no beads://<id> window left over.
--
-- Starts from what the owner has after a plain `nvim`: one window showing the empty, unnamed,
-- unmodified start buffer. In the split layout `:edit beads://<id>` in that window reuses (renames)
-- the empty buffer, so "the original buffer" must be checked as "an unnamed buffer", not by number.
-- Keys go through the real mappings (nvim_feedkeys with remap) after the detail has loaded.

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

-- <CR> on bead `id` in the tree; waits until beads://<id> has loaded ("Shown <id>" rendered) and
-- has its buffer-local q map; returns the detail window.
local function open_detail(tree, id)
  vim.api.nvim_set_current_win(tree)
  vim.api.nvim_win_set_cursor(tree, { assert(row_of(tree, id), id .. " not in the tree"), 0 })
  press(tree, "<CR>")
  local d
  assert(vim.wait(3000, function()
    d = detail_win(id)
    if not d then
      return false
    end
    local b = vim.api.nvim_win_get_buf(d)
    return vim.b[b].beads_mode == "view" and table.concat(lines_of(d), "\n"):find("Shown " .. id, 1, true) ~= nil
  end, 10), "beads://" .. id .. " never opened / loaded:\n" .. layout_desc())
  local map = vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(d), function()
    return vim.fn.maparg("q", "n", false, true)
  end)
  assert.are.equal(1, map.buffer, "no buffer-local q map in the loaded detail")
  return d
end

local CLOSERS = {
  { "q", function(d)
    press(d, "q")
  end },
  { ":bd", function(d)
    vim.api.nvim_set_current_win(d)
    vim.cmd("bd")
  end },
  { "<C-w>c", function(d)
    press(d, "<C-w>c")
  end },
}

local LAYOUTS = {
  { "full (default)", {} },
  { "split bottom", { tree = { layout = "split", position = "bottom" } } },
  { "split left", { tree = { layout = "split", position = "left" } } },
}

describe("bead bbv: closing the detail opened from the tree, then the tree", function()
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
    -- the state after a plain `nvim`: one window, the empty unnamed start buffer
    pcall(vim.cmd, "silent! tabonly!")
    pcall(vim.cmd, "silent! only!")
    vim.cmd("enew!")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if b ~= vim.api.nvim_get_current_buf() then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    assert.are.equal(1, #normal_wins())
    assert.are.equal("", vim.api.nvim_buf_get_name(0))
    assert.is_false(vim.bo.modified)
    assert.are.same({ "" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
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

  for _, layout in ipairs(LAYOUTS) do
    for _, closer in ipairs(CLOSERS) do
      it(layout[1] .. ": " .. closer[1] .. " in the detail, then q in the tree, leaves the original empty buffer", function()
        require("beads").setup(layout[2])
        local tree = open_tree()
        local d = open_detail(tree, "ch-b")

        closer[2](d)
        settle()
        local desc = layout_desc()
        assert.is_nil(any_detail(), closer[1] .. " did not close the detail:\n" .. desc)
        local t = tree_win()
        assert.is_not_nil(t, "the tree is gone after closing the detail:\n" .. desc)

        press(t, "q")
        settle()
        desc = layout_desc()
        assert.is_nil(tree_win(), "q did not close the tree:\n" .. desc)
        assert.is_nil(any_detail(), "a beads:// window is left over:\n" .. desc)
        local wins = normal_wins()
        assert.are.equal(1, #wins, "expected one window back:\n" .. desc)
        local b = vim.api.nvim_win_get_buf(wins[1])
        assert.are.equal("", vim.api.nvim_buf_get_name(b), "the original unnamed buffer is not back:\n" .. desc)
        assert.are.equal("", vim.bo[b].buftype, "the window shows a special buffer:\n" .. desc)
        assert.are.same({ "" }, vim.api.nvim_buf_get_lines(b, 0, -1, false), "the buffer is not the empty one:\n" .. desc)
      end)
    end
  end
end)
