-- Interface under test (bead beads_nvim-ge7.2): lua/beads/cli.lua
--   local cli = require("beads.cli")
--   Every callback is called exactly once, on the main loop, with ONE table `res`:
--     success: res.data = decoded JSON stdout, res.err == nil
--     failure: res.err  = message string, res.stderr = tail of stderr (non-zero exit)
--   cli.list(opts, cb)     -- opts = { all = bool } ; always passes '-n 0', '--all' when opts.all
--   cli.show(id, cb)
--   cli.ready(cb)
--   cli.search(q, cb)
--   cli.context(cb)
--   cli.run_with_files(args, files, cb)
--       args  = list of bd args (e.g. { "create", "Title" })
--       files = map flag -> text (e.g. { ["--body-file"] = "long text" }); each text is
--               written to a temp file and '<flag> <tempfile>' is added to the argv.
--               The temp files are removed after the process exits (also on failure).
--   Every invocation passes '-C <root>'; root defaults to vim.fn.getcwd() and is changed by
--   ':Beads cd <path>'.
--
-- `bd` is replaced by a generated shell script on PATH (test double for the external binary).

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local cli = require("beads.cli")

local FAKE_BD = [[#!/bin/sh
for a in "$@"; do
  printf 'ARG:%s\n' "$a" >> "$FAKE_BD_LOG"
  if [ -f "$a" ]; then
    printf 'FILE:%s:' "$a" >> "$FAKE_BD_LOG"
    cat "$a" >> "$FAKE_BD_LOG"
    printf '\n' >> "$FAKE_BD_LOG"
  fi
done
if [ -n "$FAKE_BD_STDERR" ]; then printf '%s' "$FAKE_BD_STDERR" >&2; fi
printf '%s' "$FAKE_BD_STDOUT"
exit "${FAKE_BD_EXIT:-0}"
]]

local orig_path, bin_dir, log_file

local function norm(p)
  p = vim.fn.resolve(vim.fn.fnamemodify(p, ":p"))
  return (p:gsub("/+$", ""))
end

local function set_fake(stdout, exit, stderr)
  vim.env.FAKE_BD_STDOUT = stdout or "[]"
  vim.env.FAKE_BD_EXIT = tostring(exit or 0)
  vim.env.FAKE_BD_STDERR = stderr or ""
end

local function read_log()
  if vim.fn.filereadable(log_file) == 0 then
    return {}
  end
  return vim.fn.readfile(log_file)
end

local function argv()
  local out = {}
  for _, l in ipairs(read_log()) do
    local a = l:match("^ARG:(.*)$")
    if a then
      table.insert(out, a)
    end
  end
  return out
end

local function has_pair(args, a, b)
  for i = 1, #args - 1 do
    if args[i] == a and args[i + 1] == b then
      return true
    end
  end
  return false
end

local function root_after_C(args)
  for i = 1, #args - 1 do
    if args[i] == "-C" then
      return args[i + 1]
    end
  end
end

-- Calls start(cb) and waits for the callback. Returns res, number of calls, in_fast_event flag.
local function call(start)
  local calls, res, fast = 0, nil, nil
  local ok, err = pcall(start, function(r)
    calls = calls + 1
    res = r
    fast = vim.in_fast_event()
  end)
  assert(ok, "cli call threw: " .. tostring(err))
  local done = vim.wait(5000, function()
    return calls > 0
  end, 10)
  assert(done, "callback was never called")
  vim.wait(200, function()
    return false
  end, 10)
  return res, calls, fast
end

describe("beads.cli", function()
  local cwd

  before_each(function()
    cwd = vim.fn.getcwd()
    orig_path = vim.env.PATH
    bin_dir = vim.fn.tempname()
    vim.fn.mkdir(bin_dir, "p")
    vim.fn.writefile(vim.split(FAKE_BD, "\n"), bin_dir .. "/bd")
    vim.fn.setfperm(bin_dir .. "/bd", "rwxr-xr-x")
    log_file = vim.fn.tempname()
    vim.env.FAKE_BD_LOG = log_file
    vim.env.PATH = bin_dir .. ":" .. orig_path
    set_fake("[]", 0, "")
    if vim.fn.exists(":Beads") ~= 2 then
      vim.cmd.source(root .. "/plugin/beads.lua")
    end
  end)

  after_each(function()
    vim.env.PATH = orig_path
    vim.fn.delete(bin_dir, "rf")
    vim.fn.delete(log_file)
    vim.cmd.cd(cwd)
  end)

  describe("root", function()
    it("defaults -C to the current working directory", function()
      call(function(cb)
        cli.list({}, cb)
      end)
      local r = root_after_C(argv())
      assert.is_truthy(r, "no -C in argv: " .. vim.inspect(argv()))
      assert.are.equal(norm(vim.fn.getcwd()), norm(r))
    end)
  end)

  describe("-C <root> on every invocation", function()
    local cases = {
      list = function(cb)
        cli.list({}, cb)
      end,
      show = function(cb)
        set_fake("{}", 0)
        cli.show("x-1", cb)
      end,
      ready = function(cb)
        cli.ready(cb)
      end,
      search = function(cb)
        cli.search("needle", cb)
      end,
      context = function(cb)
        set_fake("{}", 0)
        cli.context(cb)
      end,
      run_with_files = function(cb)
        set_fake("{}", 0)
        cli.run_with_files({ "create", "T" }, { ["--body-file"] = "body" }, cb)
      end,
    }
    for name, start in pairs(cases) do
      it(name .. " passes -C <root>", function()
        call(start)
        local r = root_after_C(argv())
        assert.is_truthy(r, name .. ": no -C in argv: " .. vim.inspect(argv()))
        assert.are.equal(norm(vim.fn.getcwd()), norm(r))
      end)
    end
  end)

  describe("list", function()
    it("always passes -n 0 and not --all by default", function()
      local res = call(function(cb)
        cli.list({}, cb)
      end)
      local args = argv()
      assert.is_true(has_pair(args, "-n", "0"), "missing '-n 0': " .. vim.inspect(args))
      assert.is_false(vim.tbl_contains(args, "--all"), "unexpected --all: " .. vim.inspect(args))
      assert.is_true(vim.tbl_contains(args, "list"))
      assert.is_true(vim.tbl_contains(args, "--json"))
      assert.is_nil(res.err)
    end)

    it("passes --all and -n 0 when all=true", function()
      call(function(cb)
        cli.list({ all = true }, cb)
      end)
      local args = argv()
      assert.is_true(has_pair(args, "-n", "0"), "missing '-n 0': " .. vim.inspect(args))
      assert.is_true(vim.tbl_contains(args, "--all"), "missing --all: " .. vim.inspect(args))
    end)

    it("returns decoded JSON in res.data, on the main loop", function()
      set_fake('[{"id":"a-1","title":"One"},{"id":"a-2","title":"Two"}]', 0)
      local res, calls, fast = call(function(cb)
        cli.list({}, cb)
      end)
      assert.are.equal(1, calls)
      assert.is_false(fast)
      assert.is_nil(res.err)
      assert.are.equal(2, #res.data)
      assert.are.equal("a-1", res.data[1].id)
    end)
  end)

  describe("errors", function()
    it("non-zero exit returns {err, stderr} with the stderr tail, callback called once", function()
      set_fake("", 3, "line one\nline two\nfatal: the last line\n")
      local res, calls = call(function(cb)
        cli.list({}, cb)
      end)
      assert.are.equal(1, calls)
      assert.is_truthy(res.err, "expected res.err")
      assert.are.equal("string", type(res.stderr))
      assert.is_truthy(res.stderr:find("fatal: the last line", 1, true), "stderr tail: " .. tostring(res.stderr))
    end)

    it("missing bd returns an error mentioning 'bd not found' without throwing", function()
      local empty = vim.fn.tempname()
      vim.fn.mkdir(empty, "p")
      vim.env.PATH = empty
      local res, calls = call(function(cb)
        cli.list({}, cb)
      end)
      vim.fn.delete(empty, "rf")
      assert.are.equal(1, calls)
      assert.is_truthy(res.err, "expected res.err")
      assert.is_truthy(tostring(res.err):find("bd not found", 1, true), "err: " .. tostring(res.err))
    end)

    it("invalid JSON returns a decode error, not a Lua error", function()
      set_fake("this is not json", 0)
      local res, calls = call(function(cb)
        cli.list({}, cb)
      end)
      assert.are.equal(1, calls)
      assert.is_truthy(res.err, "expected a decode error in res.err")
      assert.is_nil(res.data)
    end)
  end)

  describe(":Beads cd", function()
    it("changes the root used by subsequent calls", function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      vim.cmd("Beads cd " .. vim.fn.fnameescape(dir))
      call(function(cb)
        cli.list({}, cb)
      end)
      local r1 = root_after_C(argv())
      vim.fn.delete(log_file)
      call(function(cb)
        cli.show("x-1", cb)
      end)
      local r2 = root_after_C(argv())
      vim.cmd("Beads cd " .. vim.fn.fnameescape(cwd))
      vim.fn.delete(dir, "rf")
      assert.is_truthy(r1, "no -C after :Beads cd")
      assert.are.equal(norm(dir), norm(r1))
      assert.are.equal(norm(dir), norm(r2))
    end)
  end)

  describe("run_with_files", function()
    local function check(exit)
      set_fake(exit == 0 and "{}" or "", exit, exit == 0 and "" or "boom\n")
      local text = "multi word body text " .. exit
      local res, calls = call(function(cb)
        cli.run_with_files({ "create", "Title" }, { ["--body-file"] = text }, cb)
      end)
      assert.are.equal(1, calls)
      local args = argv()
      local path
      for i = 1, #args - 1 do
        if args[i] == "--body-file" then
          path = args[i + 1]
        end
      end
      assert.is_truthy(path, "no --body-file <path> in argv: " .. vim.inspect(args))
      local seen = false
      for _, l in ipairs(read_log()) do
        if l == "FILE:" .. path .. ":" .. text then
          seen = true
        end
      end
      assert.is_true(seen, "temp file did not hold the text while bd ran: " .. vim.inspect(read_log()))
      assert.are.equal(0, vim.fn.filereadable(path), "temp file not removed: " .. path)
      return res
    end

    it("writes text args to temp files and removes them after success", function()
      local res = check(0)
      assert.is_nil(res.err)
    end)

    it("removes temp files after a failing process", function()
      local res = check(1)
      assert.is_truthy(res.err)
    end)
  end)
end)
