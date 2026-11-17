-- Finding (bead beads_nvim-ge7.8): writing a detail buffer (:w) and the x / C keys must not pin
-- the cli root. With no explicit root (cli.set_root(nil)), cli.get_root() follows the cwd; after
-- a :w, a claim (C) or a close (x) on a detail buffer it must still follow a later :cd.
--
-- `bd` is replaced by a shell script on PATH (test double): 'show' prints one bead, 'list'
-- prints "[]", everything else prints "{}". Every call is logged one per line.

local cli = require("beads.cli")
local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local orig_path, orig_cwd, bin_dir, log

local BEAD = vim.json.encode({
  {
    id = "fx-1",
    title = "Root test",
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
    if l:find(" " .. word .. " ", 1, true) or vim.endswith(l, " " .. word) then
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
    return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] ~= ""
      and require("beads.views.detail").snapshot(buf) ~= nil
  end, "detail buffer load")
  return buf
end

-- After an action triggers update/close + refresh + reload, wait until the reload ran.
local function wait_reload(shows_before)
  wait_for(function()
    return count("show") > shows_before and count("list") >= 1
  end, "reload after action")
  vim.wait(200)
end

describe("beads detail buffer cli root", function()
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
    cli.set_root(nil)
    if vim.fn.exists("#BeadsDetail#BufReadCmd") == 0 then
      vim.cmd.source(repo .. "/plugin/beads.lua")
    end
  end)

  after_each(function()
    pcall(vim.cmd, "silent! %bwipeout!")
    vim.env.PATH = orig_path
    vim.cmd.cd(vim.fn.fnameescape(orig_cwd))
    cli.set_root(nil)
  end)

  it(":w leaves an unset cli root unset, so it still follows :cd", function()
    local a, b = tmpdir(), tmpdir()
    vim.cmd.cd(vim.fn.fnameescape(a))
    local buf = open_detail()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local changed = false
    for i, l in ipairs(lines) do
      if l:find("Root test", 1, true) then
        lines[i] = l:gsub("Root test", "Root test changed")
        changed = true
        break
      end
    end
    assert.is_true(changed, "title line not found in rendered buffer")
    if not vim.bo[buf].modifiable then
      vim.cmd.normal("e") -- beads_nvim-4gx.8: VIEW mode is read-only, e enters EDIT mode
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local shows = count("show")
    vim.cmd("write")
    wait_for(function()
      return count("update") >= 1
    end, "bd update")
    wait_reload(shows)

    vim.cmd.cd(vim.fn.fnameescape(b))
    assert.are.equal(b, vim.fn.resolve(cli.get_root()))
  end)

  it("C (claim) leaves an unset cli root unset", function()
    local a, b = tmpdir(), tmpdir()
    vim.cmd.cd(vim.fn.fnameescape(a))
    open_detail()
    local shows = count("show")
    vim.cmd("normal C")
    wait_for(function()
      return count("update") >= 1
    end, "bd update --claim")
    wait_reload(shows)

    vim.cmd.cd(vim.fn.fnameescape(b))
    assert.are.equal(b, vim.fn.resolve(cli.get_root()))
  end)

  it("x (close) leaves an unset cli root unset", function()
    local a, b = tmpdir(), tmpdir()
    vim.cmd.cd(vim.fn.fnameescape(a))
    open_detail()
    local orig_input = vim.ui.input
    vim.ui.input = function(_, on_confirm)
      on_confirm("done")
    end
    local shows = count("show")
    local ok, err = pcall(vim.cmd, "normal x")
    vim.ui.input = orig_input
    assert(ok, err)
    wait_for(function()
      return count("close") >= 1
    end, "bd close")
    wait_reload(shows)

    vim.cmd.cd(vim.fn.fnameescape(b))
    assert.are.equal(b, vim.fn.resolve(cli.get_root()))
  end)

  it("keeps an explicit cli root after :w", function()
    local explicit = tmpdir()
    cli.set_root(explicit)
    local buf = open_detail()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i, l in ipairs(lines) do
      if l:find("Root test", 1, true) then
        lines[i] = l:gsub("Root test", "Root test changed")
        break
      end
    end
    if not vim.bo[buf].modifiable then
      vim.cmd.normal("e") -- beads_nvim-4gx.8: VIEW mode is read-only, e enters EDIT mode
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local shows = count("show")
    vim.cmd("write")
    wait_reload(shows)
    assert.are.equal(explicit, cli.get_root())
  end)
end)
