-- Bead beads_nvim-4u9.2: tree and pickers render bead lines with the shared formatter
-- (lua/beads/ui/format.lua, F.format(bead, opts) -> text, ranges; see tests/format_line_spec.lua).
--   * Tree and picker lines for the same bead are identical apart from tree-only prefixes
--     (indent, guides │├└─, fold marker ▾/▸).
--   * fzf entries carry ANSI colours built from the ranges; vim.ui.select entries are plain text.
-- assumption: fzf colours are 24-bit SGR codes (ESC[38;2;R;G;Bm) built by beads from the
--   resolved foreground of each range's Beads* group (not through fzf-lua's utils).
-- bd is a fake on PATH (tests/picker_fake.lua); fzf-lua is a fake module that records fzf_exec.

local fake = require("tests.picker_fake")
local model = require("beads.model")

local ESC = "\27"

local calls
local FAKE_FZF = {
  fzf_exec = function(contents, opts)
    calls[#calls + 1] = { contents = contents, opts = opts or {} }
  end,
}

local function exec_lines(call)
  local c = call.contents
  if type(c) == "table" then
    return vim.list_extend({}, c)
  end
  local out, done = {}, false
  c(function(line, cb)
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
  return out
end

-- Raw line in `lines` whose plain text contains the bead id `id` as a word.
local function line_with(lines, id, plain)
  for _, l in ipairs(lines) do
    local s = plain and plain(l) or l
    if (" " .. s .. " "):find("[%s]" .. vim.pesc(id) .. "[%s]") then
      return l
    end
  end
  error("no line for " .. id .. ":\n" .. table.concat(lines, "\n"))
end

local function strip(s)
  return fake.strip(s)
end

local function rtrim(s)
  return (s:gsub("%s+$", ""))
end

local function hex_rgb(n)
  return math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256
end

local function no_fzf()
  package.loaded["fzf-lua"] = nil
  package.preload["fzf-lua"] = function()
    error("fzf-lua is not installed (test)")
  end
end

local captured
local function stub_select()
  captured = nil
  vim.ui.select = function(items, opts, on_choice)
    captured = { items = items, opts = opts or {}, on_choice = on_choice }
  end
end

local function select_lines(cmd)
  vim.cmd(cmd)
  assert(vim.wait(2000, function()
    return captured ~= nil
  end, 10), cmd .. " never called vim.ui.select")
  local fmt = captured.opts.format_item or tostring
  local out = {}
  for i, it in ipairs(captured.items) do
    out[i] = fmt(it)
  end
  return out
end

local function wins()
  return vim.api.nvim_tabpage_list_wins(0)
end

local function open_tree()
  local before = {}
  for _, w in ipairs(wins()) do
    before[w] = true
  end
  vim.cmd("Beads tree")
  for _, w in ipairs(wins()) do
    if not before[w] then
      return w
    end
  end
end

local function tree_lines(win)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

local COMPARE = { "op-a", "ip-b", "ot-g" }

describe("shared formatter in views", function()
  local tree

  before_each(function()
    fake.setup()
    calls = {}
    tree = nil
  end)

  after_each(function()
    if tree and vim.api.nvim_win_is_valid(tree) then
      pcall(vim.cmd, "Beads tree")
    end
    fake.teardown()
  end)

  it("tree and picker lines for the same bead are identical apart from tree prefixes", function()
    no_fzf()
    require("beads").setup({ tree = { layout = "split" } })
    stub_select()
    local picked = select_lines("Beads list")
    tree = open_tree()
    assert.is_not_nil(tree, ":Beads tree opened no window")
    local ok = vim.wait(3000, function()
      local all = table.concat(tree_lines(tree), "\n")
      for _, id in ipairs(COMPARE) do
        if not all:find(id, 1, true) then
          return false
        end
      end
      return true
    end, 10)
    assert(ok, "tree never showed the beads:\n" .. table.concat(tree_lines(tree), "\n"))
    local tl = tree_lines(tree)
    for _, id in ipairs(COMPARE) do
      local p = rtrim(line_with(picked, id))
      local t = rtrim(line_with(tl, id))
      assert.is_true(#t >= #p and t:sub(-#p) == p,
        id .. ": tree line does not end with the picker line\ntree:   " .. t .. "\npicker: " .. p)
      local prefix = t:sub(1, #t - #p)
      local rest = prefix:gsub("[ \t]", ""):gsub("│", ""):gsub("├", ""):gsub("└", ""):gsub("─", "")
        :gsub("▾", ""):gsub("▸", "")
      assert.are.equal("", rest, id .. ": tree prefix has more than guides/fold marker: '" .. prefix .. "'")
    end
  end)

  it("vim.ui.select entries are plain formatter text without ANSI codes", function()
    no_fzf()
    require("beads").setup({ tree = { layout = "split" } })
    stub_select()
    local picked = select_lines("Beads list")
    local F = require("beads.ui.format")
    for _, l in ipairs(picked) do
      assert.is_nil(l:find(ESC, 1, true), "select entry has escape codes: " .. vim.inspect(l))
    end
    local want = F.format(model.normalize(fake.by_id("op-a")))
    assert.are.equal(rtrim(want), rtrim(line_with(picked, "op-a")))
  end)

  it("fzf entries carry ANSI colours matching the formatter ranges", function()
    package.preload["fzf-lua"] = nil
    package.loaded["fzf-lua"] = FAKE_FZF
    require("beads").setup({ tree = { layout = "split" } })
    assert.is_true(require("beads").config.fzf)
    vim.o.termguicolors = true
    vim.api.nvim_set_hl(0, "BeadsId", { fg = 0x112233 })
    vim.api.nvim_set_hl(0, "BeadsTitle", { fg = 0x445566 })
    vim.api.nvim_set_hl(0, "BeadsPriority1", { fg = 0x778899 })
    vim.cmd("Beads list")
    assert(vim.wait(2000, function()
      return #calls > 0
    end, 10), ":Beads list never called fzf_exec")
    local call = calls[#calls]
    local lines = exec_lines(call)
    local raw = line_with(lines, "op-a", strip)
    assert.is_truthy(raw:find(ESC .. "[", 1, true), "fzf entry has no ANSI codes: " .. vim.inspect(raw))

    local F = require("beads.ui.format")
    local text, ranges = F.format(model.normalize(fake.by_id("op-a")))
    assert.are.equal(rtrim(text), rtrim(strip(raw)), "fzf entry text differs from the formatter text")

    -- every range's text is immediately preceded by a (non-reset) SGR sequence
    for _, r in ipairs(ranges) do
      local seg = text:sub(r.col + 1, r.end_col)
      local found = false
      local init = 1
      while true do
        local s, e, codes = raw:find(ESC .. "%[([%d;]*)m" .. vim.pesc(seg), init)
        if not s then
          break
        end
        if codes ~= "" and codes ~= "0" then
          found = true
          break
        end
        init = e + 1
      end
      assert.is_true(found, r.group .. ": '" .. seg .. "' is not coloured in " .. vim.inspect(raw))
    end

    -- colours come from the groups of the ranges
    for group, want in pairs({ BeadsId = "op-a", BeadsTitle = "Open alpha", BeadsPriority1 = "P1" }) do
      local fg = vim.api.nvim_get_hl(0, { name = group, link = false }).fg
      local rr, gg, bb = hex_rgb(fg)
      local sgr = ("38;2;%d;%d;%d"):format(rr, gg, bb)
      local _, _, codes = raw:find(ESC .. "%[([%d;]*)m" .. vim.pesc(want))
      assert.is_not_nil(codes, group .. ": no SGR before '" .. want .. "' in " .. vim.inspect(raw))
      assert.is_truthy(codes:find(sgr, 1, true), group .. ": want " .. sgr .. " before '" .. want .. "', got " .. codes)
    end

    -- the coloured entry still opens the right bead
    local a = call.opts.actions and call.opts.actions.default
    if type(a) == "table" then
      a = a.fn or a[1]
    end
    assert.are.equal("function", type(a), "no default fzf action")
    a({ raw }, call.opts)
    assert(fake.wait_buf("beads://op-a"), "current buffer is " .. vim.api.nvim_buf_get_name(0))
  end)
end)
