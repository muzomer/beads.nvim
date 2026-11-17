-- Interface under test (bead beads_nvim-ge7.7): see tests/buffer_diff_spec.lua.
-- Integration: the update produced by diff.compute for "remove all labels" really clears the
-- labels of a bead in a temp bd repo when run through cli.run_with_files. (bd 1.2.2 ignores
-- `--set-labels ""`, so the diff must use a form that bd actually applies.)

local helpers = require("tests.helpers")
local model = require("beads.model")
local render = require("beads.buffer.render")
local cli = require("beads.cli")
local diff = require("beads.buffer.diff")

local function bd(dir, args)
  local argv = { "bd", "-C", dir }
  vim.list_extend(argv, args)
  local r = vim.system(argv, { text = true }):wait()
  assert.are.equal(0, r.code, "bd " .. table.concat(args, " ") .. " failed: " .. tostring(r.stderr))
  return r.stdout
end

local function show(dir, id)
  return model.normalize(vim.json.decode(bd(dir, { "show", id, "--json" }))[1])
end

local function run_update(dir, update)
  local saved = cli.get_root_override()
  cli.set_root(dir)
  local res
  local ok, err = pcall(cli.run_with_files, update.args, update.files or {}, function(x)
    res = x
  end)
  local done = ok and vim.wait(20000, function()
    return res ~= nil
  end, 20)
  cli.set_root(saved)
  assert(ok, "run_with_files threw: " .. tostring(err))
  assert.is_true(done, "callback was never called")
  assert.is_nil(res.err, "bd update failed: " .. vim.inspect(res))
end

describe("beads.buffer.diff integration", function()
  if not helpers.has_bd() then
    pending("bd executable not found")
    return
  end

  it("removing all labels clears them in bd", function()
    helpers.with_bd_repo(function(dir)
      local id = vim.trim(bd(dir, { "create", "Labelled", "-l", "alpha,beta", "--silent" }))
      local b = show(dir, id)
      table.sort(b.labels)
      assert.same({ "alpha", "beta" }, b.labels)

      local lines = render.render(b)
      for i, l in ipairs(lines) do
        if vim.startswith(l, "labels:") then
          lines[i] = "labels: []"
        end
      end
      local r = diff.compute(b, lines)
      assert.is_not_nil(r.update)
      run_update(dir, r.update)

      assert.same({}, show(dir, id).labels)
    end)
  end)

  it("changing only priority applies it in bd and leaves other fields alone", function()
    helpers.with_bd_repo(function(dir)
      local id = vim.trim(bd(dir, { "create", "Prio", "-p", "2", "-l", "keep", "--silent" }))
      local b = show(dir, id)
      local lines = render.render(b)
      for i, l in ipairs(lines) do
        if vim.startswith(l, "priority:") then
          lines[i] = "priority: 0"
        end
      end
      local r = diff.compute(b, lines)
      run_update(dir, r.update)
      local after = show(dir, id)
      assert.equals(0, after.priority)
      assert.same({ "keep" }, after.labels)
      assert.equals("Prio", after.title)
    end)
  end)
end)
