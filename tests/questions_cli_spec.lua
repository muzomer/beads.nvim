-- Interface under test (bead beads_nvim-4gx.2): bin/beads-ask, the agent-facing CLI
-- over lua/beads/questions/store.lua.
--   beads-ask list [--needs agent|user] [--json]   -> --json: JSON array of threads
--   beads-ask show <tid> [--json]                  -> --json: JSON thread object
--   beads-ask reply <tid> <body | ->
--   beads-ask resolve <tid> [note]
--   beads-ask propose <tid> --field <title|description|design|acceptance> <value | ->
--   all accept --author NAME (default "agent"); root = $BEADS_NVIM_ROOT, else the
--   nearest directory above cwd containing .beads.
--   "user" as author, and any reopen/delete subcommand, exit non-zero with a message
--   on stderr and leave questions.json untouched.
-- Threads are seeded through the store directly; every CLI call runs with cwd in a
-- temp dir and an explicit BEADS_NVIM_ROOT so the real repo is never touched.

local qs = require("beads.questions.store")

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local bin = plugin_root .. "/bin/beads-ask"

local function run(cwd, args, opts)
  opts = opts or {}
  local cmd = { bin }
  vim.list_extend(cmd, args)
  local env = { BEADS_NVIM_ROOT = opts.env_root ~= nil and opts.env_root or cwd }
  local r = vim.system(cmd, { cwd = cwd, stdin = opts.stdin, text = true, env = env }):wait(10000)
  return r.code, r.stdout or "", r.stderr or ""
end

local function json(root, args)
  local a = vim.deepcopy(args)
  a[#a + 1] = "--json"
  local code, out, err = run(root, a)
  assert(code == 0, "exit " .. tostring(code) .. ": " .. err)
  local ok, data = pcall(vim.json.decode, out)
  assert(ok, "not JSON: " .. out)
  return data
end

local function qfile(root)
  return root .. "/.beads-nvim/questions.json"
end

local function snapshot(root)
  return table.concat(vim.fn.readfile(qfile(root), "b"), "\n")
end

local function last(t)
  return t.messages[#t.messages]
end

describe("beads-ask CLI", function()
  local roots = {}
  local function new_root()
    local r = vim.fn.tempname()
    vim.fn.mkdir(r, "p")
    roots[#roots + 1] = r
    return r
  end

  -- t1: needs agent (last author user); t2: needs user (last author agent)
  local function seeded()
    local root = new_root()
    local t1 = qs.add(root, { bead = "bd-1", section = "Design", messages = { { author = "user", body = "why this?" } } })
    local t2 = qs.add(root, {
      bead = "bd-2",
      messages = { { author = "user", body = "q" }, { author = "agent", body = "answer" } },
    })
    return root, t1, t2
  end

  after_each(function()
    for _, r in ipairs(roots) do
      vim.fn.delete(r, "rf")
    end
    roots = {}
  end)

  describe("subcommands", function()
    it("list --json returns all threads as a JSON array", function()
      local root, t1, t2 = seeded()
      local list = json(root, { "list" })
      assert.is_true(vim.islist(list))
      local ids = {}
      for _, t in ipairs(list) do
        ids[t.id] = true
      end
      assert.is_true(ids[t1.id] and ids[t2.id])
    end)

    it("list --needs agent / --needs user filter threads", function()
      local root, t1, t2 = seeded()
      local a = json(root, { "list", "--needs", "agent" })
      assert.equals(1, #a)
      assert.equals(t1.id, a[1].id)
      local u = json(root, { "list", "--needs", "user" })
      assert.equals(1, #u)
      assert.equals(t2.id, u[1].id)
    end)

    it("list without --json exits 0 and mentions the thread ids", function()
      local root, t1 = seeded()
      local code, out, err = run(root, { "list" })
      assert.equals(0, code, err)
      assert.is_truthy(out:find(t1.id, 1, true), out)
    end)

    it("show --json returns the thread object", function()
      local root, t1 = seeded()
      local t = json(root, { "show", t1.id })
      assert.equals(t1.id, t.id)
      assert.equals("bd-1", t.bead)
      assert.equals("why this?", t.messages[1].body)
    end)

    it("show without --json prints the message bodies", function()
      local root, t1 = seeded()
      local code, out, err = run(root, { "show", t1.id })
      assert.equals(0, code, err)
      assert.is_truthy(out:find("why this?", 1, true), out)
    end)

    it("show of an unknown thread exits non-zero", function()
      local root = seeded()
      local code, _, err = run(root, { "show", "t999" })
      assert.is_not.equals(0, code)
      assert.is_true(#err > 0)
    end)

    it("reply appends a message authored by 'agent' by default", function()
      local root, t1 = seeded()
      local code, _, err = run(root, { "reply", t1.id, "because" })
      assert.equals(0, code, err)
      local t = qs.get(root, t1.id)
      assert.equals(2, #t.messages)
      assert.equals("agent", last(t).author)
      assert.equals("because", last(t).body)
      assert.equals("user", t.needs)
    end)

    it("reply --author records the given author", function()
      local root, t1 = seeded()
      local code, _, err = run(root, { "reply", t1.id, "hi", "--author", "claude" })
      assert.equals(0, code, err)
      assert.equals("claude", last(qs.get(root, t1.id)).author)
    end)

    it("reply to an unknown thread exits non-zero and changes nothing", function()
      local root = seeded()
      local before = snapshot(root)
      local code = run(root, { "reply", "t999", "x" })
      assert.is_not.equals(0, code)
      assert.equals(before, snapshot(root))
    end)

    it("resolve marks the thread resolved with needs 'none'", function()
      local root, t1 = seeded()
      local code, _, err = run(root, { "resolve", t1.id })
      assert.equals(0, code, err)
      local t = json(root, { "show", t1.id })
      assert.equals("resolved", t.status)
      assert.equals("none", t.needs)
    end)

    it("resolve with a note appends the note as a message, then resolves", function()
      local root, t1 = seeded()
      local code, _, err = run(root, { "resolve", t1.id, "fixed in design" })
      assert.equals(0, code, err)
      local t = qs.get(root, t1.id)
      assert.equals("resolved", t.status)
      assert.equals("fixed in design", last(t).body)
      assert.equals("agent", last(t).author)
    end)

    it("finds the root from the nearest .beads above cwd when BEADS_NVIM_ROOT is empty", function()
      local root, t1 = seeded()
      vim.fn.mkdir(root .. "/.beads", "p")
      vim.fn.mkdir(root .. "/sub/dir", "p")
      local code, out, err = run(root .. "/sub/dir", { "list", "--json" }, { env_root = "" })
      assert.equals(0, code, err)
      local list = vim.json.decode(out)
      assert.equals(2, #list)
      code, _, err = run(root .. "/sub/dir", { "reply", t1.id, "from subdir" }, { env_root = "" })
      assert.equals(0, code, err)
      assert.equals("from subdir", last(qs.get(root, t1.id)).body)
    end)
  end)

  describe("refusals", function()
    local function refused(root, args)
      local before = snapshot(root)
      local code, _, err = run(root, args)
      assert.is_not.equals(0, code)
      assert.is_true(#vim.trim(err) > 0, "expected a message on stderr")
      assert.equals(before, snapshot(root))
      return err
    end

    it("reply --author user is refused", function()
      local root, t1 = seeded()
      local err = refused(root, { "reply", t1.id, "pretend", "--author", "user" })
      assert.is_truthy(err:find("user", 1, true), err)
    end)

    it("propose --author user is refused", function()
      local root, t1 = seeded()
      local err = refused(root, { "propose", t1.id, "--field", "title", "New", "--author", "user" })
      assert.is_truthy(err:find("user", 1, true), err)
    end)

    it("reopen is refused", function()
      local root, t1 = seeded()
      qs.resolve(root, t1.id)
      refused(root, { "reopen", t1.id })
      assert.equals("resolved", qs.get(root, t1.id).status)
    end)

    it("delete is refused", function()
      local root, t1 = seeded()
      refused(root, { "delete", t1.id })
      assert.is_table(qs.get(root, t1.id))
    end)
  end)

  describe("propose", function()
    for _, field in ipairs({ "title", "description", "design", "acceptance" }) do
      it("stores {field, value} on a new agent message for field " .. field, function()
        local root, t1 = seeded()
        local code, _, err = run(root, { "propose", t1.id, "--field", field, "new " .. field })
        assert.equals(0, code, err)
        local t = qs.get(root, t1.id)
        assert.equals(2, #t.messages)
        local m = last(t)
        assert.equals("agent", m.author)
        assert.is_table(m.proposal)
        assert.equals(field, m.proposal.field)
        assert.equals("new " .. field, m.proposal.value)
        assert.equals("user", t.needs)
      end)
    end

    it("an unknown field exits non-zero and changes nothing", function()
      local root, t1 = seeded()
      local before = snapshot(root)
      local code, _, err = run(root, { "propose", t1.id, "--field", "status", "closed" })
      assert.is_not.equals(0, code)
      assert.is_true(#vim.trim(err) > 0)
      assert.equals(before, snapshot(root))
    end)
  end)

  describe("body from stdin", function()
    it("reply - reads a multi-line body from stdin", function()
      local root, t1 = seeded()
      local code, _, err = run(root, { "reply", t1.id, "-" }, { stdin = "line one\nline two\n" })
      assert.equals(0, code, err)
      local body = last(qs.get(root, t1.id)).body
      assert.equals("line one\nline two", (body:gsub("\n+$", "")))
    end)

    it("propose - reads a multi-line value from stdin", function()
      local root, t1 = seeded()
      local code, _, err =
        run(root, { "propose", t1.id, "--field", "design", "-" }, { stdin = "## A\n\n- b\n- c\n" })
      assert.equals(0, code, err)
      local m = last(qs.get(root, t1.id))
      assert.equals("design", m.proposal.field)
      assert.equals("## A\n\n- b\n- c", (m.proposal.value:gsub("\n+$", "")))
    end)
  end)
end)
