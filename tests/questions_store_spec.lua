-- Interface under test (bead beads_nvim-4gx.1): lua/beads/questions/store.lua
--   local qs = require("beads.questions.store")
--   File: <root>/.beads-nvim/questions.json (dir gets a .gitignore containing '*').
--   Thread: {id, bead, section?, quote?, status = "open"|"resolved",
--            needs = "agent"|"user"|"none", messages = {{id, author, ts, body, proposal?}}}
--   qs.add(root, thread) -> stored thread (with id, status, needs, message ids/ts filled in)
--       thread = {bead, section?, quote?, messages = {{author, body, proposal?}}}
--   qs.get(root, tid) -> thread | nil
--   qs.list(root, filter?) -> list of threads; filter keys (all optional): bead, needs, status
--   qs.reply(root, tid, author, body, proposal?)
--   qs.resolve(root, tid)
--   needs: last author 'user' -> 'agent', any other author -> 'user'; resolved -> 'none'.

local qs = require("beads.questions.store")

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function new_root()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

local function qfile(root)
  return root .. "/.beads-nvim/questions.json"
end

local function read_json(path)
  local lines = vim.fn.readfile(path)
  return vim.json.decode(table.concat(lines, "\n"))
end

local function file_threads(root)
  local data = read_json(qfile(root))
  -- accept either a bare list of threads or {threads = [...]}
  if data.threads then
    return data.threads
  end
  return data
end

local function find(threads, tid)
  for _, t in ipairs(threads) do
    if t.id == tid then
      return t
    end
  end
end

describe("beads.questions.store", function()
local roots = {}
local function root_for_test()
  local r = new_root()
  table.insert(roots, r)
  return r
end

after_each(function()
  for _, r in ipairs(roots) do
    vim.fn.delete(r, "rf")
  end
  roots = {}
end)

describe("questions store round-trip", function()
  it("add stores a thread in questions.json and get/list return it", function()
    local root = root_for_test()
    local t = qs.add(root, {
      bead = "bd-1",
      section = "Design",
      quote = "some text",
      messages = { { author = "user", body = "why?" } },
    })
    assert.is_table(t)
    assert.is_truthy(t.id)
    assert.equals(1, vim.fn.filereadable(qfile(root)))

    local onfile = find(file_threads(root), t.id)
    assert.is_table(onfile)
    assert.equals("bd-1", onfile.bead)
    assert.equals("Design", onfile.section)
    assert.equals("some text", onfile.quote)
    assert.equals("open", onfile.status)
    assert.equals(1, #onfile.messages)
    assert.equals("why?", onfile.messages[1].body)
    assert.equals("user", onfile.messages[1].author)
    assert.is_truthy(onfile.messages[1].id)
    assert.is_truthy(onfile.messages[1].ts)

    local got = qs.get(root, t.id)
    assert.equals(t.id, got.id)
    assert.equals("why?", got.messages[1].body)
    assert.equals(1, #qs.list(root))
  end)

  it("reply appends a message (with proposal) that survives a re-read from the file", function()
    local root = root_for_test()
    local t = qs.add(root, { bead = "bd-1", messages = { { author = "user", body = "q" } } })
    qs.reply(root, t.id, "agent", "answer", { field = "design", value = "new design" })
    qs.reply(root, t.id, "user", "thanks")

    local onfile = find(file_threads(root), t.id)
    assert.equals(3, #onfile.messages)
    assert.equals("answer", onfile.messages[2].body)
    assert.equals("agent", onfile.messages[2].author)
    assert.same({ field = "design", value = "new design" }, onfile.messages[2].proposal)
    assert.equals("thanks", onfile.messages[3].body)
    assert.is_nil(onfile.messages[3].proposal)

    local got = qs.get(root, t.id)
    assert.equals(3, #got.messages)
    assert.same({ field = "design", value = "new design" }, got.messages[2].proposal)
  end)

  it("resolve marks the thread resolved in the file", function()
    local root = root_for_test()
    local t = qs.add(root, { bead = "bd-1", messages = { { author = "user", body = "q" } } })
    qs.resolve(root, t.id)
    assert.equals("resolved", find(file_threads(root), t.id).status)
    assert.equals("resolved", qs.get(root, t.id).status)
  end)

  it("thread ids and message ids are unique", function()
    local root = root_for_test()
    local tids, mids = {}, {}
    for i = 1, 20 do
      local t = qs.add(root, { bead = "bd-" .. (i % 3), messages = { { author = "user", body = "q" .. i } } })
      assert.is_nil(tids[t.id], "duplicate thread id " .. tostring(t.id))
      tids[t.id] = true
      qs.reply(root, t.id, "agent", "a" .. i)
    end
    local threads = qs.list(root)
    assert.equals(20, #threads)
    for _, t in ipairs(threads) do
      for _, m in ipairs(t.messages) do
        assert.is_truthy(m.id)
        local key = t.id .. "/" .. m.id
        assert.is_nil(mids[key], "duplicate message id " .. key)
        mids[key] = true
      end
      -- message ids unique within a thread
      assert.are_not.equal(t.messages[1].id, t.messages[2].id)
    end
  end)

  it("get returns nil for an unknown thread id", function()
    local root = root_for_test()
    qs.add(root, { bead = "bd-1", messages = { { author = "user", body = "q" } } })
    assert.is_nil(qs.get(root, "no-such-thread"))
  end)

  it("list filters by bead, needs and status", function()
    local root = root_for_test()
    local a = qs.add(root, { bead = "bd-1", messages = { { author = "user", body = "q1" } } })
    local b = qs.add(root, { bead = "bd-2", messages = { { author = "agent", body = "q2" } } })
    local c = qs.add(root, { bead = "bd-1", messages = { { author = "user", body = "q3" } } })
    qs.resolve(root, c.id)

    local function ids(list)
      local out = {}
      for _, t in ipairs(list) do
        table.insert(out, t.id)
      end
      table.sort(out)
      return out
    end
    local function sorted(l)
      table.sort(l)
      return l
    end

    assert.same(sorted({ a.id, c.id }), ids(qs.list(root, { bead = "bd-1" })))
    assert.same({ a.id }, ids(qs.list(root, { needs = "agent" })))
    assert.same({ b.id }, ids(qs.list(root, { needs = "user" })))
    assert.same({ c.id }, ids(qs.list(root, { status = "resolved" })))
    assert.same(sorted({ a.id, b.id }), ids(qs.list(root, { status = "open" })))
    assert.same(sorted({ a.id, b.id, c.id }), ids(qs.list(root, {})))
  end)
end)

describe("questions store needs", function()
  it("is 'agent' after a user message and 'user' after an agent message", function()
    local root = root_for_test()
    local t = qs.add(root, { bead = "bd-1", messages = { { author = "user", body = "q" } } })
    assert.equals("agent", t.needs)
    assert.equals("agent", qs.get(root, t.id).needs)
    assert.equals("agent", find(file_threads(root), t.id).needs)

    qs.reply(root, t.id, "agent", "a")
    assert.equals("user", qs.get(root, t.id).needs)
    assert.equals("user", find(file_threads(root), t.id).needs)

    qs.reply(root, t.id, "user", "more")
    assert.equals("agent", qs.get(root, t.id).needs)
  end)

  it("treats any non-user author as an agent", function()
    local root = root_for_test()
    local t = qs.add(root, { bead = "bd-1", messages = { { author = "claude", body = "q from agent" } } })
    assert.equals("user", qs.get(root, t.id).needs)
    qs.reply(root, t.id, "user", "answer")
    assert.equals("agent", qs.get(root, t.id).needs)
    qs.reply(root, t.id, "codex", "reply")
    assert.equals("user", qs.get(root, t.id).needs)
  end)

  it("is 'none' for resolved threads", function()
    local root = root_for_test()
    local t = qs.add(root, { bead = "bd-1", messages = { { author = "user", body = "q" } } })
    qs.resolve(root, t.id)
    assert.equals("none", qs.get(root, t.id).needs)
    assert.equals("none", find(file_threads(root), t.id).needs)
  end)
end)

describe("questions store .gitignore", function()
  it("creates .beads-nvim/.gitignore containing '*' on first write", function()
    local root = root_for_test()
    assert.equals(0, vim.fn.isdirectory(root .. "/.beads-nvim"))
    qs.add(root, { bead = "bd-1", messages = { { author = "user", body = "q" } } })
    local gi = root .. "/.beads-nvim/.gitignore"
    assert.equals(1, vim.fn.filereadable(gi))
    local lines = vim.tbl_map(vim.trim, vim.fn.readfile(gi))
    assert.is_true(vim.tbl_contains(lines, "*"))
  end)

  it("reads do not create the directory", function()
    local root = root_for_test()
    assert.same({}, qs.list(root))
    assert.is_nil(qs.get(root, "x"))
    assert.equals(0, vim.fn.isdirectory(root .. "/.beads-nvim"))
  end)
end)

describe("questions store missing or corrupt file", function()
  it("missing file reads as no threads", function()
    local root = root_for_test()
    local ok, res = pcall(qs.list, root)
    assert.is_true(ok, tostring(res))
    assert.same({}, res)
    local ok2, got = pcall(qs.get, root, "t1")
    assert.is_true(ok2, tostring(got))
    assert.is_nil(got)
  end)

  local corrupt = {
    garbage = "{not json at all",
    empty = "",
    wrong_shape = '"just a string"',
    truncated = '[{"id":"t1","bead":"bd-1","messages":[',
  }
  for name, content in pairs(corrupt) do
    it("corrupt file (" .. name .. ") reads as no threads", function()
      local root = root_for_test()
      vim.fn.mkdir(root .. "/.beads-nvim", "p")
      local f = assert(io.open(qfile(root), "w"))
      f:write(content)
      f:close()
      local ok, res = pcall(qs.list, root)
      assert.is_true(ok, tostring(res))
      assert.same({}, res)
      local ok2, got = pcall(qs.get, root, "t1")
      assert.is_true(ok2, tostring(got))
      assert.is_nil(got)
    end)
  end
end)

describe("questions store concurrent writers", function()
  -- Writer script run in a separate headless nvim process.
  -- args: plugin_root, root, tid, tag, n
  local WRITER = [[
local plugin_root, root, tid, tag, n = _G.arg[1], _G.arg[2], _G.arg[3], _G.arg[4], tonumber(_G.arg[5])
package.path = plugin_root .. "/lua/?.lua;" .. plugin_root .. "/lua/?/init.lua;" .. package.path
vim.opt.rtp:prepend(plugin_root)
local qs = require("beads.questions.store")
local go = root .. "/go"
local i = 0
while vim.fn.filereadable(go) == 0 and i < 500 do
  vim.uv.sleep(5)
  i = i + 1
end
for k = 1, n do
  qs.reply(root, tid, tag, tag .. "-reply-" .. k)
  qs.add(root, { bead = "bd-" .. tag, messages = { { author = "user", body = tag .. "-add-" .. k } } })
end
io.stdout:write("done\n")
]]

  it("two nvim processes writing at once lose no message and keep the file valid", function()
    local root = root_for_test()
    local t = qs.add(root, { bead = "bd-0", messages = { { author = "user", body = "start" } } })
    local script = root .. "/writer.lua"
    vim.fn.writefile(vim.split(WRITER, "\n", { plain = true }), script)

    local n = 25
    local procs = {}
    for _, tag in ipairs({ "w1", "w2" }) do
      table.insert(
        procs,
        vim.system(
          { vim.v.progpath, "--clean", "--headless", "-l", script, plugin_root, root, t.id, tag, tostring(n) },
          { text = true }
        )
      )
    end
    vim.fn.writefile({ "" }, root .. "/go")
    -- one shared deadline so a stuck lock cannot outlive plenary's per-file timeout;
    -- a timed-out wait kills the writer, so no process is left behind
    local deadline = vim.uv.hrtime() / 1e6 + 20000
    local results = {}
    for i, p in ipairs(procs) do
      local remaining = math.floor(deadline - vim.uv.hrtime() / 1e6)
      results[i] = p:wait(math.max(1, remaining))
    end
    for i, res in ipairs(results) do
      assert.equals(0, res.code, "writer " .. i .. " failed: " .. tostring(res.stderr) .. tostring(res.stdout))
    end

    -- file is valid JSON
    local ok, threads = pcall(file_threads, root)
    assert.is_true(ok, "questions.json is not valid JSON: " .. tostring(threads))

    -- no reply lost
    local thread = qs.get(root, t.id)
    local bodies = {}
    for _, m in ipairs(thread.messages) do
      bodies[m.body] = true
    end
    assert.equals(1 + 2 * n, #thread.messages)
    for _, tag in ipairs({ "w1", "w2" }) do
      for k = 1, n do
        assert.is_true(bodies[tag .. "-reply-" .. k] == true, "lost " .. tag .. "-reply-" .. k)
      end
    end

    -- no added thread lost, ids unique
    local all = qs.list(root)
    assert.equals(1 + 2 * n, #all)
    local seen, added = {}, {}
    for _, th in ipairs(all) do
      assert.is_nil(seen[th.id], "duplicate thread id " .. tostring(th.id))
      seen[th.id] = true
      added[th.messages[1].body] = true
    end
    for _, tag in ipairs({ "w1", "w2" }) do
      for k = 1, n do
        assert.is_true(added[tag .. "-add-" .. k] == true, "lost thread " .. tag .. "-add-" .. k)
      end
    end
  end)
end)
end)
