-- Shared setup for the view/edit mode specs (bead beads_nvim-4gx.8).
-- `bd` is replaced by a shell script on PATH (test double for the external binary). Every call is
-- logged one per line to <dir>/calls.log. Dispatch on the first matching subcommand:
--   show    -> <dir>/bead.json (one bead fx-1, "Mode test")
--   list    -> "[]"
--   update  -> exit 1 with "boom" on stderr when <dir>/fail exists, else "{}"
--   other   -> "{}"
local cli = require("beads.cli")

local M = {}

M.repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
M.TITLE = "Mode test"

local state = {}

function M.bead(extra)
  local b = {
    id = "fx-1",
    title = M.TITLE,
    description = "desc",
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

function M.set_fail(on)
  if on then
    vim.fn.writefile({ "1" }, state.dir .. "/fail")
  else
    vim.fn.delete(state.dir .. "/fail")
  end
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
  assert(vim.wait(timeout or 5000, function()
    local ok, v = pcall(pred)
    return ok and v
  end, 10), "timed out waiting for " .. what)
end

function M.setup()
  state.orig_path = vim.env.PATH
  state.orig_cwd = vim.fn.getcwd()
  state.orig_select = vim.ui.select
  state.orig_input = vim.ui.input
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  state.dir = vim.fn.resolve(d)
  local q = vim.fn.shellescape
  vim.fn.writefile({
    "#!/bin/sh",
    'echo "$*" >> ' .. q(state.dir .. "/calls.log"),
    'for a in "$@"; do',
    '  case "$a" in',
    "    show) cat " .. q(state.dir .. "/bead.json") .. "; exit 0;;",
    "    list) echo '[]'; exit 0;;",
    "    update) if [ -f " .. q(state.dir .. "/fail") .. " ]; then echo boom >&2; exit 1; fi; echo '{}'; exit 0;;",
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
  pcall(vim.cmd, "silent! only!")
  pcall(vim.cmd, "silent! %bwipeout!")
  vim.ui.select = state.orig_select
  vim.ui.input = state.orig_input
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

function M.float_text(w)
  return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), "\n")
end

-- Title of a float as plain text (nvim_win_get_config returns a list of chunks).
function M.float_title(w)
  local t = vim.api.nvim_win_get_config(w).title
  if type(t) == "table" then
    local parts = {}
    for _, c in ipairs(t) do
      parts[#parts + 1] = type(c) == "table" and c[1] or tostring(c)
    end
    return table.concat(parts)
  end
  return tostring(t or "")
end

function M.close_float(w)
  if w and vim.api.nvim_win_is_valid(w) then
    pcall(vim.api.nvim_win_close, w, true)
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

function M.has_line(buf, line)
  return vim.tbl_contains(vim.api.nvim_buf_get_lines(buf, 0, -1, false), line)
end

-- Replaces the title line of buf (must be modifiable).
function M.edit_title(buf, new)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, l in ipairs(lines) do
    if l == "# " .. M.TITLE then
      vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { "# " .. new })
      return
    end
  end
  error("title line not found")
end

function M.is_view(buf)
  return vim.bo[buf].modifiable == false and vim.b[buf].beads_mode == "view"
end

function M.is_edit(buf)
  return vim.bo[buf].modifiable == true and vim.b[buf].beads_mode == "edit"
end

return M
