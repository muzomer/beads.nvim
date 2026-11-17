-- Finding (bead beads_nvim-ge7.7, lua/beads/buffer/diff.lua:153): diff.create passed the title
-- as a positional arg, so a title starting with '-' was parsed by bd as a flag and create failed.
-- Integration: the create args from diff.create, run through cli.run_with_files, really create a
-- bead whose title starts with '-'.

local helpers = require("tests.helpers")
local render = require("beads.buffer.render")
local cli = require("beads.cli")
local diff = require("beads.buffer.diff")

local function replace(lines, prefix, new)
  local out = vim.deepcopy(lines)
  for i, l in ipairs(out) do
    if vim.startswith(l, prefix) then
      out[i] = new
      return out
    end
  end
  error("no line starting with " .. prefix)
end

local function list_titles(dir)
  local r = vim.system({ "bd", "-C", dir, "list", "--all", "--json" }, { text = true }):wait()
  assert.are.equal(0, r.code, "bd list failed: " .. tostring(r.stderr))
  local titles = {}
  for _, it in ipairs(vim.json.decode(r.stdout) or {}) do
    titles[#titles + 1] = it.title
  end
  return titles
end

describe("beads.buffer.diff create with a dash-leading title", function()
  if not helpers.has_bd() then
    pending("bd executable not found")
    return
  end

  it("creates the bead in bd with the exact title", function()
    helpers.with_bd_repo(function(dir)
      local title = "-1 off-by-one in pager"
      local lines = replace(render.template({}), "# ", "# " .. title)
      local c = diff.create(lines)

      local saved = cli.get_root_override()
      cli.set_root(dir)
      local res
      local ok, err = pcall(cli.run_with_files, c.args, c.files or {}, function(x)
        res = x
      end)
      local done = ok and vim.wait(20000, function()
        return res ~= nil
      end, 20)
      cli.set_root(saved)
      assert(ok, "run_with_files threw: " .. tostring(err))
      assert.is_true(done, "callback was never called")
      assert.is_nil(res.err, "bd create failed: " .. vim.inspect(res) .. " args: " .. vim.inspect(c.args))

      assert.is_true(vim.tbl_contains(list_titles(dir), title), vim.inspect(list_titles(dir)))
    end)
  end)
end)
