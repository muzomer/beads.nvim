-- Bead beads_nvim-2qo.2 (integration): set type / add label / remove label / move under epic /
-- remove parent from the tree's A menu against a real temp bd repo. Each runs one `bd update` per
-- bead (counted through a logging shim on PATH that execs the real bd) and every bead reflects
-- the change in `bd show --json`.
-- Prompt conventions and assumptions: see tests/tree_group_fields_spec.lua.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local helpers = require("tests.helpers")
local cli = require("beads.cli")
local model = require("beads.model")
local H = require("tests.group_actions_harness")

local TIMEOUT = 30000

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

local function create(dir, title, extra)
  local args = { "create", title, "--silent" }
  vim.list_extend(args, extra or {})
  return vim.trim(bd(dir, args))
end

describe("tree group actions integration (real bd)", function()
  if not helpers.has_bd() then
    pending("bd executable not found")
    return
  end

  local real_bd = vim.fn.exepath("bd")
  local orig_path, shim, cwd

  local function log()
    local p = shim .. "/calls.log"
    return vim.fn.filereadable(p) == 1 and vim.fn.readfile(p) or {}
  end

  -- number of logged bd calls whose verb is v and that name id (id nil: any)
  local function count(v, id)
    local n = 0
    for _, l in ipairs(log()) do
      local args = {}
      for a in l:gmatch("%[(.-)%]") do
        args[#args + 1] = a
      end
      if args[1] == "-C" then
        args = vim.list_slice(args, 3)
      end
      local verb
      for _, a in ipairs(args) do
        if a:sub(1, 1) ~= "-" then
          verb = a
          break
        end
      end
      if verb == v and (id == nil or vim.tbl_contains(args, id)) then
        n = n + 1
      end
    end
    return n
  end

  -- Runs fn(dir, ids) with a temp repo holding epics E1, E2 (E1 > a, b) and task c; a, b, c carry
  -- label "old". The tree is open on it with the A-menu stubs installed.
  local function with_repo(fn)
    helpers.with_bd_repo(function(dir)
      local ids = {}
      ids.e1 = create(dir, "Epic one", { "-t", "epic" })
      ids.e2 = create(dir, "Epic two", { "-t", "epic" })
      ids.a = create(dir, "Task a", { "-l", "old", "--parent", ids.e1 })
      ids.b = create(dir, "Task b", { "-l", "old", "--parent", ids.e1 })
      ids.c = create(dir, "Task c", { "-l", "old" })
      shim = vim.fn.tempname()
      vim.fn.mkdir(shim, "p")
      vim.fn.writefile({
        "#!/bin/sh",
        'line=""',
        'for a in "$@"; do line="$line[$a]"; done',
        "printf '%s\\n' \"$line\" >> " .. vim.fn.shellescape(shim .. "/calls.log"),
        "exec " .. vim.fn.shellescape(real_bd) .. ' "$@"',
      }, shim .. "/bd")
      vim.fn.setfperm(shim .. "/bd", "rwxr-xr-x")
      orig_path = vim.env.PATH
      vim.env.PATH = shim .. ":" .. orig_path
      cwd = vim.fn.getcwd()
      H.install()
      local ok, err = pcall(function()
        vim.cmd.cd(vim.fn.fnameescape(dir))
        cli.set_root(dir)
        if vim.fn.exists(":Beads") == 0 then
          vim.cmd.source(root .. "/plugin/beads.lua")
        end
        require("beads").setup({ fzf = false })
        H.open_tree(ids.c)
        fn(dir, ids)
      end)
      H.close_all()
      H.sleep(300)
      H.restore()
      vim.env.PATH = orig_path
      cli.set_root(nil)
      vim.cmd.cd(vim.fn.fnameescape(cwd))
      require("beads").setup({})
      vim.fn.delete(shim, "rf")
      if not ok then
        error(err, 0)
      end
    end)
  end

  local function wait_updates(n, what)
    H.wait_for(function()
      return count("update") >= n
    end, what .. "; bd log:\n" .. table.concat(log(), "\n"), TIMEOUT)
    H.sleep(500)
  end

  local function one_update_each(list)
    assert.are.equal(0, count("batch"), "per-bead action went through bd batch")
    for _, id in ipairs(list) do
      assert.are.equal(1, count("update", id), id .. ": expected one bd update:\n" .. table.concat(log(), "\n"))
    end
  end

  it("set type runs one bd update per bead and all beads become bugs", function()
    with_repo(function(dir, ids)
      local list = { ids.a, ids.b, ids.c }
      H.mark(list)
      H.act({
        name = "type",
        menu = H.menu.type,
        value = {
          input = "bug",
          pick = function(t)
            return t:find("bug", 1, true) ~= nil
          end,
        },
      })
      wait_updates(3, "three updates")
      one_update_each(list)
      for _, id in ipairs(list) do
        assert.are.equal("bug", show(dir, id).type, id .. " type")
      end
    end)
  end)

  it("add label runs one bd update per bead and all beads carry the label", function()
    with_repo(function(dir, ids)
      local list = { ids.a, ids.c }
      H.mark(list)
      H.act({
        name = "add label",
        menu = H.menu.add_label,
        value = {
          input = "urgent",
          pick = function(t)
            return t:find("urgent", 1, true) ~= nil
          end,
        },
      })
      wait_updates(2, "two updates")
      one_update_each(list)
      for _, id in ipairs(list) do
        assert.is_true(vim.tbl_contains(show(dir, id).labels, "urgent"), id .. " lacks label urgent")
      end
      assert.is_false(vim.tbl_contains(show(dir, ids.b).labels, "urgent"), "unmarked bead got the label")
    end)
  end)

  it("remove label runs one bd update per bead and the label is gone from all", function()
    with_repo(function(dir, ids)
      local list = { ids.a, ids.b, ids.c }
      H.mark(list)
      H.act({
        name = "remove label",
        menu = H.menu.remove_label,
        value = {
          input = "old",
          pick = function(t)
            return t:match("%f[%w]old%f[%W]") ~= nil
          end,
        },
      })
      wait_updates(3, "three updates")
      one_update_each(list)
      for _, id in ipairs(list) do
        assert.is_false(vim.tbl_contains(show(dir, id).labels, "old"), id .. " still has label old")
      end
    end)
  end)

  it("move under epic runs one bd update per bead and all beads get the new parent", function()
    with_repo(function(dir, ids)
      local list = { ids.a, ids.c }
      H.mark(list)
      H.act({ name = "move under epic", menu = H.menu.epic, value = { input = ids.e2, pick = H.pick_id(ids.e2) } })
      wait_updates(2, "two updates")
      one_update_each(list)
      for _, id in ipairs(list) do
        assert.are.equal(ids.e2, show(dir, id).parent, id .. " parent")
      end
      assert.are.equal(ids.e1, show(dir, ids.b).parent, "unmarked bead was moved")
    end)
  end)

  it("remove parent runs one bd update per bead and the beads have no parent", function()
    with_repo(function(dir, ids)
      local list = { ids.a, ids.b }
      H.mark(list)
      H.act({
        name = "remove parent (or move under epic)",
        menu = H.menu.remove_parent,
        value = { input = "", pick = H.pick_remove_parent },
      })
      wait_updates(2, "two updates")
      one_update_each(list)
      for _, id in ipairs(list) do
        assert.is_nil(show(dir, id).parent, id .. " still has a parent")
      end
    end)
  end)
end)
