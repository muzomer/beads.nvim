-- Shared setup for the gd peek specs (bead beads_nvim-4u9.15).
-- `bd` is replaced by a shell script on PATH (test double): `show <id>` prints show_<id>.json,
-- `list --label ...` (the human-questions lookup) prints [], anything else prints list.json.
--
-- Fixture (one id prefix "pk", as a real project):
--   pk-a1x   epic "Alpha epic"
--   pk-a1x.1 child of pk-a1x, "Dotted child"
--   pk-b2y   child of pk-a1x, blocked_by pk-c3z, description mentions pk-d4w and pk-a1x.1,
--            a word that is no bead ("zebra") and an id-shaped word that is no bead (pk-zz9)
--   pk-c3z   "Charlie blocker", description mentions pk-d4w
--   pk-d4w   "Delta notes", description mentions pk-c3z
local cli = require("beads.cli")
local store = require("beads.store")

local M = {}

M.plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

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

function M.items()
  return {
    bead("pk-a1x", "Alpha epic", { issue_type = "epic", priority = 1 }),
    bead("pk-a1x.1", "Dotted child", {
      parent = "pk-a1x",
      dependencies = { { issue_id = "pk-a1x.1", depends_on_id = "pk-a1x", type = "parent-child" } },
    }),
    bead("pk-b2y", "Bravo work", {
      parent = "pk-a1x",
      dependencies = {
        { issue_id = "pk-b2y", depends_on_id = "pk-a1x", type = "parent-child" },
        { issue_id = "pk-b2y", depends_on_id = "pk-c3z", type = "blocks" },
      },
      description = table.concat({
        "Body of pk-b2y",
        "See pk-d4w, it explains the plan.",
        "Also pk-a1x.1 matters.",
        "",
        "zebra first",
        "",
        "Unknown pk-zz9 here.",
        "",
        "zebra second and pk-zz9 again",
      }, "\n"),
    }),
    bead("pk-c3z", "Charlie blocker", { description = "Body of pk-c3z\nDepends on pk-d4w for context." }),
    bead("pk-d4w", "Delta notes", { description = "Body of pk-d4w\nCompare with pk-c3z please." }),
  }
end

M.ALL_IDS = { "pk-a1x", "pk-a1x.1", "pk-b2y", "pk-c3z", "pk-d4w" }

function M.set_list(items)
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

M.notes = {}

function M.setup(opts)
  if vim.fn.exists(":Beads") ~= 2 then
    vim.cmd.source(M.plugin_root .. "/plugin/beads.lua")
  end
  require("beads").setup(vim.tbl_deep_extend("keep", opts or {}, { tree = { layout = "split" } }))
  state.orig_columns = vim.o.columns
  state.orig_lines = vim.o.lines
  vim.o.columns = 200
  vim.o.lines = 50
  state.orig_path = vim.env.PATH
  state.orig_notify = vim.notify
  state.orig_input = vim.ui.input
  M.notes = {}
  vim.notify = function(msg)
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
  M.set_list(M.items())
  M.prefill()
  pcall(vim.cmd, "messages clear")
end

function M.root()
  return cli.get_root()
end

function M.close_floats()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_config(w).relative ~= "" then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
end

function M.teardown()
  M.close_floats()
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

function M.lines_of(win)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

function M.text_of(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return "<no window>"
  end
  return table.concat(M.lines_of(win), "\n")
end

local function is_float(w)
  return vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_config(w).relative ~= ""
end

-- The bead id a window shows (from its rendered "id: <id>" frontmatter line), or nil.
function M.shown_bead(win)
  for _, l in ipairs(M.lines_of(win)) do
    local id = l:match("^id: (%S+)%s*$")
    if id then
      return id
    end
  end
end

-- Peek floats: floating windows whose buffer shows a rendered bead (an "id: <id>" line).
function M.peeks()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if is_float(w) and M.shown_bead(w) then
      out[#out + 1] = w
    end
  end
  return out
end

function M.peek_of(id)
  for _, w in ipairs(M.peeks()) do
    if M.shown_bead(w) == id then
      return w
    end
  end
end

function M.floats()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if is_float(w) then
      out[#out + 1] = w
    end
  end
  return out
end

function M.describe_floats()
  local t = {}
  for _, w in ipairs(M.floats()) do
    t[#t + 1] = ("win %d: %s"):format(w, tostring(M.shown_bead(w) or (M.lines_of(w)[1] or "")))
  end
  return "{" .. table.concat(t, "; ") .. "}"
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

-- Puts the cursor of win on `text` (first line containing it, `skip` chars into the match).
function M.cursor_on(win, text, skip, from_row)
  local lines = M.lines_of(win)
  for i = from_row or 1, #lines do
    local s = lines[i]:find(text, 1, true)
    if s then
      vim.api.nvim_win_set_cursor(win, { i, s - 1 + (skip or 0) })
      return i
    end
  end
  error(("text %q not found in window %d:\n%s"):format(text, win, M.text_of(win)), 0)
end

-- Presses keys in win and waits for a peek float showing id; returns it.
function M.peek(win, keys, id)
  M.press(win, keys)
  local f
  vim.wait(3000, function()
    f = M.peek_of(id)
    return f ~= nil and M.text_of(f):find("Body of " .. id, 1, true) ~= nil
  end, 10)
  assert(f, ("%s opened no peek float showing %s; floats: %s"):format(keys, id, M.describe_floats()))
  return f
end

function M.shown_id(win)
  return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)):match("^beads://(.+)$")
end

function M.open_tree()
  local before = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    before[w] = true
  end
  vim.cmd("Beads tree")
  local tree
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if not before[w] then
      tree = w
    end
  end
  assert(tree, ":Beads tree opened no window")
  assert(vim.wait(3000, function()
    return vim.api.nvim_win_is_valid(tree) and M.text_of(tree):find("pk-d4w", 1, true) ~= nil
  end, 10), "tree never rendered:\n" .. M.text_of(tree))
  vim.api.nvim_win_call(tree, function()
    vim.cmd("silent! normal! zR")
  end)
  return tree
end

function M.main_win(tree)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= tree and vim.api.nvim_win_get_config(w).relative == "" then
      return w
    end
  end
end

function M.buf_map(buf, mode, lhs)
  local want = vim.fn.keytrans(vim.keycode(lhs))
  for _, km in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if vim.fn.keytrans(vim.keycode(km.lhs)) == want then
      return km
    end
  end
end

function M.hl_on_line(buf, row1, group)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, { row1 - 1, 0 }, { row1 - 1, -1 }, { details = true })) do
    if (m[4] or {}).hl_group == group then
      return true
    end
  end
  return false
end

return M
