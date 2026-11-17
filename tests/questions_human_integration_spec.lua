-- Interface under test (bead beads_nvim-4gx.3): lua/beads/questions/human.lua
--   local human = require("beads.questions.human")
--   human.list(root, cb)            -> cb({data = threads}) | cb({err = msg})
--       one read-only thread per bead labelled 'human' in <root>:
--       {bead = <id>, status = "open", needs = "user", messages = {..., {body = <latest note>}}}
--       Not stored in <root>/.beads-nvim/questions.json.
--   human.answer(root, id, text, cb) -> cb({}) / cb({data = ...}) on success | cb({err = msg})
--       bd update <id> --append-notes <text>, then bd label remove <id> human; both scoped to
--       <root>, never changing the cli root override.
-- Integration against a real temp bd repo. bd joins appended notes with a single newline, so the
-- latest note of a bead is its last notes line.

local helpers = require("tests.helpers")
local cli = require("beads.cli")

local function bd(dir, args)
  local argv = { "bd", "-C", dir }
  vim.list_extend(argv, args)
  local r = vim.system(argv, { text = true }):wait()
  assert(r.code == 0, "bd " .. table.concat(args, " ") .. " failed: " .. tostring(r.stderr))
  return r.stdout
end

local function create(dir, title)
  local out = vim.json.decode(bd(dir, { "create", title, "--json" }))
  if vim.islist(out) then
    out = out[1]
  end
  return out.id
end

local function show(dir, id)
  local out = vim.json.decode(bd(dir, { "show", id, "--json" }))
  return vim.islist(out) and out[1] or out
end

local function await(fn)
  local res
  fn(function(x)
    res = x
  end)
  assert(
    vim.wait(20000, function()
      return res ~= nil
    end, 20),
    "callback was never called"
  )
  return res
end

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end

describe("beads.questions.human (bd integration)", function()
  if not helpers.has_bd() then
    pending("bd executable not found")
    return
  end

  local human = require("beads.questions.human")
  local other

  before_each(function()
    other = tmpdir()
    cli.set_root(other)
  end)

  after_each(function()
    cli.set_root(nil)
    vim.fn.delete(other, "rf")
  end)

  it("a bead labelled human yields one thread with its latest note; unlabelled beads none", function()
    helpers.with_bd_repo(function(dir)
      local a = create(dir, "Asks the owner")
      bd(dir, { "update", a, "--append-notes", "old note" })
      bd(dir, { "update", a, "--append-notes", "the question?" })
      bd(dir, { "label", "add", a, "human" })
      local b = create(dir, "No label")
      bd(dir, { "update", b, "--append-notes", "not a question" })

      local res = await(function(cb)
        human.list(dir, cb)
      end)
      assert.are.equal(other, cli.get_root_override())
      assert.is_nil(res.err, vim.inspect(res))
      local threads = res.data
      assert.are.equal(1, #threads, vim.inspect(threads))
      local t = threads[1]
      assert.are.equal(a, t.bead)
      assert.are.equal("user", t.needs)
      assert.are.equal("open", t.status)
      assert.is_true(type(t.messages) == "table" and #t.messages >= 1, vim.inspect(t))
      assert.are.equal("the question?", t.messages[#t.messages].body)
      assert.are.equal(0, vim.fn.filereadable(dir .. "/.beads-nvim/questions.json"))
    end)
  end)

  it("answer() appends the note and removes the label; no human thread remains", function()
    helpers.with_bd_repo(function(dir)
      local a = create(dir, "Asks the owner")
      bd(dir, { "update", a, "--append-notes", "which option?" })
      bd(dir, { "label", "add", a, "human" })

      local before = await(function(cb)
        human.list(dir, cb)
      end)
      assert.is_nil(before.err, vim.inspect(before))
      assert.are.equal(1, #before.data)

      local res
      human.answer(dir, a, "Owner answer: option (a).", function(x)
        res = x
        assert.are.equal(other, cli.get_root_override(), "cli root changed during answer()")
      end)
      assert.are.equal(other, cli.get_root_override(), "cli root changed by answer()")
      assert(
        vim.wait(20000, function()
          return res ~= nil
        end, 20),
        "answer() callback was never called"
      )
      assert.are.equal(other, cli.get_root_override())
      assert.is_nil(res.err, vim.inspect(res))

      local bead = show(dir, a)
      assert.is_truthy(
        vim.endswith(vim.trim(bead.notes or ""), "Owner answer: option (a)."),
        "notes: " .. tostring(bead.notes)
      )
      assert.is_truthy((bead.notes or ""):find("which option?", 1, true), "earlier note lost")
      assert.is_false(vim.tbl_contains(bead.labels or {}, "human"), vim.inspect(bead.labels))

      local after = await(function(cb)
        human.list(dir, cb)
      end)
      assert.is_nil(after.err, vim.inspect(after))
      assert.are.equal(0, #after.data, vim.inspect(after.data))
      assert.are.equal(0, vim.fn.filereadable(dir .. "/.beads-nvim/questions.json"))
    end)
  end)
end)
