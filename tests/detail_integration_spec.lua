-- Bead beads_nvim-ge7.8: detail buffer beads://<id> (lua/beads/views/detail.lua + buffer/write.lua).
-- Interface under test (public entry points only):
--   * plugin/beads.lua registers BufReadCmd/BufWriteCmd for "beads://*":
--       :e beads://<id>  -> async 'bd show <id> --json --include-comments', rendered, filetype markdown,
--                            'modified' off after load.
--       :w               -> at most one 'bd update' (text via temp files), then one 'bd batch' for deps;
--                            buffer reloaded afterwards; failures reported via vim.notify.
--   * buffer-local normal-mode keys: x (close, reason via vim.ui.input), C (claim), yy (yank id into
--     the unnamed register), yr (yank workflow.run_command(bead) into the unnamed register), g? (help).
--   * ':Beads show <id>' opens beads://<id>.
-- The bd root is taken from beads.cli (cli.set_root).

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local helpers = require("tests.helpers")
local cli = require("beads.cli")
local model = require("beads.model")
local workflow = require("beads.workflow")

local TIMEOUT = 15000

local function bd(dir, args)
  local argv = { "bd", "-C", dir }
  vim.list_extend(argv, args)
  local r = vim.system(argv, { text = true }):wait()
  assert.are.equal(0, r.code, "bd " .. table.concat(args, " ") .. " failed: " .. tostring(r.stderr))
  return r.stdout
end

local function raw_show(dir, id)
  return vim.json.decode(bd(dir, { "show", id, "--json" }))[1]
end

local function show(dir, id)
  return model.normalize(raw_show(dir, id))
end

local function create(dir, title, extra)
  local args = { "create", title, "--silent" }
  vim.list_extend(args, extra or {})
  return vim.trim(bd(dir, args))
end

local function buf_lines(buf)
  return vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)
end

local function has_line(buf, line)
  return vim.tbl_contains(buf_lines(buf), line)
end

local function line_with_prefix(buf, prefix)
  for _, l in ipairs(buf_lines(buf)) do
    if vim.startswith(l, prefix) then
      return l
    end
  end
end

local function set_line(buf, pred, new)
  local lines = buf_lines(buf)
  for i, l in ipairs(lines) do
    if pred(l) then
      vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { new })
      return
    end
  end
  error("no matching line to edit")
end

local function wait_for(fn, msg)
  local ok = vim.wait(TIMEOUT, function()
    local pok, v = pcall(fn)
    return pok and v
  end, 20)
  assert.is_true(ok, "timed out waiting for: " .. msg)
end

-- Spies (pass-through) on vim.system and vim.notify.
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

-- bd subcommand of a recorded argv: first token after "bd" and the "-C <dir>" pair, skipping flags.
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

local function wipe_beads_buffers()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.startswith(vim.api.nvim_buf_get_name(b), "beads://") then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
end

-- One temp bd repo shared by the whole file ('bd init' is slow and plenary times out a file
-- after 50s); each test uses its own beads. Removed by the last test.
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

-- Runs fn(dir) with cli root set to the shared repo and spies installed; always cleans up.
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

local function open(id, title)
  -- fail fast (instead of a long wait) when the beads:// handler does not exist
  assert(#vim.api.nvim_get_autocmds({ event = "BufReadCmd", pattern = "beads://*" }) > 0, "no beads:// BufReadCmd")
  vim.cmd.edit(vim.fn.fnameescape("beads://" .. id))
  local buf = vim.api.nvim_get_current_buf()
  wait_for(function()
    return has_line(buf, "# " .. title) and not vim.bo[buf].modified
  end, "beads://" .. id .. " to load")
  return buf
end

local function write_and_wait(buf, cond, msg)
  vim.api.nvim_set_current_buf(buf)
  vim.cmd.write()
  wait_for(cond, msg)
end

describe("beads detail buffer (beads://<id>)", function()
  if not helpers.has_bd() then
    pending("bd executable not found")
    return
  end

  if vim.fn.exists(":Beads") ~= 2 then
    vim.cmd.source(root .. "/plugin/beads.lua")
  end

  it("registers BufReadCmd and BufWriteCmd for beads://*", function()
    local read = vim.api.nvim_get_autocmds({ event = "BufReadCmd", pattern = "beads://*" })
    local write = vim.api.nvim_get_autocmds({ event = "BufWriteCmd", pattern = "beads://*" })
    assert.is_true(#read > 0, "no BufReadCmd autocmd for beads://*")
    assert.is_true(#write > 0, "no BufWriteCmd autocmd for beads://*")
  end)

  it(":e beads://<id> shows the rendered bead, markdown, modified off", function()
    in_repo(function(dir)
      local id = create(dir, "Render me", { "-p", "1", "-l", "alpha" })
      local buf = open(id, "Render me")
      assert.is_true(has_line(buf, "id: " .. id))
      assert.is_true(has_line(buf, "priority: 1"))
      assert.is_true(has_line(buf, "labels: [alpha]"))
      assert.is_true(has_line(buf, "## Description"))
      assert.equals("markdown", vim.bo[buf].filetype)
      assert.is_false(vim.bo[buf].modified)
      assert.equals("beads://" .. id, vim.api.nvim_buf_get_name(buf))
    end)
  end)

  it("detail load calls bd show with --include-comments and renders comments", function()
    in_repo(function(dir)
      local id = create(dir, "Has comment")
      bd(dir, { "comments", "add", id, "a detail comment body" })
      local buf = open(id, "Has comment")

      local found = false
      for _, argv in ipairs(calls_of("show")) do
        if vim.tbl_contains(argv, id) and vim.tbl_contains(argv, "--include-comments") then
          found = true
        end
      end
      assert.is_true(found, "no 'bd show " .. id .. " --include-comments' call: " .. vim.inspect(calls))

      local lines = buf_lines(buf)
      local comments_at, text_at
      for i, l in ipairs(lines) do
        if l == "## Comments" then
          comments_at = i
        elseif l == "a detail comment body" then
          text_at = i
        end
      end
      assert.is_not_nil(comments_at, "no ## Comments section")
      assert.is_not_nil(text_at, "comment text not shown")
      assert.is_true(text_at > comments_at, "comment text not inside Comments section")
    end)
  end)

  it("changing title and status then :w runs exactly one bd update and applies both", function()
    in_repo(function(dir)
      local id = create(dir, "Old title")
      local buf = open(id, "Old title")
      set_line(buf, function(l)
        return l == "# Old title"
      end, "# New title")
      set_line(buf, function(l)
        return vim.startswith(l, "status:")
      end, "status: in_progress")
      calls = {}

      write_and_wait(buf, function()
        return has_line(buf, "# New title") and has_line(buf, "status: in_progress") and not vim.bo[buf].modified
      end, "write + reload")
      -- let any stray follow-up calls land before counting
      vim.wait(300)

      assert.equals(1, #calls_of("update"), "bd update calls: " .. vim.inspect(calls_of("update")))
      local after = show(dir, id)
      assert.equals("New title", after.title)
      assert.equals("in_progress", after.status)
    end)
  end)

  it("adding a blocked_by id then :w creates the blocks dependency", function()
    in_repo(function(dir)
      local blocker = create(dir, "Blocker")
      local id = create(dir, "Blocked one")
      local buf = open(id, "Blocked one")
      set_line(buf, function(l)
        return vim.startswith(l, "blocked_by:")
      end, "blocked_by: [" .. blocker .. "]")

      write_and_wait(buf, function()
        return vim.tbl_contains(show(dir, id).blocked_by, blocker)
      end, "blocks dependency in bd")
      wait_for(function()
        return has_line(buf, "blocked_by: [" .. blocker .. "]") and not vim.bo[buf].modified
      end, "buffer reload after :w")
    end)
  end)

  it("batch failure after a successful update reloads the buffer and reports the dep part", function()
    in_repo(function(dir)
      local a = create(dir, "Cycle A")
      local b = create(dir, "Cycle B")
      bd(dir, { "dep", "add", b, a }) -- b blocked by a; adding a blocked by b is a cycle -> batch fails
      local buf = open(a, "Cycle A")
      set_line(buf, function(l)
        return l == "# Cycle A"
      end, "# Cycle A renamed")
      set_line(buf, function(l)
        return vim.startswith(l, "blocked_by:")
      end, "blocked_by: [" .. b .. "]")

      write_and_wait(buf, function()
        return has_line(buf, "# Cycle A renamed") and not vim.bo[buf].modified
      end, "reload after partial write")

      local after = show(dir, a)
      assert.equals("Cycle A renamed", after.title)
      assert.is_false(vim.tbl_contains(after.blocked_by, b))
      assert.equals("blocked_by: []", line_with_prefix(buf, "blocked_by:"))

      wait_for(function()
        for _, n in ipairs(notes) do
          local m = n.msg:lower()
          if (n.level or 0) >= vim.log.levels.WARN and (m:find("dep", 1, true) or m:find("blocked_by", 1, true)) then
            return true
          end
        end
      end, "warning/error notification naming the dependency part; got " .. vim.inspect(notes))
    end)
  end)

  it("edits in Notes are reverted on :w with a warning", function()
    in_repo(function(dir)
      local id = create(dir, "Noted", { "--notes", "original note text" })
      local buf = open(id, "Noted")
      assert.is_true(has_line(buf, "original note text"))
      set_line(buf, function(l)
        return l == "original note text"
      end, "tampered note text")

      write_and_wait(buf, function()
        return has_line(buf, "original note text") and not has_line(buf, "tampered note text") and not vim.bo[buf].modified
      end, "Notes reverted in buffer")

      assert.equals("original note text", show(dir, id).notes)
      local warned = false
      for _, n in ipairs(notes) do
        if n.level == vim.log.levels.WARN and n.msg:find("Notes", 1, true) then
          warned = true
        end
      end
      assert.is_true(warned, "no WARN mentioning Notes: " .. vim.inspect(notes))
    end)
  end)

  describe("buffer-local keys", function()
    local KEYS = { "x", "C", "yy", "yr", "g?" }

    it("x, C, yy, yr, g? are buffer-local normal-mode mappings", function()
      in_repo(function(dir)
        local id = create(dir, "Keyed")
        local buf = open(id, "Keyed")
        for _, k in ipairs(KEYS) do
          local m = vim.fn.maparg(k, "n", false, true)
          assert.equals(1, m.buffer, "no buffer-local mapping for " .. k)
        end
        assert.equals(buf, vim.api.nvim_get_current_buf())
      end)
    end)

    it("yy yanks the bead id", function()
      in_repo(function(dir)
        local id = create(dir, "Yank id")
        open(id, "Yank id")
        vim.fn.setreg('"', "")
        vim.cmd.normal("yy")
        wait_for(function()
          return vim.fn.getreg('"') == id
        end, "unnamed register == id; got " .. vim.inspect(vim.fn.getreg('"')))
      end)
    end)

    it("yr yanks the workflow run command", function()
      in_repo(function(dir)
        local id = create(dir, "Yank run")
        open(id, "Yank run")
        local want = workflow.run_command(show(dir, id))
        vim.fn.setreg('"', "")
        vim.cmd.normal("yr")
        wait_for(function()
          return vim.fn.getreg('"') == want
        end, "unnamed register == " .. want .. "; got " .. vim.inspect(vim.fn.getreg('"')))
      end)
    end)

    it("C claims the bead", function()
      in_repo(function(dir)
        local id = create(dir, "Claim me")
        open(id, "Claim me")
        vim.cmd.normal("C")
        wait_for(function()
          local b = show(dir, id)
          return b.status == "in_progress" and b.assignee ~= nil and b.assignee ~= ""
        end, "bead claimed in bd")
      end)
    end)

    it("x closes the bead with the reason from the prompt", function()
      in_repo(function(dir)
        local id = create(dir, "Close me")
        open(id, "Close me")
        local orig_input = vim.ui.input
        vim.ui.input = function(_, on_confirm)
          on_confirm("finished via detail")
        end
        local ok, err = pcall(function()
          vim.cmd.normal("x")
          wait_for(function()
            return raw_show(dir, id).status == "closed"
          end, "bead closed in bd")
        end)
        vim.ui.input = orig_input
        assert(ok, err)
        assert.equals("finished via detail", raw_show(dir, id).close_reason)
      end)
    end)

    it("g? lists x, C, yy, yr", function()
      in_repo(function(dir)
        local id = create(dir, "Help me")
        local buf = open(id, "Help me")
        local before = {}
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          before[b] = true
        end
        vim.cmd("messages clear")
        vim.cmd.normal("g?")
        vim.wait(300)

        local chunks = {}
        for _, n in ipairs(notes) do
          chunks[#chunks + 1] = n.msg
        end
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          if not before[b] and b ~= buf and vim.api.nvim_buf_is_valid(b) then
            vim.list_extend(chunks, buf_lines(b))
          end
        end
        chunks[#chunks + 1] = vim.api.nvim_exec2("messages", { output = true }).output
        local text = " " .. table.concat(chunks, "\n") .. " "

        for _, k in ipairs({ "x", "C", "yy", "yr" }) do
          assert.is_truthy(
            text:find("%f[%w]" .. vim.pesc(k) .. "%f[%W]"),
            "help does not list key " .. k .. ": " .. text
          )
        end
      end)
    end)
  end)

  it(":Beads show <id> opens beads://<id>", function()
    in_repo(function(dir)
      local id = create(dir, "Via command")
      vim.cmd("Beads show " .. id)
      local buf = vim.api.nvim_get_current_buf()
      assert.equals("beads://" .. id, vim.api.nvim_buf_get_name(buf))
      wait_for(function()
        return has_line(buf, "# Via command")
      end, ":Beads show to load the bead")
    end)
  end)

  it("cleanup: removes the shared temp repo", function()
    if shared_dir then
      vim.fn.delete(shared_dir, "rf")
      shared_dir = nil
    end
  end)
end)
