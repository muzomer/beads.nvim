-- Shared setup for the detail-buffer Questions specs (bead beads_nvim-4gx.4).
-- `bd` is replaced by a shell script on PATH (test double for the external binary). Every call is
-- logged one per line to <dir>/calls.log. Dispatch:
--   any call containing "--label human" -> <dir>/human.json if it exists, else "[]"
--   show    -> <dir>/bead.json (one bead fx-1, "Questions test")
--   list    -> "[]"
--   other   -> "{}"
-- Stored question threads live in <dir>/.beads-nvim/questions.json (beads.questions.store).
local cli = require("beads.cli")

local M = {}

M.repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
M.TITLE = "Questions test"

local state = {}

function M.dir()
  return state.dir
end

function M.bead(extra)
  local b = {
    id = "fx-1",
    title = M.TITLE,
    description = "desc",
    acceptance_criteria = "old ac",
    status = "open",
    priority = 2,
    issue_type = "task",
    created_at = "2026-11-17T16:01:12Z",
    updated_at = "2026-11-17T16:01:12Z",
  }
  for k, v in pairs(extra or {}) do
    b[k] = v
  end
  return b
end

function M.write_bead(extra)
  vim.fn.writefile({ vim.json.encode({ M.bead(extra) }) }, state.dir .. "/bead.json")
end

-- beads returned for `bd list --label human`.
function M.write_human(beads)
  vim.fn.writefile({ vim.json.encode(beads) }, state.dir .. "/human.json")
end

function M.log()
  local p = state.dir .. "/calls.log"
  return vim.fn.filereadable(p) == 1 and vim.fn.readfile(p) or {}
end

-- Number of logged calls containing the plain substring s.
function M.count(s)
  local n = 0
  for _, l in ipairs(M.log()) do
    if l:find(s, 1, true) then
      n = n + 1
    end
  end
  return n
end

function M.wait_for(pred, what, timeout)
  assert(vim.wait(timeout or 3000, function()
    local ok, v = pcall(pred)
    return ok and v
  end, 10), "timed out waiting for " .. what)
end

function M.setup()
  state.orig_path = vim.env.PATH
  state.orig_cwd = vim.fn.getcwd()
  state.orig_select = vim.ui.select
  state.orig_input = vim.ui.input
  state.orig_notify = vim.notify
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  state.dir = vim.fn.resolve(d)
  local q = vim.fn.shellescape
  vim.fn.writefile({
    "#!/bin/sh",
    'echo "$*" >> ' .. q(state.dir .. "/calls.log"),
    'case "$*" in',
    '  *"--label human"*) if [ -f ' .. q(state.dir .. "/human.json") .. " ]; then cat " .. q(
      state.dir .. "/human.json"
    ) .. "; else echo '[]'; fi; exit 0;;",
    "esac",
    'for a in "$@"; do',
    '  case "$a" in',
    "    show) cat " .. q(state.dir .. "/bead.json") .. "; exit 0;;",
    "    list) echo '[]'; exit 0;;",
    "  esac",
    "done",
    "echo '{}'",
  }, state.dir .. "/bd")
  vim.fn.setfperm(state.dir .. "/bd", "rwxr-xr-x")
  M.write_bead()
  vim.env.PATH = state.dir .. ":" .. state.orig_path
  vim.cmd.cd(vim.fn.fnameescape(state.dir))
  cli.set_root(state.dir)
  if vim.fn.exists("#BeadsDetail#BufReadCmd") == 0 then
    vim.cmd.source(M.repo .. "/plugin/beads.lua")
  end
end

function M.teardown()
  pcall(vim.cmd, "stopinsert")
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  pcall(vim.cmd, "silent! diffoff!")
  pcall(vim.cmd, "silent! only!")
  pcall(vim.cmd, "silent! %bwipeout!")
  vim.ui.select = state.orig_select
  vim.ui.input = state.orig_input
  vim.notify = state.orig_notify
  vim.env.PATH = state.orig_path
  vim.cmd.cd(vim.fn.fnameescape(state.orig_cwd))
  cli.set_root(nil)
  vim.fn.delete(state.dir, "rf")
end

-- Opens beads://fx-1 in the current window and waits for the load.
function M.open_detail()
  vim.cmd("edit beads://fx-1")
  local buf = vim.api.nvim_get_current_buf()
  M.wait_for(function()
    return require("beads.views.detail").snapshot(buf) ~= nil
      and vim.tbl_contains(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "# " .. M.TITLE)
      and not vim.bo[buf].modified
  end, "detail buffer load")
  return buf
end

-- 1-based line number of the first line after "## Questions" containing text, or nil.
function M.question_line(buf, text)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local start
  for i, l in ipairs(lines) do
    if l == "## Questions" then
      start = i
    elseif start and l:find(text, 1, true) then
      return i
    end
  end
end

-- Waits until the Questions section shows a line containing text; returns its line number.
function M.wait_question(buf, text)
  local n
  M.wait_for(function()
    n = M.question_line(buf, text)
    return n ~= nil
  end, "Questions line containing '" .. text .. "'")
  return n
end

function M.press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

local function wins()
  local s = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    s[w] = true
  end
  return s
end

-- Presses keys; returns the floating window that appeared (or nil).
function M.press_for_float(keys)
  local before = wins()
  M.press(keys)
  local found
  vim.wait(1000, function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if not before[w] and vim.api.nvim_win_get_config(w).relative ~= "" then
        found = w
        return true
      end
    end
    return false
  end, 10)
  pcall(vim.cmd, "stopinsert")
  return found
end

-- Puts the cursor on the Questions line containing text and presses <CR>; returns the float.
function M.open_thread(buf, text)
  local n = M.wait_question(buf, text)
  local win = vim.fn.bufwinid(buf)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { n, 0 })
  local f = M.press_for_float("<CR>")
  assert(f, "<CR> on the thread line opened no float")
  vim.api.nvim_set_current_win(f)
  return f
end

function M.float_text(w)
  return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), "\n")
end

-- Presses r (reply) in the current thread float and supplies text, whether the reply is asked
-- through vim.ui.input or through an input float (filled, then submitted with <C-s>).
function M.reply(text)
  local asked = false
  vim.ui.input = function(_, cb)
    asked = true
    cb(text)
  end
  local f = M.press_for_float("r")
  if not asked and f then
    vim.api.nvim_set_current_win(f)
    local b = vim.api.nvim_win_get_buf(f)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { text })
    M.press("<C-s>")
  end
  return asked or f ~= nil
end

-- vim.ui.select stub: picks the item whose text contains "apply" (case-insensitive), else the first.
function M.select_apply()
  vim.ui.select = function(items, opts, on_choice)
    local fmt = (opts or {}).format_item or tostring
    for _, it in ipairs(items) do
      if tostring(fmt(it)):lower():find("apply", 1, true) then
        return on_choice(it)
      end
    end
    on_choice(items[1])
  end
end

-- Buffer-local map for lhs in mode, or nil.
function M.buf_map(buf, mode, lhs)
  local want = vim.fn.keytrans(vim.keycode(lhs))
  for _, km in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if vim.fn.keytrans(vim.keycode(km.lhs)) == want then
      return km
    end
  end
end

-- Captures vim.notify calls into the returned list of { msg, level }.
function M.capture_notify()
  local got = {}
  vim.notify = function(msg, level)
    got[#got + 1] = { msg = tostring(msg), level = level }
  end
  return got
end

return M
