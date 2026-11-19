-- Bead beads_nvim-f92: questions reach the agent with beads-ask allowed and on PATH.
-- Interface under test:
--   * workflow.deliver(root, prompt, note) calls require("agent-poke").poke(root, prompt, opts) with
--       opts.env.PATH = <plugin>/bin .. ":" .. <PATH at deliver time>
--       opts.tools    = { "Bash(beads-ask:*)", "Bash(bd show:*)" }
--   * The same opts reach agent-poke on ask (detail `a`, sent with <M-s>) and on reply (thread
--     float `r`, sent with <M-s>).
--   * README has no manual PATH / allowed-tools step for beads-ask.
-- agent-poke is a fake through package.preload (captures root, prompt, opts).
-- assumption: <plugin> is the plugin's repository root (the directory holding lua/ and bin/), and
--   PATH is the current vim.env.PATH with that bin prepended (":"-separated, nothing else changed).
-- assumption: opts.tools is exactly the list in the acceptance criteria, in that order.

local fake = require("tests.questions_fake")
local store = require("beads.questions.store")

local REPO = fake.repo
local TOOLS = { "Bash(beads-ask:*)", "Bash(bd show:*)" }

local pokes

local function norm(p)
  return (vim.fn.resolve(vim.fn.fnamemodify(p, ":p")):gsub("/+$", ""))
end

local function stub_poke()
  package.loaded["agent-poke"] = nil
  package.preload["agent-poke"] = function()
    return {
      poke = function(root, prompt, opts)
        pokes[#pokes + 1] = { root = root, prompt = prompt, opts = opts, path = vim.env.PATH }
      end,
    }
  end
end

-- Checks the opts of one captured poke.
local function assert_opts(p)
  local opts = p.opts
  assert.are.equal("table", type(opts), "poke got no opts table")
  assert.are.equal("table", type(opts.env), "opts.env is not a table: " .. vim.inspect(opts.env))
  local path = opts.env.PATH
  assert.are.equal("string", type(path), "opts.env.PATH is not a string: " .. vim.inspect(path))
  local first, rest = path:match("^([^:]*):(.*)$")
  assert.is_truthy(first, "opts.env.PATH has no ':'-separated first entry: " .. path)
  assert.are.equal(norm(REPO .. "/bin"), norm(first), "first PATH entry is not the plugin's bin/: " .. path)
  assert.are.equal(1, vim.fn.executable(first .. "/beads-ask"), "no executable beads-ask in " .. first)
  assert.are.equal(p.path, rest, "the rest of opts.env.PATH is not the current PATH")
  assert.are.same(TOOLS, opts.tools)
end

describe("workflow.deliver passes env and tools to agent-poke", function()
  local orig_preload, orig_loaded

  before_each(function()
    orig_preload = package.preload["agent-poke"]
    orig_loaded = package.loaded["agent-poke"]
    pokes = {}
    stub_poke()
  end)

  after_each(function()
    package.preload["agent-poke"] = orig_preload
    package.loaded["agent-poke"] = orig_loaded
  end)

  it("deliver(root, prompt) pokes with env.PATH = <plugin>/bin prepended and the beads tools", function()
    local root = vim.fn.tempname()
    require("beads.workflow").deliver(root, "hello agent", "note.")
    assert.are.equal(1, #pokes, "agent-poke.poke not called once")
    assert.are.equal(root, pokes[1].root)
    assert.are.equal("hello agent", pokes[1].prompt)
    assert_opts(pokes[1])
  end)

  it("uses the PATH current at deliver time", function()
    local orig = vim.env.PATH
    vim.env.PATH = "/tmp/beads-f92-test-dir:" .. orig
    local ok, err = pcall(require("beads.workflow").deliver, vim.fn.tempname(), "x")
    vim.env.PATH = orig
    assert(ok, tostring(err))
    assert.are.equal(1, #pokes)
    assert_opts(pokes[1])
    assert.is_truthy(pokes[1].opts.env.PATH:find("/tmp/beads-f92-test-dir", 1, true), pokes[1].opts.env.PATH)
  end)
end)

describe("ask and reply send env and tools to agent-poke", function()
  before_each(function()
    fake.setup()
    pokes = {}
    stub_poke()
    require("beads").setup({})
  end)

  after_each(function()
    package.preload["agent-poke"] = nil
    package.loaded["agent-poke"] = nil
    fake.teardown()
  end)

  it("ask (detail a, <M-s>) pokes with env.PATH and tools", function()
    fake.open_detail()
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
    vim.ui.input = function(_, cb)
      cb(nil)
    end
    local f = fake.press_for_float("a")
    assert(f ~= nil, "a opened no ask box")
    vim.api.nvim_set_current_win(f)
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(f), 0, -1, false, { "Where does it go?" })
    fake.press("<M-s>")
    fake.wait_for(function()
      return #pokes == 1
    end, "agent-poke.poke called on ask")
    assert_opts(pokes[1])
  end)

  it("reply (thread float r, <M-s>) pokes with env.PATH and tools", function()
    store.add(fake.dir(), { bead = "fx-1", messages = { { author = "agent", body = "Which database?" } } })
    fake.open_detail()
    local buf = vim.api.nvim_get_current_buf()
    fake.open_thread(buf, "Which database?")
    vim.ui.input = function(_, cb)
      cb(nil)
    end
    local f = fake.press_for_float("r")
    assert(f ~= nil, "r opened no reply box")
    vim.api.nvim_set_current_win(f)
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(f), 0, -1, false, { "Use sqlite" })
    fake.press("<M-s>")
    fake.wait_for(function()
      return #pokes == 1
    end, "agent-poke.poke called on reply")
    assert.is_truthy(pokes[1].prompt:find("Use sqlite", 1, true), pokes[1].prompt)
    assert_opts(pokes[1])
  end)
end)

describe("README", function()
  it("has no manual PATH or allowed-tools step for beads-ask", function()
    local text = table.concat(vim.fn.readfile(REPO .. "/README.md"), "\n")
    for _, needle in ipairs({ "extra_tools", "allowed_tools", "allowedTools", "Bash(beads-ask" }) do
      assert.is_falsy(text:find(needle, 1, true), "README still mentions " .. needle)
    end
    for line in text:gmatch("[^\n]+") do
      local l = line:lower()
      assert.is_falsy(
        l:find("path", 1, true) and l:find("bin", 1, true) and (l:find("beads-ask", 1, true) or l:find("beads.nvim", 1, true)),
        "README still has a PATH step: " .. line
      )
    end
  end)
end)
