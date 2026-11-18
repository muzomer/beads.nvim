-- Bead beads_nvim-ge7.10: create flow, beads://new.
-- Interface under test (public entry points only):
--   * ':Beads create' opens a buffer named beads://new with the template
--     (render.template: type task, priority 2, no id line).
--   * require("beads.views.detail").create_child(parent_id) opens beads://new with 'parent: <id>'
--     prefilled (used by the tree's 'a' key).
--   * :w on beads://new runs exactly one 'bd create' (text via files, --deps blocks:<id>, --parent,
--     -l, -a), then the buffer is renamed to beads://<new-id> and reloaded.
--   * An empty title refuses the write with an ERROR notification and spawns no bd process.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local helpers = require("tests.helpers")
local cli = require("beads.cli")
local model = require("beads.model")

local TIMEOUT = 15000

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

local function count_titled(dir, title)
  local n = 0
  for _, it in ipairs(vim.json.decode(bd(dir, { "list", "--all", "-n", "0", "--json" })) or {}) do
    if it.title == title then
      n = n + 1
    end
  end
  return n
end

local function buf_lines(buf)
  return vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)
end

local function has_line(buf, line)
  return vim.tbl_contains(buf_lines(buf), line)
end

local function set_line(buf, pred, new)
  local lines = buf_lines(buf)
  for i, l in ipairs(lines) do
    if pred(l) then
      vim.api.nvim_buf_set_lines(buf, i - 1, i, false, type(new) == "table" and new or { new })
      return
    end
  end
  error("no matching line to edit")
end

local function set_prefixed(buf, prefix, new)
  set_line(buf, function(l)
    return vim.startswith(l, prefix)
  end, new)
end

local function set_title(buf, title)
  set_line(buf, function(l)
    return l == "#" or vim.startswith(l, "# ")
  end, "# " .. title)
end

-- Inserts text lines right after the given heading line.
local function fill_section(buf, heading, text_lines)
  local lines = buf_lines(buf)
  for i, l in ipairs(lines) do
    if l == heading then
      vim.api.nvim_buf_set_lines(buf, i, i, false, text_lines)
      return
    end
  end
  error("no heading " .. heading)
end

local function wait_for(fn, msg, timeout)
  local ok = vim.wait(timeout or TIMEOUT, function()
    local pok, v = pcall(fn)
    return pok and v
  end, 20)
  assert.is_true(ok, "timed out waiting for: " .. msg)
end

local calls, notes
local orig_system, orig_notify

local function start_spies()
  calls, notes = {}, {}
  orig_system, orig_notify = vim.system, vim.notify
  vim.system = function(cmd, opts, on_exit)
    if type(cmd) == "table" then
      calls[#calls + 1] = vim.deepcopy(cmd)
    end
    return orig_system(cmd, opts, on_exit)
  end
  vim.notify = function(msg, level, opts)
    notes[#notes + 1] = { msg = tostring(msg), level = level }
    return orig_notify(msg, level, opts)
  end
end

local function stop_spies()
  if orig_system then
    vim.system = orig_system
  end
  if orig_notify then
    vim.notify = orig_notify
  end
  orig_system, orig_notify = nil, nil
end

local function subcommand(argv)
  if argv[1] ~= "bd" then
    return nil
  end
  local i = 2
  while i <= #argv do
    local a = argv[i]
    if a == "-C" or a == "--db" then
      i = i + 2
    elseif vim.startswith(a, "-") then
      i = i + 1
    else
      return a, i
    end
  end
end

local function calls_of(sub)
  local out = {}
  for _, argv in ipairs(calls) do
    if subcommand(argv) == sub then
      out[#out + 1] = argv
    end
  end
  return out
end

local function bd_calls()
  local out = {}
  for _, argv in ipairs(calls) do
    if argv[1] == "bd" then
      out[#out + 1] = argv
    end
  end
  return out
end

-- Data-changing bd calls only: background watcher refreshes (list/ready/show) may legitimately
-- fire late from an earlier test and are not writes.
local READ_SUBS = { list = true, ready = true, show = true, children = true, ["--version"] = true }
local function bd_writes()
  local out = {}
  for _, argv in ipairs(bd_calls()) do
    if not READ_SUBS[subcommand(argv) or ""] then
      out[#out + 1] = argv
    end
  end
  return out
end

local function wipe_beads_buffers()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.startswith(vim.api.nvim_buf_get_name(b), "beads://") then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
end

local shared_dir

local function repo()
  if not shared_dir then
    shared_dir = vim.fn.tempname()
    vim.fn.mkdir(shared_dir, "p")
    local res = vim.system({ "bd", "init", "--non-interactive" }, { cwd = shared_dir, text = true }):wait()
    assert(res.code == 0, "bd init failed: " .. tostring(res.stderr))
  end
  return shared_dir
end

local function in_repo(fn)
  local dir = repo()
  local saved = cli.get_root_override()
  cli.set_root(dir)
  start_spies()
  local ok, err = pcall(fn, dir)
  stop_spies()
  vim.cmd("silent! enew!")
  wipe_beads_buffers()
  cli.set_root(saved)
  if not ok then
    error(err, 0)
  end
end

-- Waits until the current buffer is the beads://new template.
local function wait_new_buffer()
  local buf = vim.api.nvim_get_current_buf()
  wait_for(function()
    return vim.api.nvim_buf_get_name(buf) == "beads://new" and has_line(buf, "## Description")
  end, "current buffer to be the beads://new template", 3000)
  return buf
end

-- :w then wait for the rename to beads://<new-id>; returns the new id.
local function write_and_wait_rename(buf)
  vim.api.nvim_set_current_buf(buf)
  vim.cmd.write()
  local id
  wait_for(function()
    if not vim.api.nvim_buf_is_valid(buf) then
      return false
    end
    local m = vim.api.nvim_buf_get_name(buf):match("^beads://(.+)$")
    if m and m ~= "new" then
      id = m
      return true
    end
  end, "buffer renamed to beads://<new-id>")
  return id
end

describe("beads create flow (beads://new)", function()
  if not helpers.has_bd() then
    pending("bd executable not found")
    return
  end

  if vim.fn.exists(":Beads") ~= 2 then
    vim.cmd.source(root .. "/plugin/beads.lua")
  end

  it(":Beads create opens beads://new with the template (type task, priority 2)", function()
    in_repo(function()
      vim.cmd("Beads create")
      local buf = wait_new_buffer()
      assert.is_true(has_line(buf, "type: task"), "template lacks 'type: task'")
      assert.is_true(has_line(buf, "priority: 2"), "template lacks 'priority: 2'")
    end)
  end)

  it(":Beads create, title + description, :w -> bead exists and buffer is beads://<new-id>", function()
    in_repo(function(dir)
      vim.cmd("Beads create")
      local buf = wait_new_buffer()
      local title = "Created from nvim " .. tostring(vim.uv.hrtime())
      set_title(buf, title)
      fill_section(buf, "## Description", { "First line of the body.", "Second line." })
      local id = write_and_wait_rename(buf)

      local b = show(dir, id)
      assert.are.equal(title, b.title)
      assert.are.equal("First line of the body.\nSecond line.", vim.trim(b.description or ""))
      assert.are.equal("task", b.type)
      assert.are.equal(2, tonumber(b.priority))
      assert.are.equal(1, count_titled(dir, title), "expected exactly one bead with the title")

      -- reloaded as a normal detail buffer
      wait_for(function()
        return has_line(buf, "id: " .. id) and has_line(buf, "# " .. title) and not vim.bo[buf].modified
      end, "beads://" .. id .. " to be reloaded")
    end)
  end)

  it("create_child(X) prefills parent: X and the created bead's parent is X", function()
    in_repo(function(dir)
      local parent = create(dir, "Parent epic", { "-t", "epic" })
      require("beads.views.detail").create_child(parent)
      local buf = wait_new_buffer()
      assert.is_true(has_line(buf, "parent: " .. parent), "template lacks 'parent: " .. parent .. "'")

      local title = "Child " .. tostring(vim.uv.hrtime())
      set_title(buf, title)
      local id = write_and_wait_rename(buf)
      local b = show(dir, id)
      assert.are.equal(title, b.title)
      assert.are.equal(parent, b.parent)
    end)
  end)

  it("empty title -> write refused with an error, no bd call", function()
    in_repo(function()
      vim.cmd("Beads create")
      local buf = wait_new_buffer()
      fill_section(buf, "## Description", { "body without a title" })
      calls, notes = {}, {}
      vim.api.nvim_set_current_buf(buf)
      pcall(vim.cmd.write)
      vim.wait(500)

      assert.are.same({}, bd_writes(), "no data-changing bd call may be made for an empty title")
      local errored = false
      for _, n in ipairs(notes) do
        if n.level == vim.log.levels.ERROR then
          errored = true
        end
      end
      assert.is_true(errored, "expected an ERROR notification")
      assert.are.equal("beads://new", vim.api.nvim_buf_get_name(buf))
      assert.is_true(vim.bo[buf].modified, "buffer should keep the user's edits (modified)")
    end)
  end)

  it("whitespace-only title is treated as empty", function()
    in_repo(function()
      vim.cmd("Beads create")
      local buf = wait_new_buffer()
      set_title(buf, "   ")
      calls, notes = {}, {}
      vim.api.nvim_set_current_buf(buf)
      pcall(vim.cmd.write)
      vim.wait(500)
      assert.are.same({}, bd_writes(), "no data-changing bd call may be made for a blank title")
      assert.are.equal("beads://new", vim.api.nvim_buf_get_name(buf))
    end)
  end)

  it("exactly one bd process mutates for a create with every field set", function()
    in_repo(function(dir)
      local parent = create(dir, "Full parent", { "-t", "epic" })
      local blocker = create(dir, "Full blocker")
      vim.cmd("Beads create")
      local buf = wait_new_buffer()
      local title = "Full create " .. tostring(vim.uv.hrtime())
      set_title(buf, title)
      set_prefixed(buf, "priority:", "priority: 1")
      set_prefixed(buf, "type:", "type: bug")
      set_prefixed(buf, "assignee:", "assignee: alice")
      set_prefixed(buf, "labels:", "labels: [alpha, beta]")
      set_prefixed(buf, "parent:", "parent: " .. parent)
      set_prefixed(buf, "blocked_by:", "blocked_by: [" .. blocker .. "]")
      fill_section(buf, "## Description", { "full description" })
      fill_section(buf, "## Design", { "full design" })
      fill_section(buf, "## Acceptance", { "full acceptance" })

      calls, notes = {}, {}
      local id = write_and_wait_rename(buf)
      wait_for(function()
        return has_line(buf, "id: " .. id) and not vim.bo[buf].modified
      end, "reload after create")

      assert.are.equal(1, #calls_of("create"), "expected exactly one 'bd create'")
      for _, sub in ipairs({ "update", "batch", "dep", "label", "comment", "close" }) do
        assert.are.equal(0, #calls_of(sub), "unexpected 'bd " .. sub .. "' during create")
      end
      -- nothing touches the placeholder id before the create
      for _, argv in ipairs(bd_calls()) do
        local sub = subcommand(argv)
        if sub == "create" then
          break
        end
        assert.is_false(vim.tbl_contains(argv, "new"), "bd called with id 'new' before create: " .. table.concat(argv, " "))
      end

      local b = show(dir, id)
      assert.are.equal(title, b.title)
      assert.are.equal(1, tonumber(b.priority))
      assert.are.equal("bug", b.type)
      assert.are.equal("alice", b.assignee)
      table.sort(b.labels)
      assert.are.same({ "alpha", "beta" }, b.labels)
      assert.are.equal(parent, b.parent)
      assert.is_true(vim.tbl_contains(b.blocked_by or {}, blocker), "blocked_by lacks " .. blocker)
      assert.are.equal("full description", vim.trim(b.description or ""))
      assert.are.equal("full design", vim.trim(b.design or ""))
      assert.are.equal("full acceptance", vim.trim(b.acceptance or ""))
    end)
  end)

  it("cleans up the shared repo", function()
    if shared_dir then
      vim.fn.delete(shared_dir, "rf")
      shared_dir = nil
    end
  end)
end)
