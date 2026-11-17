-- Finding (bead beads_nvim-ge7.5): a store refresh must not pin the cli root.
-- With no explicit root (cli.set_root(nil)), cli.get_root() follows the cwd; after
-- store.refresh(other_root) it must still follow a later :cd, and an explicit root
-- set by the user must survive a refresh unchanged.
--
-- `bd` is replaced by a shell script on PATH that prints "[]" (test double).

local cli = require("beads.cli")
local store = require("beads.store")

local orig_path, orig_cwd, bin_dir

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return vim.fn.resolve(d)
end

local function refresh_wait(r)
  local done = false
  store.refresh(r, function()
    done = true
  end)
  assert(vim.wait(5000, function()
    return done
  end, 10), "refresh callback was never called")
end

describe("beads.store cli root", function()
  before_each(function()
    orig_path = vim.env.PATH
    orig_cwd = vim.fn.getcwd()
    bin_dir = tmpdir()
    vim.fn.writefile({ "#!/bin/sh", "echo '[]'" }, bin_dir .. "/bd")
    vim.fn.setfperm(bin_dir .. "/bd", "rwxr-xr-x")
    vim.env.PATH = bin_dir .. ":" .. orig_path
  end)

  after_each(function()
    vim.env.PATH = orig_path
    vim.cmd.cd(vim.fn.fnameescape(orig_cwd))
    cli.set_root(nil)
  end)

  it("leaves an unset cli root unset, so it still follows :cd after a refresh", function()
    cli.set_root(nil)
    local a, b, r = tmpdir(), tmpdir(), tmpdir()
    vim.cmd.cd(vim.fn.fnameescape(a))
    assert.are.equal(a, vim.fn.resolve(cli.get_root()))

    refresh_wait(r)

    vim.cmd.cd(vim.fn.fnameescape(b))
    assert.are.equal(b, vim.fn.resolve(cli.get_root()))
  end)

  it("keeps an explicit cli root after a refresh of another root", function()
    local explicit, r = tmpdir(), tmpdir()
    cli.set_root(explicit)
    refresh_wait(r)
    assert.are.equal(explicit, cli.get_root())
  end)
end)
