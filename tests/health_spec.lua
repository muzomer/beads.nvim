-- Interface under test (bead beads_nvim-ge7.15): lua/beads/health.lua, run via
-- ':checkhealth beads'. The report is read back from the checkhealth buffer.
-- The checked root is the plugin root (cli.get_root()); tests set both the cwd
-- and the cli root override so either source resolves to the same dir.

local helpers = require("tests.helpers")
local cli = require("beads.cli")

local function run_checkhealth(dir)
  local prev_cwd = vim.fn.getcwd()
  local prev_root = cli.get_root_override()
  vim.cmd.cd(vim.fn.fnameescape(dir))
  cli.set_root(dir)
  local ok, err = pcall(vim.cmd, "checkhealth beads")
  local lines = {}
  if ok then
    lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    if #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd("tabclose!")
    end
  end
  cli.set_root(prev_root)
  vim.cmd.cd(vim.fn.fnameescape(prev_cwd))
  assert(ok, ":checkhealth beads threw: " .. tostring(err))
  return lines, table.concat(lines, "\n")
end

local function lines_with(lines, kind)
  return vim.tbl_filter(function(l)
    return l:find(kind, 1, true) ~= nil
  end, lines)
end

local function assert_ran(text)
  assert.is_nil(text:find("No healthcheck found", 1, true), "no beads healthcheck:\n" .. text)
  assert.is_nil(text:find("Failed to run healthcheck", 1, true), "healthcheck threw:\n" .. text)
end

describe(":checkhealth beads", function()
  it("reports an error and does not throw when bd is missing", function()
    local empty = vim.fn.tempname()
    vim.fn.mkdir(empty, "p")
    local prev_path = vim.env.PATH
    vim.env.PATH = empty
    local ok, lines, text = pcall(run_checkhealth, empty)
    vim.env.PATH = prev_path
    vim.fn.delete(empty, "rf")
    assert(ok, tostring(lines))
    assert_ran(text)
    local errors = lines_with(lines, "ERROR")
    assert.is_true(#errors >= 1, "expected an ERROR line:\n" .. text)
    assert.is_truthy(table.concat(errors, "\n"):find("bd", 1, true), "ERROR should mention bd:\n" .. text)
  end)

  if not helpers.has_bd() then
    pending("bd executable not found")
    return
  end

  it("reports ok for bd present, its version and .beads found in a temp bd repo", function()
    local v = vim.system({ "bd", "version" }, { text = true }):wait()
    local version = (v.stdout or ""):match("(%d+%.%d+%.%d+)")
    assert.is_not_nil(version, "could not read bd version")
    helpers.with_bd_repo(function(dir)
      local lines, text = run_checkhealth(dir)
      assert_ran(text)
      assert.are.same({}, lines_with(lines, "ERROR"), "unexpected ERROR:\n" .. text)
      local oks = lines_with(lines, "OK")
      local ok_text = table.concat(oks, "\n")
      assert.is_true(#oks >= 3, "expected at least 3 OK lines (bd, version, .beads):\n" .. text)
      assert.is_truthy(ok_text:find("bd", 1, true), "OK for bd present missing:\n" .. text)
      assert.is_truthy(ok_text:find(version, 1, true), "OK with bd version " .. version .. " missing:\n" .. text)
      assert.is_truthy(ok_text:find(".beads", 1, true), "OK for .beads found missing:\n" .. text)
    end)
  end)

  it("reports an error with a 'bd init' hint in a dir without .beads", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local ok, lines, text = pcall(run_checkhealth, dir)
    vim.fn.delete(dir, "rf")
    assert(ok, tostring(lines))
    assert_ran(text)
    assert.is_true(#lines_with(lines, "ERROR") >= 1, "expected an ERROR line:\n" .. text)
    assert.is_truthy(text:find("bd init", 1, true), "expected a 'bd init' hint:\n" .. text)
  end)
end)
