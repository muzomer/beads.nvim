-- Finding (bead beads_nvim-ge7.11): confirming the note / comment float with :w must not trigger
-- the global beads://* BufWriteCmd handler. A spurious "Beads: detail buffer not loaded yet"
-- WARN (or any WARN/ERROR notify) on a successful :w confirm is the bug.
--
-- `bd` is replaced by a shell script on PATH (test double): 'show' prints one bead, 'list'
-- prints "[]", everything else prints "{}". Every call is logged one per line.

local cli = require("beads.cli")
local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local orig_path, orig_cwd, orig_notify, bin_dir, log, notes

local BEAD = vim.json.encode({
  {
    id = "fx-1",
    title = "Float write test",
    description = "desc",
    status = "open",
    priority = 2,
    issue_type = "task",
    created_at = "2026-11-17T16:01:12Z",
    updated_at = "2026-11-17T16:01:12Z",
  },
})

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return vim.fn.resolve(d)
end

local function count(word)
  local n = 0
  for _, l in ipairs(vim.fn.filereadable(log) == 1 and vim.fn.readfile(log) or {}) do
    if l:find(" " .. word .. " ", 1, true) or vim.endswith(l, " " .. word) or vim.startswith(l, word .. " ") then
      n = n + 1
    end
  end
  return n
end

local function wait_for(pred, what)
  assert(vim.wait(5000, pred, 10), "timed out waiting for " .. what)
end

local function open_detail()
  vim.cmd("edit beads://fx-1")
  local buf = vim.api.nvim_get_current_buf()
  wait_for(function()
    return require("beads.views.detail").snapshot(buf) ~= nil and not vim.bo[buf].modified
  end, "detail buffer load")
  return buf
end

local function bad_notes()
  local out = {}
  for _, n in ipairs(notes) do
    if (n.level or vim.log.levels.INFO) >= vim.log.levels.WARN or n.msg:find("not loaded", 1, true) then
      out[#out + 1] = n
    end
  end
  return out
end

describe("beads detail note/comment float :w", function()
  before_each(function()
    orig_path = vim.env.PATH
    orig_cwd = vim.fn.getcwd()
    bin_dir = tmpdir()
    log = bin_dir .. "/calls.log"
    vim.fn.writefile({
      "#!/bin/sh",
      'echo "$*" >> ' .. vim.fn.shellescape(log),
      'for a in "$@"; do',
      '  case "$a" in',
      "    show) cat " .. vim.fn.shellescape(bin_dir .. "/bead.json") .. "; exit 0;;",
      "    list) echo '[]'; exit 0;;",
      "  esac",
      "done",
      "echo '{}'",
    }, bin_dir .. "/bd")
    vim.fn.writefile({ BEAD }, bin_dir .. "/bead.json")
    vim.fn.setfperm(bin_dir .. "/bd", "rwxr-xr-x")
    vim.env.PATH = bin_dir .. ":" .. orig_path
    vim.cmd.cd(vim.fn.fnameescape(bin_dir))
    cli.set_root(bin_dir)
    if vim.fn.exists("#BeadsDetail#BufReadCmd") == 0 then
      vim.cmd.source(repo .. "/plugin/beads.lua")
    end
    notes = {}
    orig_notify = vim.notify
    vim.notify = function(msg, level, opts)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
  end)

  after_each(function()
    vim.notify = orig_notify
    pcall(vim.cmd, "stopinsert")
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    pcall(vim.cmd, "silent! %bwipeout!")
    vim.env.PATH = orig_path
    vim.cmd.cd(vim.fn.fnameescape(orig_cwd))
    cli.set_root(nil)
  end)

  for _, case in ipairs({ { key = "n", sub = "update" }, { key = "c", sub = "comment" } }) do
    it(case.key .. " + text + :w confirms without a spurious warning", function()
      open_detail()
      vim.cmd.normal(case.key)
      vim.cmd("stopinsert")
      local win = vim.api.nvim_get_current_win()
      assert.is_true(vim.api.nvim_win_get_config(win).relative ~= "", "no float opened")
      local fbuf = vim.api.nvim_win_get_buf(win)
      vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { "float text" })
      local shows = count("show")
      notes = {}
      vim.cmd("write")
      wait_for(function()
        return count(case.sub) + (case.sub == "comment" and count("comments") or 0) >= 1
      end, "bd " .. case.sub)
      wait_for(function()
        return count("show") > shows
      end, "reload after confirm")
      vim.wait(300)
      assert.same({}, bad_notes(), ":w in the float produced a warning: " .. vim.inspect(notes))
    end)
  end
end)
