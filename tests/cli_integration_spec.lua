-- Interface under test (bead beads_nvim-ge7.2): see tests/cli_spec.lua.
-- Integration: cli.list() against a real temp bd repo with 55 issues returns all 55
-- (bd's default list limit is 50, so this needs '-n 0').

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local helpers = require("tests.helpers")
local cli = require("beads.cli")

describe("beads.cli integration", function()
  if not helpers.has_bd() then
    pending("bd executable not found")
    return
  end

  it("list() returns all 55 issues of a temp bd repo", function()
    if vim.fn.exists(":Beads") ~= 2 then
      vim.cmd.source(root .. "/plugin/beads.lua")
    end
    local cwd = vim.fn.getcwd()
    helpers.with_bd_repo(function(dir)
      local lines = {}
      for i = 1, 55 do
        table.insert(lines, "## Issue " .. i)
        table.insert(lines, "")
      end
      local md = dir .. "/issues.md"
      vim.fn.writefile(lines, md)
      local r = vim.system({ "bd", "create", "-f", md, "--json" }, { cwd = dir, text = true }):wait()
      assert.are.equal(0, r.code, "bd create -f failed: " .. tostring(r.stderr))

      vim.cmd("Beads cd " .. vim.fn.fnameescape(dir))
      local res
      local ok, err = pcall(cli.list, {}, function(x)
        res = x
      end)
      local done = ok and vim.wait(20000, function()
        return res ~= nil
      end, 20)
      vim.cmd("Beads cd " .. vim.fn.fnameescape(cwd))
      assert(ok, "cli.list threw: " .. tostring(err))
      assert.is_true(done, "callback was never called")
      assert.is_nil(res.err, "unexpected error: " .. vim.inspect(res))
      assert.are.equal(55, #res.data)
    end)
  end)
end)
