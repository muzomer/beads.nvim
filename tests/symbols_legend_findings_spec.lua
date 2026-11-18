-- Bead beads_nvim-4u9.12, review findings on lua/beads/legend.lua:
--   * The detail VIEW (?) / EDIT (g?) legend must not list "·" (unknown status): the detail winbar
--     renders an unknown status as "" and its only "·" are field separators.
--   * The tree (?) legend must list the guides │ ├ └ that the tree draws, each with a meaning.
-- bd is a fake on PATH (tests/questions_fake.lua).

local fake = require("tests.questions_fake")

local function norm(l)
  return vim.trim((l:gsub("[^%w ]", ""))):lower()
end

local HEADINGS = { "global", "view mode", "edit mode", "tree", "thread", "input", "symbols" }

local function heading_name(l)
  local n = norm(l)
  for _, h in ipairs(HEADINGS) do
    if n == h then
      return h
    end
  end
  if l:find("──", 1, true) or l:match("^%s*#") then
    return n
  end
end

local function symbols_section(lines)
  local out, inside = nil, false
  for _, l in ipairs(lines) do
    local h = heading_name(l)
    if h then
      if inside then
        break
      end
      if h == "symbols" then
        inside, out = true, {}
      end
    elseif inside then
      out[#out + 1] = l
    end
  end
  return out
end

local function legend(f)
  assert.is_not_nil(f, "no help float opened")
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(f), 0, -1, false)
  local dump = table.concat(lines, "\n")
  local sec = symbols_section(lines)
  assert(sec, "help float has no 'Symbols' section:\n" .. dump)
  return sec, dump
end

-- A line of sec with glyph and a meaning (letters besides the glyph).
local function has_symbol(sec, glyph)
  for _, l in ipairs(sec) do
    local s, e = l:find(glyph, 1, true)
    if s and (l:sub(1, s - 1) .. l:sub(e + 1)):find("%a") then
      return true
    end
  end
  return false
end

local function assert_no_dot(sec, dump)
  for _, l in ipairs(sec) do
    assert.is_nil(l:find("·", 1, true), "detail legend lists '·':\n" .. dump)
    assert.is_nil(l:lower():find("unknown", 1, true), "detail legend lists an unknown status:\n" .. dump)
  end
end

local function close_all_floats()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
end

describe("Symbols legend findings", function()
  before_each(function()
    fake.setup()
    require("beads").setup({})
  end)
  after_each(function()
    close_all_floats()
    fake.teardown()
    require("beads").setup({})
  end)

  it("detail VIEW ?: no '·' unknown-status row", function()
    fake.open_detail()
    local sec, dump = legend(fake.press_for_float("?"))
    assert_no_dot(sec, dump)
  end)

  it("detail EDIT g?: no '·' unknown-status row", function()
    local buf = fake.open_detail()
    fake.press("e")
    pcall(vim.cmd, "stopinsert")
    assert.equals("edit", vim.b[buf].beads_mode, "e did not enter edit mode")
    local sec, dump = legend(fake.press_for_float("g?"))
    assert_no_dot(sec, dump)
  end)

  it("tree ?: lists the guides │ ├ └ with a meaning", function()
    vim.cmd("Beads tree")
    assert.equals("beads-tree", vim.bo.filetype, ":Beads tree did not focus the tree")
    local sec, dump = legend(fake.press_for_float("?"))
    for _, glyph in ipairs({ "│", "├", "└" }) do
      assert(has_symbol(sec, glyph), ("tree legend has no line with %q and a meaning:\n%s"):format(glyph, dump))
    end
  end)
end)
