-- Bead beads_nvim-4u9.11: grouped help float.
-- Interface under test (through key presses, not module internals):
--   * The help float (keymaps <group>.help, ? / g?, and the global <leader>b?) is grouped in
--     sections, each started by a heading line: "Global", "View mode" / "Edit mode", "Tree",
--     "Thread", "Input". The keys of a section are listed below its heading (until the next one).
--   * A help float shows (at least) the section of where you are (View mode in VIEW, Edit mode in
--     EDIT, Tree, Thread, Input) and the Global section; other sections may be listed too.
--   * Disabled keys (keymaps ... = false) are not listed.
--   * The title shows the current mode (view / edit / tree / thread).
--   * The float is sized to its content.
-- A heading line is matched by its letters: decoration (─, #, :, brackets, ...) is ignored and the
-- normalized line must start with the section name followed by the end or a space
-- ("── Tree ──", "## View mode", "Global keys (<leader>b)" all match).
-- bd is a fake on PATH (tests/questions_fake.lua).

local fake = require("tests.questions_fake")
local qstore = require("beads.questions.store")

local function lines_of(w)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
end

local function title_of(w)
  local t = vim.api.nvim_win_get_config(w).title
  if type(t) == "table" then
    local parts = {}
    for _, c in ipairs(t) do
      parts[#parts + 1] = type(c) == "table" and c[1] or tostring(c)
    end
    return table.concat(parts)
  end
  return tostring(t or "")
end

local function norm(l)
  return vim.trim((l:gsub("[^%w ]", ""))):lower()
end

local function is_heading(l, name)
  local n = norm(l)
  name = name:lower()
  return n == name or n:sub(1, #name + 1) == name .. " "
end

-- 1-based row of the heading `name`, or nil.
local function heading_row(lines, name)
  for i, l in ipairs(lines) do
    if is_heading(l, name) then
      return i
    end
  end
end

local ALL_HEADINGS = { "Global", "View mode", "Edit mode", "Tree", "Thread", "Input" }

-- The lines under heading `name` (up to the next heading of any section), or nil without heading.
local function section(lines, name)
  local start = heading_row(lines, name)
  if not start then
    return nil
  end
  local out = {}
  for i = start + 1, #lines do
    for _, h in ipairs(ALL_HEADINGS) do
      if is_heading(lines[i], h) then
        return out
      end
    end
    out[#out + 1] = lines[i]
  end
  return out
end

-- Asserts the section `name` exists and has a line containing every plain string of `wants`.
local function assert_in_section(lines, name, wants)
  local dump = table.concat(lines, "\n")
  local sec = section(lines, name)
  assert(sec, "help has no '" .. name .. "' heading:\n" .. dump)
  local hit = false
  for _, l in ipairs(sec) do
    local all = true
    for _, s in ipairs(wants) do
      if not l:lower():find(s:lower(), 1, true) then
        all = false
      end
    end
    hit = hit or all
  end
  assert(hit, "section '" .. name .. "' has no line with " .. vim.inspect(wants) .. ":\n" .. dump)
end

local function close_all_floats()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
end

local function open_tree()
  vim.cmd("Beads tree")
  local tbuf = vim.api.nvim_get_current_buf()
  assert.equals("beads-tree", vim.bo[tbuf].filetype, ":Beads tree did not focus the tree")
  return vim.api.nvim_get_current_win()
end

describe("beads grouped help float", function()
  local orig_columns, orig_lines
  before_each(function()
    orig_columns, orig_lines = vim.o.columns, vim.o.lines
    fake.setup()
    require("beads").setup({})
  end)

  after_each(function()
    close_all_floats()
    fake.teardown()
    vim.o.columns, vim.o.lines = orig_columns, orig_lines
    require("beads").setup({})
  end)

  it("? in detail VIEW mode: 'View mode' and 'Global' sections, title shows view", function()
    fake.open_detail()
    local f = fake.press_for_float("?")
    assert.is_not_nil(f, "? opened no float")
    local lines, title = lines_of(f), title_of(f)
    assert_in_section(lines, "View mode", { "yy" })
    assert_in_section(lines, "View mode", { "claim" })
    assert_in_section(lines, "Global", { "bt", "tree" })
    assert.is_truthy(title:lower():find("view", 1, true), "help title lacks the mode: " .. title)
  end)

  it("g? in detail EDIT mode: 'Edit mode' and 'Global' sections, title shows edit", function()
    local buf = fake.open_detail()
    fake.press("e")
    pcall(vim.cmd, "stopinsert")
    assert.equals("edit", vim.b[buf].beads_mode, "e did not enter edit mode")
    local f = fake.press_for_float("g?")
    assert.is_not_nil(f, "g? opened no float in edit mode")
    local lines, title = lines_of(f), title_of(f)
    assert_in_section(lines, "Edit mode", { "<C-s>", "save" })
    assert_in_section(lines, "Global", { "bt", "tree" })
    assert.is_truthy(title:lower():find("edit", 1, true), "help title lacks the mode: " .. title)
  end)

  it("? in the tree: 'Tree' and 'Global' sections, title shows tree", function()
    open_tree()
    local f = fake.press_for_float("?")
    assert.is_not_nil(f, "? in the tree opened no float")
    local lines, title = lines_of(f), title_of(f)
    assert_in_section(lines, "Tree", { "R", "refresh" })
    assert_in_section(lines, "Tree", { "<Tab>", "fold" })
    assert_in_section(lines, "Global", { "bt", "tree" })
    assert.is_truthy(title:lower():find("tree", 1, true), "help title lacks the mode: " .. title)
  end)

  it("? in a thread float: 'Thread' and 'Global' sections, title shows thread", function()
    qstore.add(fake.dir(), { bead = "fx-1", messages = { { author = "agent", body = "HQ: help question?" } } })
    local buf = fake.open_detail()
    fake.open_thread(buf, "HQ:")
    local f = fake.press_for_float("?")
    assert.is_not_nil(f, "? in the thread float opened no help float")
    local lines, title = lines_of(f), title_of(f)
    assert_in_section(lines, "Thread", { "reply" })
    assert_in_section(lines, "Thread", { "resolve" })
    assert_in_section(lines, "Global", { "bt", "tree" })
    assert.is_truthy(title:lower():find("thread", 1, true), "help title lacks the mode: " .. title)
  end)

  it("<leader>b? in a note input float: 'Input' and 'Global' sections", function()
    fake.open_detail()
    local nf = fake.press_for_float("n")
    assert.is_not_nil(nf, "n opened no note float")
    vim.api.nvim_set_current_win(nf)
    pcall(vim.cmd, "stopinsert")
    local f = fake.press_for_float("<leader>b?")
    assert.is_not_nil(f, "<leader>b? in the note float opened no help float")
    local lines = lines_of(f)
    assert_in_section(lines, "Input", { "<C-s>", "submit" })
    assert_in_section(lines, "Input", { "cancel" })
    assert_in_section(lines, "Global", { "bt", "tree" })
  end)

  it("<leader>b? in a plain buffer: a 'Global' section with the global keys", function()
    vim.cmd("enew")
    local f = fake.press_for_float("<leader>b?")
    assert.is_not_nil(f, "<leader>b? opened no float")
    local lines = lines_of(f)
    assert_in_section(lines, "Global", { "bt", "tree" })
    assert_in_section(lines, "Global", { "bc", "create" })
  end)

  it("disabled keys are omitted from their sections", function()
    require("beads").setup({ keymaps = { ready = false, tree_view = { refresh = false } } })
    open_tree()
    local f = fake.press_for_float("<leader>b?")
    assert.is_not_nil(f, "<leader>b? in the tree opened no float")
    local lines = lines_of(f)
    local dump = table.concat(lines, "\n")
    assert_in_section(lines, "Tree", { "<Tab>", "fold" })
    assert_in_section(lines, "Global", { "bt", "tree" })
    for _, l in ipairs(lines) do
      assert.is_nil(l:lower():find("refresh", 1, true), "disabled tree key refresh is listed:\n" .. dump)
      assert.is_nil(l:lower():find("ready picker", 1, true), "disabled global key ready is listed:\n" .. dump)
    end
  end)

  it("a disabled key is not listed in the tree ? help (passes already)", function()
    require("beads").setup({ keymaps = { tree_view = { refresh = false } } })
    open_tree()
    local f = fake.press_for_float("?")
    assert.is_not_nil(f, "? in the tree opened no float")
    local lines = lines_of(f)
    for _, l in ipairs(lines) do
      assert.is_nil(l:lower():find("refresh", 1, true), "disabled key refresh is listed:\n" .. table.concat(lines, "\n"))
    end
  end)

  it("the help float is sized to its content (passes already)", function()
    vim.o.columns, vim.o.lines = 200, 150
    open_tree()
    local f = fake.press_for_float("?")
    assert.is_not_nil(f, "? in the tree opened no float")
    local lines = lines_of(f)
    local maxw = 0
    for _, l in ipairs(lines) do
      maxw = math.max(maxw, vim.fn.strdisplaywidth(l))
    end
    local w, h = vim.api.nvim_win_get_width(f), vim.api.nvim_win_get_height(f)
    assert.is_true(w >= maxw, ("float width %d is narrower than its widest line %d"):format(w, maxw))
    assert.is_true(w <= maxw + 4, ("float width %d is much wider than its content %d"):format(w, maxw))
    assert.equals(#lines, h, "float height is not the number of lines")
  end)
end)
