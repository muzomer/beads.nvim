-- Bead beads_nvim-qvs.3 (integration): setting an assignee whose value contains a single quote on
-- several beads from the tree's A menu works against a real temp bd repo (one bd batch; every
-- bead shows the exact value in `bd show --json`).
-- Prompt conventions: see tests/tree_group_fields_spec.lua.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local helpers = require("tests.helpers")
local cli = require("beads.cli")
local H = require("tests.group_actions_harness")

local TIMEOUT = 30000

local function bd(dir, args)
  local argv = { "bd", "-C", dir }
  vim.list_extend(argv, args)
  local r = vim.system(argv, { text = true }):wait()
  assert.are.equal(0, r.code, "bd " .. table.concat(args, " ") .. " failed: " .. tostring(r.stderr))
  return r.stdout
end

local function assignee(dir, id)
  return vim.json.decode(bd(dir, { "show", id, "--json" }))[1].assignee
end

local function create(dir, title)
  return vim.trim(bd(dir, { "create", title, "--silent" }))
end

describe("group set assignee with a single quote (real bd)", function()
  if not helpers.has_bd() then
    pending("bd executable not found")
    return
  end

  local function with_repo(fn)
    helpers.with_bd_repo(function(dir)
      local ids = { create(dir, "Task a"), create(dir, "Task b"), create(dir, "Task c") }
      local cwd = vim.fn.getcwd()
      H.install()
      local ok, err = pcall(function()
        vim.cmd.cd(vim.fn.fnameescape(dir))
        cli.set_root(dir)
        if vim.fn.exists(":Beads") == 0 then
          vim.cmd.source(root .. "/plugin/beads.lua")
        end
        require("beads").setup({ tree = { layout = "split" }, fzf = false })
        H.open_tree(ids[3])
        fn(dir, ids)
      end)
      H.close_all()
      H.sleep(300)
      H.restore()
      cli.set_root(nil)
      vim.cmd.cd(vim.fn.fnameescape(cwd))
      require("beads").setup({ tree = { layout = "split" } })
      if not ok then
        error(err, 0)
      end
    end)
  end

  local function set_assignee_on_all(dir, ids, value)
    H.mark(ids)
    H.act({ name = "assignee", menu = H.menu.assignee, value = { input = value } })
    local got
    local done = vim.wait(TIMEOUT, function()
      got = {}
      for _, id in ipairs(ids) do
        got[#got + 1] = assignee(dir, id)
      end
      return vim.deep_equal(got, { value, value, value })
    end, 300)
    local errs = {}
    for _, n in ipairs(H.notes) do
      errs[#errs + 1] = n.msg
    end
    assert.is_true(done, ("assignee %q not set on all beads; got %s; messages:\n%s"):format(
      value, vim.inspect(got), table.concat(errs, "\n")))
  end

  it("sets assignee o'brien on three beads", function()
    with_repo(function(dir, ids)
      set_assignee_on_all(dir, ids, "o'brien")
    end)
  end)

  it("sets assignee Mary O'Brien (space and single quote) on three beads", function()
    with_repo(function(dir, ids)
      set_assignee_on_all(dir, ids, "Mary O'Brien")
    end)
  end)
end)
