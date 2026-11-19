-- Shared setup for the detail ]b / [b specs (bead beads_nvim-4u9.14).
-- `bd` is replaced by a shell script on PATH (test double): `show <id>` prints show_<id>.json,
-- `list --label ...` (the human-questions lookup) prints [], anything else prints list.json.
--
-- Fixture (ch-b is closed):
--   ep-a (epic, p1) > { ch-b (closed), ep-s (epic) > { gc-x, gc-y } }
--   bl-d (p2)
--   ep-t (epic, p3) > { tc-1, tc-2 }
-- Default tree order (sort priority, no filter, closed hidden):
--   ep-a, ep-s, gc-x, gc-y, bl-d, ep-t, tc-1, tc-2
local cli = require("beads.cli")
local store = require("beads.store")

local M = {}

M.plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

M.DEFAULT_ORDER = { "ep-a", "ep-s", "gc-x", "gc-y", "bl-d", "ep-t", "tc-1", "tc-2" }
M.CLOSED_SHOWN_ORDER = { "ep-a", "ch-b", "ep-s", "gc-x", "gc-y", "bl-d", "ep-t", "tc-1", "tc-2" }
M.ID_SORT_ORDER = { "bl-d", "ep-a", "ep-s", "gc-x", "gc-y", "ep-t", "tc-1", "tc-2" }
M.EPIC_FILTER_ORDER = { "ep-a", "ep-s", "ep-t" }
M.ALL_IDS = { "ep-a", "ch-b", "ep-s", "gc-x", "gc-y", "bl-d", "ep-t", "tc-1", "tc-2" }

local FAKE_BD = [[#!/bin/sh
prev=""
for a in "$@"; do
  if [ "$prev" = "show" ]; then
    if [ -f "$FAKE_DIR/show_$a.json" ]; then
      cat "$FAKE_DIR/show_$a.json"
    else
      echo "[]"
    fi
    exit 0
  fi
  if [ "$a" = "--label" ]; then
    echo "[]"
    exit 0
  fi
  prev="$a"
done
cat "$FAKE_DIR/list.json"
]]

local state = {}

local function bead(id, title, extra)
  local b = {
    id = id,
    title = title,
    status = "open",
    priority = 2,
    issue_type = "task",
    description = "Body of " .. id,
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

function M.items()
  return {
    bead("ep-a", "Epic alpha", { issue_type = "epic", priority = 1 }),
    child_of("ch-b", "ep-a", "Child bravo", { status = "closed" }),
    child_of("ep-s", "ep-a", "Sub epic", { issue_type = "epic" }),
    child_of("gc-x", "ep-s", "Grandchild xray"),
    child_of("gc-y", "ep-s", "Grandchild yankee"),
    bead("bl-d", "Leaf delta"),
    bead("ep-t", "Epic tango", { issue_type = "epic", priority = 3 }),
    child_of("tc-1", "ep-t", "Tango one"),
    child_of("tc-2", "ep-t", "Tango two"),
  }
end

local function set_list(items)
  vim.fn.writefile({ vim.json.encode(items) }, state.fake_dir .. "/list.json")
  for _, b in ipairs(items) do
    vim.fn.writefile({ vim.json.encode({ b }) }, state.fake_dir .. "/show_" .. b.id .. ".json")
  end
end

function M.prefill()
  local done = false
  store.refresh(cli.get_root(), function()
    done = true
  end)
  assert(vim.wait(3000, function()
    return done
  end, 10), "store refresh never completed")
end

-- Messages: vim.notify is replaced by a recorder; :messages is also checked.
M.notes = {}

function M.setup(opts)
  if vim.fn.exists(":Beads") ~= 2 then
    vim.cmd.source(M.plugin_root .. "/plugin/beads.lua")
  end
  require("beads").setup(vim.tbl_deep_extend("keep", opts or {}, { tree = { layout = "split" } }))
  state.orig_columns = vim.o.columns
  state.orig_lines = vim.o.lines
  vim.o.columns = 200
  vim.o.lines = 40
  state.orig_path = vim.env.PATH
  state.orig_notify = vim.notify
  state.orig_input = vim.ui.input
  M.notes = {}
  vim.notify = function(msg, level, o)
    M.notes[#M.notes + 1] = tostring(msg)
  end
  state.bin_dir = vim.fn.tempname()
  vim.fn.mkdir(state.bin_dir, "p")
  vim.fn.writefile(vim.split(FAKE_BD, "\n"), state.bin_dir .. "/bd")
  vim.fn.setfperm(state.bin_dir .. "/bd", "rwxr-xr-x")
  state.fake_dir = vim.fn.tempname()
  vim.fn.mkdir(state.fake_dir, "p")
  vim.env.FAKE_DIR = state.fake_dir
  vim.env.PATH = state.bin_dir .. ":" .. state.orig_path
  local r = vim.fn.tempname()
  vim.fn.mkdir(r, "p")
  cli.set_root(r)
  set_list(M.items())
  M.prefill()
  pcall(vim.cmd, "messages clear")
end

function M.all_flashes()
  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    for _, r in ipairs(M.hl_rows(b, "BeadsFlash")) do
      out[#out + 1] = b .. ":" .. r
    end
  end
  return out
end

function M.teardown()
  -- let pending flash-clear timers fire before buffers go away
  vim.wait(500, function()
    return #M.all_flashes() == 0
  end, 10)
  pcall(vim.cmd, "stopinsert")
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
  vim.notify = state.orig_notify
  vim.ui.input = state.orig_input
  vim.env.PATH = state.orig_path
  vim.fn.delete(state.bin_dir, "rf")
  vim.fn.delete(state.fake_dir, "rf")
  vim.o.columns = state.orig_columns
  vim.o.lines = state.orig_lines
  require("beads").setup({})
end

function M.wins()
  return vim.api.nvim_tabpage_list_wins(0)
end

function M.lines_of(win)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

function M.row_of(win, id)
  for i, l in ipairs(M.lines_of(win)) do
    local s = l:find(id, 1, true)
    if s and not l:sub(1, s - 1):find("blocked", 1, true) then
      return i
    end
  end
  return nil
end

function M.dump(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return "<no window>"
  end
  return table.concat(M.lines_of(win), "\n")
end

-- Ids of the fixture shown in the tree, top to bottom.
function M.tree_order(tree)
  local rows = {}
  for _, id in ipairs(M.ALL_IDS) do
    local r = M.row_of(tree, id)
    if r then
      rows[#rows + 1] = { r, id }
    end
  end
  table.sort(rows, function(a, b)
    return a[1] < b[1]
  end)
  return vim.tbl_map(function(x)
    return x[2]
  end, rows)
end

function M.hl_rows(buf, group)
  local set = {}
  if not vim.api.nvim_buf_is_valid(buf) then
    return {}
  end
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    local d = m[4] or {}
    if d.hl_group == group or d.line_hl_group == group then
      set[m[2] + 1] = true
    end
  end
  local rows = vim.tbl_keys(set)
  table.sort(rows)
  return rows
end

function M.current_rows(tree)
  return M.hl_rows(vim.api.nvim_win_get_buf(tree), "BeadsCurrent")
end

function M.wait_current(tree, id)
  return vim.wait(2000, function()
    local r = M.row_of(tree, id)
    local rows = M.current_rows(tree)
    return r ~= nil and #rows == 1 and rows[1] == r
  end, 10)
end

function M.current_msg(tree, id)
  return ("expected exactly %s's row (%s) to carry BeadsCurrent, got rows {%s}:\n%s"):format(
    id,
    tostring(M.row_of(tree, id)),
    table.concat(M.current_rows(tree), ","),
    M.dump(tree)
  )
end

function M.flash_on_cursor(win)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  return vim.tbl_contains(M.hl_rows(vim.api.nvim_win_get_buf(win), "BeadsFlash"), row)
end

function M.open_tree()
  local before = {}
  for _, w in ipairs(M.wins()) do
    before[w] = true
  end
  vim.cmd("Beads tree")
  local tree
  for _, w in ipairs(M.wins()) do
    if not before[w] then
      tree = w
    end
  end
  assert(tree, ":Beads tree opened no window")
  assert(vim.wait(3000, function()
    return vim.api.nvim_win_is_valid(tree)
      and M.row_of(tree, "tc-2") ~= nil
      and (M.lines_of(tree)[1] or ""):find("^beads ·") ~= nil
  end, 10), "tree never rendered:\n" .. M.dump(tree))
  vim.api.nvim_win_call(tree, function()
    vim.cmd("silent! normal! zR")
  end)
  return tree
end

-- The non-tree, non-floating window of this tabpage.
function M.main_win(tree)
  for _, w in ipairs(M.wins()) do
    if w ~= tree and vim.api.nvim_win_get_config(w).relative == "" then
      return w
    end
  end
end

function M.detail_loaded(buf, id)
  return vim.api.nvim_buf_is_valid(buf)
    and table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("Body of " .. id, 1, true) ~= nil
end

function M.edit_in(win, id)
  vim.api.nvim_set_current_win(win)
  vim.cmd.edit(vim.fn.fnameescape("beads://" .. id))
  local buf = vim.api.nvim_get_current_buf()
  assert(vim.wait(3000, function()
    return M.detail_loaded(buf, id)
  end, 10), "detail beads://" .. id .. " never loaded")
  return buf
end

function M.press(win, keys)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

function M.shown_id(win)
  local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
  return name:match("^beads://(.+)$")
end

-- Waits until `win` shows the loaded detail of `id`; returns true on success.
function M.wait_shown(win, id)
  return vim.wait(3000, function()
    return vim.api.nvim_win_is_valid(win)
      and M.shown_id(win) == id
      and M.detail_loaded(vim.api.nvim_win_get_buf(win), id)
  end, 10)
end

function M.shown_msg(win, id)
  return ("expected window %d to show the loaded beads://%s, it shows %s"):format(
    win,
    id,
    vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) or "<closed>"
  )
end

-- Presses keys in win and asserts it lands on the loaded detail of `id`, still in VIEW mode.
function M.jump(win, keys, id)
  local nwins = #M.wins()
  M.press(win, keys)
  assert(M.wait_shown(win, id), keys .. ": " .. M.shown_msg(win, id))
  assert.are.equal(win, vim.api.nvim_get_current_win(), keys .. ": focus left the detail window")
  assert.are.equal(nwins, #M.wins(), keys .. ": the jump changed the number of windows")
  assert.are.equal(
    "view",
    vim.b[vim.api.nvim_win_get_buf(win)].beads_mode,
    keys .. ": the detail is not in VIEW mode after the jump"
  )
end

-- True when a message containing `text` was shown (vim.notify or :messages).
function M.said(text)
  for _, m in ipairs(M.notes) do
    if m:find(text, 1, true) then
      return true
    end
  end
  local ok, out = pcall(vim.api.nvim_exec2, "messages", { output = true })
  return ok and (out.output or ""):find(text, 1, true) ~= nil
end

function M.buf_map(buf, mode, lhs)
  local want = vim.fn.keytrans(vim.keycode(lhs))
  for _, km in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if vim.fn.keytrans(vim.keycode(km.lhs)) == want then
      return km
    end
  end
end

return M
