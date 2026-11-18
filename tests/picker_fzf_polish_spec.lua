-- Bead beads_nvim-4u9.10: fzf picker polish.
-- Interface under test (fzf-lua replaced by a fake module, as in picker_fzf_spec.lua):
--   * fzf_exec opts carry a header listing the picker action keys from keymaps.picker, as
--     opts.header (fzf-lua option) or opts.fzf_opts["--header"].
--   * opts.previewer is a fzf-lua builtin previewer class (extending
--     require("fzf-lua.previewer.builtin").base) whose populate_preview_buf(entry) puts the
--     rendered bead into a buffer with markdown highlighting (filetype markdown).
-- The fake previewer base is a test double for fzf-lua's builtin previewer: classic-style
-- extend/new, get_tmp_buffer() creates a scratch buffer, set_preview_buf(buf) records it.

local fake = require("tests.picker_fake")

local calls

local identity = function(s)
  return s
end

local FAKE_FZF = {
  fzf_exec = function(contents, opts)
    calls[#calls + 1] = { contents = contents, opts = opts or {} }
  end,
  utils = {
    ansi_codes = setmetatable({}, {
      __index = function()
        return identity
      end,
    }),
  },
}

-- Minimal classic-style class, as fzf-lua.class.
local Object = {}
Object.__index = Object
function Object:new() end
function Object:extend()
  local cls = {}
  for k, v in pairs(self) do
    if type(k) == "string" and k:find("__") == 1 then
      cls[k] = v
    end
  end
  cls.__index = cls
  cls.super = self
  setmetatable(cls, self)
  return cls
end
function Object:__call(...)
  local obj = setmetatable({}, self)
  obj:new(...)
  return obj
end

local preview_bufs

local FakeBase = Object:extend()
function FakeBase:new(o, opts, fzf_win)
  self.opts = opts
  self.win = fzf_win
  self.o = o
  return self
end
function FakeBase:get_tmp_buffer()
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].modifiable = true
  return b
end
function FakeBase:set_preview_buf(buf)
  self.preview_bufnr = buf
  preview_bufs[#preview_bufs + 1] = buf
end
function FakeBase:populate_preview_buf() end
function FakeBase:gen_winopts()
  return {}
end
-- any other base method the implementation may call is a no-op
setmetatable(FakeBase, {
  __index = function(_, k)
    local v = rawget(Object, k)
    if v ~= nil then
      return v
    end
    return function() end
  end,
  __call = Object.__call,
})

local FAKE_BUILTIN = { base = FakeBase }

local function run(cmd)
  vim.cmd(cmd)
  assert(vim.wait(2000, function()
    return #calls > 0
  end, 10), cmd .. " never called fzf-lua fzf_exec")
  local call = calls[#calls]
  local lines = call.contents
  if type(lines) == "function" then
    local out, done = {}, false
    lines(function(line, cb)
      if line == nil then
        done = true
      else
        out[#out + 1] = line
      end
      if cb then
        cb()
      end
    end)
    assert(vim.wait(2000, function()
      return done
    end, 10), "contents function never finished")
    lines = out
  end
  return call, lines
end

local function header_of(call)
  local h = call.opts.header
  if h == nil and type(call.opts.fzf_opts) == "table" then
    h = call.opts.fzf_opts["--header"]
  end
  if type(h) == "table" then
    h = table.concat(h, "\n")
  end
  assert.are.equal("string", type(h), "fzf_exec opts have no header")
  return fake.strip(h)
end

local function line_for(lines, id)
  for _, l in ipairs(lines) do
    if fake.line_id(l) == id then
      return l
    end
  end
  error("no picker line for " .. id)
end

-- Instantiates opts.previewer the way fzf-lua's previewer.new does (new | _new | _ctor).
local function make_previewer(call)
  local spec = call.opts.previewer
  assert.are.equal("table", type(spec), "fzf_exec opts.previewer is not a previewer class")
  local win = { preview_winid = vim.api.nvim_get_current_win(), validate_preview = function()
    return true
  end }
  if type(spec.new) == "function" then
    return spec:new(spec, call.opts, win)
  elseif type(spec._new) == "function" then
    return spec._new()(spec, call.opts, win)
  elseif type(spec._ctor) == "function" then
    return spec._ctor()(spec, call.opts, win)
  end
  error("opts.previewer cannot be instantiated")
end

local function is_markdown(buf)
  if vim.bo[buf].filetype == "markdown" or vim.bo[buf].syntax == "markdown" then
    return true
  end
  local hl = vim.treesitter.highlighter and vim.treesitter.highlighter.active[buf]
  return hl ~= nil and hl.tree ~= nil and hl.tree:lang() == "markdown"
end

describe("fzf picker polish", function()
  local orig_builtin

  before_each(function()
    fake.setup()
    calls, preview_bufs = {}, {}
    orig_builtin = package.loaded["fzf-lua.previewer.builtin"]
    package.loaded["fzf-lua.previewer.builtin"] = FAKE_BUILTIN
    package.preload["fzf-lua"] = nil
    package.loaded["fzf-lua"] = FAKE_FZF
    require("beads").setup({})
    assert.is_true(require("beads").config.fzf)
    vim.ui.input = function(_, cb)
      cb("")
    end
  end)

  after_each(function()
    fake.teardown()
    package.loaded["fzf-lua.previewer.builtin"] = orig_builtin
  end)

  it("header lists the default picker keys", function()
    local call = run("Beads list")
    local h = header_of(call)
    for _, key in ipairs({ "ctrl-y", "alt-r", "ctrl-x" }) do
      assert.is_truthy(h:find(key, 1, true), "header lacks " .. key .. ": " .. h)
    end
  end)

  it("changing keymaps.picker changes the header", function()
    require("beads").setup({ keymaps = { picker = { yank_id = "ctrl-o", close = false } } })
    local call = run("Beads list")
    local h = header_of(call)
    assert.is_truthy(h:find("ctrl-o", 1, true), "header lacks ctrl-o: " .. h)
    assert.is_truthy(h:find("alt-r", 1, true), "header lacks alt-r: " .. h)
    assert.is_falsy(h:find("ctrl-y", 1, true), "header still lists ctrl-y: " .. h)
    assert.is_falsy(h:find("ctrl-x", 1, true), "header still lists disabled ctrl-x: " .. h)
  end)

  it("preview buffer shows the rendered bead with markdown highlighting", function()
    local call, lines = run("Beads list")
    local p = make_previewer(call)
    assert.are.equal("function", type(p.populate_preview_buf), "previewer has no populate_preview_buf")
    p:populate_preview_buf(line_for(lines, "op-a"))
    local buf = p.preview_bufnr or preview_bufs[#preview_bufs]
    assert.is_not_nil(buf, "previewer never set a preview buffer")
    assert.is_true(vim.api.nvim_buf_is_valid(buf))
    local text = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.is_true(vim.tbl_contains(text, "# Open alpha"), "preview lacks '# Open alpha':\n" .. table.concat(text, "\n"))
    assert.is_true(vim.tbl_contains(text, "id: op-a"), "preview lacks 'id: op-a'")
    assert.is_true(is_markdown(buf), "preview buffer has no markdown highlighting (filetype "
      .. vim.bo[buf].filetype .. ")")
  end)
end)
