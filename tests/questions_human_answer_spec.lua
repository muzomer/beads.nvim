-- Interface under test (bead beads_nvim-4gx.3): human.answer(root, id, text, cb), see
-- tests/questions_human_integration_spec.lua.
-- `bd` is replaced by a shell script on PATH (test double) that logs every call one per line,
-- prints "{}" and exits 0, except: when FAIL_LABEL is set it exits 1 with stderr "boom" for any
-- call containing the word "label".

local cli = require("beads.cli")

local orig_path, bin_dir, log

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end

local function calls()
  return vim.fn.filereadable(log) == 1 and vim.fn.readfile(log) or {}
end

local function index_of(pred)
  for i, l in ipairs(calls()) do
    if pred(l) then
      return i, l
    end
  end
end

local function is_update(l)
  return l:find(" update ", 1, true) ~= nil and l:find("--append-notes", 1, true) ~= nil
end

local function is_label_remove(l)
  return l:find(" label ", 1, true) ~= nil and l:find(" remove ", 1, true) ~= nil
end

local function answer(root, id, text)
  local human = require("beads.questions.human")
  local res
  local saw_during
  human.answer(root, id, text, function(x)
    saw_during = cli.get_root_override()
    res = x
  end)
  local sync_override = cli.get_root_override()
  assert(
    vim.wait(5000, function()
      return res ~= nil
    end, 10),
    "answer() callback was never called"
  )
  return res, sync_override, saw_during
end

describe("beads.questions.human answer() with a fake bd", function()
  before_each(function()
    orig_path = vim.env.PATH
    bin_dir = tmpdir()
    log = bin_dir .. "/calls.log"
    vim.fn.writefile({
      "#!/bin/sh",
      'echo "$*" >> ' .. vim.fn.shellescape(log),
      'if [ -n "$FAIL_LABEL" ]; then',
      '  for a in "$@"; do',
      '    if [ "$a" = label ]; then echo boom >&2; exit 1; fi',
      "  done",
      "fi",
      "echo '{}'",
    }, bin_dir .. "/bd")
    vim.fn.setfperm(bin_dir .. "/bd", "rwxr-xr-x")
    vim.env.PATH = bin_dir .. ":" .. orig_path
    vim.env.FAIL_LABEL = nil
    cli.set_root(nil)
  end)

  after_each(function()
    vim.env.PATH = orig_path
    vim.env.FAIL_LABEL = nil
    cli.set_root(nil)
    vim.fn.delete(bin_dir, "rf")
  end)

  it("runs update --append-notes then label remove human, both scoped to the root", function()
    local root = tmpdir()
    local res = answer(root, "fx-1", "my answer")
    assert.is_nil(res.err, vim.inspect(res))
    local iu, lu = index_of(is_update)
    local il, ll = index_of(is_label_remove)
    assert.is_truthy(iu, "no bd update --append-notes call: " .. vim.inspect(calls()))
    assert.is_truthy(il, "no bd label remove call: " .. vim.inspect(calls()))
    assert.is_true(iu < il, "label removed before the note was appended: " .. vim.inspect(calls()))
    assert.is_truthy(lu:find("-C " .. root, 1, true), "update not root-scoped: " .. lu)
    assert.is_truthy(lu:find("fx-1", 1, true) and lu:find("my answer", 1, true), lu)
    assert.is_truthy(ll:find("-C " .. root, 1, true), "label remove not root-scoped: " .. ll)
    assert.is_truthy(ll:find("fx-1", 1, true) and ll:find("human", 1, true), ll)
    vim.fn.delete(root, "rf")
  end)

  it("leaves an unset cli root override unset", function()
    local root = tmpdir()
    local res, sync_override, during = answer(root, "fx-1", "my answer")
    assert.is_nil(res.err, vim.inspect(res))
    assert.is_nil(sync_override, "override set right after answer() returned")
    assert.is_nil(during, "override set when the callback ran")
    assert.is_nil(cli.get_root_override())
    vim.fn.delete(root, "rf")
  end)

  it("leaves a set cli root override unchanged", function()
    local root, other = tmpdir(), tmpdir()
    cli.set_root(other)
    local res, sync_override, during = answer(root, "fx-1", "my answer")
    assert.is_nil(res.err, vim.inspect(res))
    assert.are.equal(other, sync_override)
    assert.are.equal(other, during)
    assert.are.equal(other, cli.get_root_override())
    for _, l in ipairs(calls()) do
      assert.is_nil(l:find(other, 1, true), "bd call used the cli root instead of root: " .. l)
    end
    vim.fn.delete(root, "rf")
    vim.fn.delete(other, "rf")
  end)

  it("names the label step when removing the label fails after the note was appended", function()
    local root = tmpdir()
    vim.env.FAIL_LABEL = "1"
    local res = answer(root, "fx-1", "my answer")
    assert.is_truthy(index_of(is_update), "note was not appended first: " .. vim.inspect(calls()))
    assert.is_truthy(res.err, "expected an error: " .. vim.inspect(res))
    assert.is_truthy(tostring(res.err):lower():find("label", 1, true), "error does not name the label step: " .. tostring(res.err))
    assert.is_nil(cli.get_root_override())
    vim.fn.delete(root, "rf")
  end)
end)
