-- Bead beads_nvim-r6s: the thread float is sized to its content.
-- Interface under test (black box, the float opened by <CR> on a Questions line of beads://fx-1):
--   * width: the content's display width, at most 80% of the editor width (floor), at least 60
--     columns when the editor is wide (200 columns here); height: the content, at most 80% of the
--     editor height (floor).
--   * the window has wrap, linebreak and breakindent set.
--   * the float re-sizes when a reply arrives (threads refreshed) and on VimResized.
-- agent-poke is made unavailable (tests/poke_progress_fake.lua) so no stage line takes part.
-- assumption: sizes are the float's width/height from nvim_win_get_config (border not counted);
--   comparisons allow a few cells of padding.

local fake = require("tests.questions_fake")
local poke = require("tests.poke_progress_fake")
local store = require("beads.questions.store")

local function words(n)
  local out = {}
  for i = 1, n do
    out[#out + 1] = "word" .. (i % 10)
  end
  return table.concat(out, " ")
end

local function size(w)
  local c = vim.api.nvim_win_get_config(w)
  return c.width, c.height, c
end

local function num(x)
  return type(x) == "table" and (x[false] or x[1]) or x
end

local function open(body_or_messages)
  local messages = type(body_or_messages) == "table" and body_or_messages
    or { { author = "agent", body = body_or_messages } }
  local t = store.add(fake.dir(), { bead = "fx-1", messages = messages })
  local buf = fake.open_detail()
  local first = vim.split(messages[1].body, "\n", { plain = true })[1]:sub(1, 20)
  local f = fake.open_thread(buf, first)
  return f, buf, t
end

describe("thread float size", function()
  local cols, lines

  before_each(function()
    cols, lines = vim.o.columns, vim.o.lines
    fake.setup()
    poke.install_missing()
    require("beads").setup({})
    vim.o.columns = 200
    vim.o.lines = 50
  end)

  after_each(function()
    fake.teardown()
    poke.uninstall()
    vim.o.columns = cols
    vim.o.lines = lines
  end)

  it("short content: at least 60 columns on a wide editor, no taller than its content", function()
    local f = open("Which database?")
    local w, h = size(f)
    assert.is_true(w >= 60, "width " .. w .. " < 60 on a 200-column editor")
    assert.is_true(w <= 64, "width " .. w .. " is not sized to short content")
    local need = vim.api.nvim_win_text_height(f, {}).all
    assert.is_true(need <= h, ("content needs %d rows, float has %d"):format(need, h))
    assert.is_true(h <= need + 3, ("float height %d is far beyond its content (%d rows)"):format(h, need))
  end)

  it("a 100-column line fits without wrapping (width >= content, <= 80% of the editor)", function()
    local body = ("x"):rep(100)
    local f = open(body)
    local w = size(f)
    assert.is_true(w >= 102, "width " .. w .. " is smaller than the content line ('  ' .. 100 chars)")
    assert.is_true(w <= 160, "width " .. w .. " > 80% of 200 columns")
  end)

  it("long lines: width is capped at 80% of the editor width", function()
    local f = open(words(60))
    local w = size(f)
    assert.is_true(w >= 158 and w <= 160, "width " .. w .. " is not ~80% (160) of 200 columns")
  end)

  it("many lines: height is capped at 80% of the editor height", function()
    local body = {}
    for i = 1, 80 do
      body[#body + 1] = "line " .. i
    end
    local f = open(table.concat(body, "\n"))
    local _, h = size(f)
    assert.is_true(h >= 38 and h <= 40, "height " .. h .. " is not ~80% (40) of 50 lines")
  end)

  it("content that fits needs no scrolling", function()
    local msgs = {}
    for i = 1, 6 do
      msgs[#msgs + 1] = { author = i % 2 == 1 and "agent" or "user", body = "message " .. i .. " " .. words(30) }
    end
    local f = open(msgs)
    local _, h = size(f)
    local need = vim.api.nvim_win_text_height(f, {}).all
    assert.is_true(need <= h, ("content needs %d rows, float has %d"):format(need, h))
  end)

  it("sets wrap, linebreak and breakindent", function()
    local f = open(words(60))
    assert.is_true(vim.wo[f].wrap, "wrap is off")
    assert.is_true(vim.wo[f].linebreak, "linebreak is off")
    assert.is_true(vim.wo[f].breakindent, "breakindent is off")
  end)

  it("re-sizes when a reply arrives", function()
    local f, buf, t = open("Which database?")
    local w1, h1 = size(f)
    local reply = { ("y"):rep(150) }
    for i = 1, 20 do
      reply[#reply + 1] = "reply line " .. i
    end
    store.reply(fake.dir(), t.id, "agent", table.concat(reply, "\n"))
    require("beads.views.detail").refresh_threads(buf)
    local ok = vim.wait(3000, function()
      if not vim.api.nvim_win_is_valid(f) then
        return false
      end
      local w, h = size(f)
      return w >= 152 and h >= math.min(40, h1 + 20)
    end, 10)
    assert.is_true(vim.api.nvim_win_is_valid(f), "the float closed")
    local w, h = size(f)
    assert.is_true(ok, ("float did not grow with the reply: %dx%d -> %dx%d"):format(w1, h1, w, h))
  end)

  it("re-sizes on VimResized and stays inside the editor", function()
    local f = open(words(60) .. "\n" .. table.concat(vim.split(("l\n"):rep(60), "\n"), "\n"))
    local w0 = size(f)
    assert.is_true(w0 >= 158, "width " .. w0 .. " before resize")
    vim.o.columns = 100
    vim.o.lines = 30
    vim.api.nvim_exec_autocmds("VimResized", {})
    local ok = vim.wait(2000, function()
      local w, h = size(f)
      return w <= 80 and h <= 24
    end, 10)
    local w, h, c = size(f)
    assert.is_true(ok, ("after resize to 100x30 the float is %dx%d"):format(w, h))
    assert.is_true(num(c.col) + w <= 100, "float runs past the right edge: col " .. tostring(num(c.col)))
    assert.is_true(num(c.row) + h <= 30, "float runs past the bottom: row " .. tostring(num(c.row)))
  end)
end)
