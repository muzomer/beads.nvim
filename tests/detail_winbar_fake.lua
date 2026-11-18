-- Shared setup for the detail winbar / highlighting specs (bead beads_nvim-4u9.8).
-- `bd` is replaced by a shell script on PATH (test double for the external binary). Every call is
-- logged one per line to <dir>/calls.log. Dispatch on the first matching subcommand:
--   show   -> <dir>/bead.json  (a one-element array with the bead)
--   list   -> <dir>/list.json  (the same bead, so store refreshes deliver it)
--   ready  -> "[]"
--   other  -> "{}"
local cli = require("beads.cli")

local M = {}

M.repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
M.ID = "wb-1"
M.TITLE = "Winbar test"

local state = {}

function M.dir()
  return state.dir
end

function M.bead(extra)
  local b = {
    id = M.ID,
    title = M.TITLE,
    description = "desc",
    status = "open",
    priority = 2,
    issue_type = "task",
    created_at = "2026-11-10T10:00:00Z",
    updated_at = "2026-11-10T10:00:00Z",
  }
  for k, v in pairs(extra or {}) do
    b[k] = v
  end
  return b
end

-- Writes the bead served by `bd show` and `bd list`.
function M.write_bead(extra)
  local b = M.bead(extra)
  vim.fn.writefile({ vim.json.encode({ b }) }, state.dir .. "/bead.json")
  vim.fn.writefile({ vim.json.encode({ b }) }, state.dir .. "/list.json")
end

function M.wait_for(pred, what, timeout)
  assert(vim.wait(timeout or 5000, function()
    local ok, v = pcall(pred)
    return ok and v
  end, 10), "timed out waiting for " .. what)
end

function M.setup(bead_extra)
  state.orig_path = vim.env.PATH
  state.orig_cwd = vim.fn.getcwd()
  state.orig_select = vim.ui.select
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
    "    list) cat " .. q(state.dir .. "/list.json") .. "; exit 0;;",
    "    ready) echo '[]'; exit 0;;",
    "  esac",
    "done",
    "echo '{}'",
  }, state.dir .. "/bd")
  vim.fn.setfperm(state.dir .. "/bd", "rwxr-xr-x")
  M.write_bead(bead_extra)
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
  vim.env.PATH = state.orig_path
  vim.cmd.cd(vim.fn.fnameescape(state.orig_cwd))
  cli.set_root(nil)
  vim.fn.delete(state.dir, "rf")
end

-- Opens beads://<ID> in the current window and waits for the load.
function M.open_detail()
  vim.cmd("edit beads://" .. M.ID)
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

-- Evaluated winbar of window `win`: { str = <text>, hl = { { start = <0-based byte>, group = <name> } } }.
function M.winbar(win)
  local wb = vim.api.nvim_get_option_value("winbar", { win = win })
  if wb == nil or wb == "" then
    return { str = "", hl = {} }
  end
  local res = vim.api.nvim_eval_statusline(wb, { winid = win, use_winbar = true, highlights = true })
  local hl = {}
  for _, h in ipairs(res.highlights or {}) do
    local g = h.group
    if type(h.groups) == "table" and #h.groups > 0 then
      g = h.groups[#h.groups]
    end
    hl[#hl + 1] = { start = h.start, group = g }
  end
  return { str = res.str, hl = hl }
end

-- Highlight group in effect at the first byte of plain substring `needle` of the evaluated winbar.
function M.winbar_group_at(wb, needle)
  local s = wb.str:find(needle, 1, true)
  assert(s, "'" .. needle .. "' not in winbar: " .. vim.inspect(wb.str))
  local byte = s - 1
  local group
  for _, h in ipairs(wb.hl) do
    if h.start <= byte then
      group = h.group
    end
  end
  return group
end

-- All highlight groups of extmarks (any namespace) covering (row, col), both 0-based.
function M.groups_at(buf, row, col)
  local out = {}
  local marks = vim.api.nvim_buf_get_extmarks(buf, -1, { row, 0 }, { row, -1 }, { details = true, overlap = true })
  for _, m in ipairs(marks) do
    local r, c, d = m[2], m[3], m[4]
    local er, ec = d.end_row or r, d.end_col
    local covers
    if ec == nil then
      covers = r == row and c == col
    else
      covers = (r < row or (r == row and c <= col)) and (er > row or (er == row and col < ec))
    end
    if covers and d.hl_group then
      local g = d.hl_group
      if type(g) == "table" then
        for _, x in ipairs(g) do
          out[#out + 1] = x
        end
      else
        out[#out + 1] = g
      end
    end
  end
  return out
end

-- 0-based row of the first buffer line starting with `prefix`.
function M.row_of(buf, prefix)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if vim.startswith(l, prefix) then
      return i - 1, l
    end
  end
  error("no line starting with '" .. prefix .. "'")
end

-- Text shown on 0-based `row`: the line itself plus all virt_text / virt_lines of extmarks on it.
function M.shown_text(buf, row)
  local parts = { vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "" }
  local marks = vim.api.nvim_buf_get_extmarks(buf, -1, { row, 0 }, { row, -1 }, { details = true })
  for _, m in ipairs(marks) do
    local d = m[4]
    for _, ch in ipairs(d.virt_text or {}) do
      parts[#parts + 1] = ch[1]
    end
    for _, vl in ipairs(d.virt_lines or {}) do
      for _, ch in ipairs(vl) do
        parts[#parts + 1] = ch[1]
      end
    end
  end
  return table.concat(parts, " ")
end

return M
