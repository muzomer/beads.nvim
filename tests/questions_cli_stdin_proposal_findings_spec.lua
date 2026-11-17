-- Findings for bead beads_nvim-4gx.2 (lua/beads/questions/cli.lua:60):
-- a body read from stdin ('-') must not leak gsub's match count into store.reply
-- as a proposal. reply/resolve with '-' store a plain message (proposal == nil),
-- and the text 'show' of that thread works.

local qs = require("beads.questions.store")

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local bin = plugin_root .. "/bin/beads-ask"

local function run(root, args, stdin)
  local cmd = { bin }
  vim.list_extend(cmd, args)
  local r = vim.system(cmd, { cwd = root, stdin = stdin, text = true, env = { BEADS_NVIM_ROOT = root } }):wait(10000)
  return r.code, r.stdout or "", r.stderr or ""
end

local function last(t)
  return t.messages[#t.messages]
end

describe("beads-ask stdin body (findings)", function()
  local root, tid

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    tid = qs.add(root, { bead = "bd-1", messages = { { author = "user", body = "why?" } } }).id
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  it("reply - stores a plain message without a proposal", function()
    local code, _, err = run(root, { "reply", tid, "-" }, "line one\nline two\n")
    assert.are.equal(0, code, err)
    local m = last(qs.get(root, tid))
    assert.are.equal("agent", m.author)
    assert.are.equal("line one\nline two", m.body)
    assert.is_nil(m.proposal)
  end)

  it("reply - with no trailing newline stores no proposal", function()
    local code, _, err = run(root, { "reply", tid, "-" }, "single line")
    assert.are.equal(0, code, err)
    assert.is_nil(last(qs.get(root, tid)).proposal)
  end)

  it("show (text) works after a stdin reply", function()
    local code, _, err = run(root, { "reply", tid, "-" }, "alpha\nbravo\n")
    assert.are.equal(0, code, err)
    local scode, out, serr = run(root, { "show", tid })
    assert.are.equal(0, scode, serr)
    assert.is_truthy(out:find("alpha", 1, true) and out:find("bravo", 1, true), out)
  end)

  it("resolve - stores the stdin note without a proposal and resolves", function()
    local code, _, err = run(root, { "resolve", tid, "-" }, "done\n")
    assert.are.equal(0, code, err)
    local t = qs.get(root, tid)
    assert.are.equal("done", last(t).body)
    assert.is_nil(last(t).proposal)
    assert.are.equal("resolved", t.status)
  end)
end)
