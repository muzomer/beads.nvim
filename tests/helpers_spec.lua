-- Interface under test (bead beads_nvim-ge7.1): the test helper module
--   local helpers = require("tests.helpers")   -- tests/helpers.lua or tests/helpers/init.lua
--   helpers.load_fixture(name)  -> decoded JSON of tests/fixtures/<name>.json (name without extension)
--   helpers.has_bd()            -> true when the `bd` executable is available
--   helpers.with_bd_repo(fn)    -> creates a temp dir, runs `bd init` in it, calls fn(dir),
--                                  then removes the dir (also when fn errors; the error is re-raised)

local helpers = require("tests.helpers")

describe("tests.helpers.load_fixture", function()
  it("loads and decodes a JSON fixture by name", function()
    local data = helpers.load_fixture("helpers_sample")
    assert.are.equal("table", type(data))
    assert.are.equal("sample-1", data[1].id)
    assert.are.equal("Sample issue", data[1].title)
  end)
end)

describe("tests.helpers.with_bd_repo", function()
  if not helpers.has_bd() then
    pending("bd executable not found")
    return
  end

  it("creates a temp bd repo and removes it afterwards", function()
    local seen
    helpers.with_bd_repo(function(dir)
      seen = dir
      assert.are.equal(1, vim.fn.isdirectory(dir))
      assert.are.equal(1, vim.fn.isdirectory(dir .. "/.beads"))
    end)
    assert.is_truthy(seen)
    assert.are.equal(0, vim.fn.isdirectory(seen))
  end)

  it("removes the temp repo even when the test body errors", function()
    local seen
    local ok = pcall(helpers.with_bd_repo, function(dir)
      seen = dir
      error("boom")
    end)
    assert.is_false(ok)
    assert.is_truthy(seen)
    assert.are.equal(0, vim.fn.isdirectory(seen))
  end)
end)
