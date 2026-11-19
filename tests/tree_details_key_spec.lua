-- Bead beads_nvim-8in: K in the tree opens the peek float (bead details) for the row bead.
-- Interface under test:
--   * keymaps.tree_view.details (default "K"; a key, a list of keys or false = disabled).
--   * K on a bead row opens the peek float for that row's bead wherever the cursor is on the line;
--     on the header (or any line without a bead) it does nothing and raises no error.
--   * K on a bead already open in a float focuses that float (no second float).
--   * With marks set, K opens only the bead under the cursor.
--   * The tree ? / g? help and README.md list K.
-- Fixture and fake bd: tests/peek_fake.lua.
-- assumption: the tree help line for K contains the token "K" and the word "detail" or "peek".
-- assumption: README.md lists `K` as a code span and names the config key `details`
--   (as keymaps.tree_view.details).

local fake = require("tests.peek_fake")

local function row_of(win, id)
  for i, l in ipairs(fake.lines_of(win)) do
    -- The row's own id: the first whole-id match that is not part of a
    -- "blocked by <id>" annotation (pk-b2y's row reads "... blocked by pk-c3z").
    local s = l:find("%f[%w%-%.]" .. vim.pesc(id) .. "%f[^%w%-%.]")
    if s and not l:sub(1, s - 1):find("blocked", 1, true) then
      return i
    end
  end
  error(("row of %s not found in tree:\n%s"):format(id, fake.text_of(win)), 0)
end

local function help_lines(win, keys)
  local before = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    before[w] = true
  end
  fake.press(win, keys)
  local found
  vim.wait(1000, function()
    for _, w in ipairs(fake.floats()) do
      if not before[w] then
        found = w
        return true
      end
    end
    return false
  end, 10)
  assert.is_not_nil(found, keys .. " opened no help float")
  return fake.lines_of(found)
end

local function has_details_line(lines)
  for _, l in ipairs(lines) do
    local low = l:lower()
    if
      vim.list_contains(vim.split(vim.trim(l), "[%s,/]+"), "K")
      and (low:find("detail", 1, true) or low:find("peek", 1, true))
    then
      return true
    end
  end
  return false
end

describe("tree K (details)", function()
  before_each(function()
    fake.setup({})
  end)

  after_each(function()
    fake.teardown()
  end)

  it("maps K in the tree by default", function()
    local tree = fake.open_tree()
    assert.is_not_nil(fake.buf_map(vim.api.nvim_win_get_buf(tree), "n", "K"), "K is not mapped in the tree")
  end)

  it("K at the start of a bead row opens the peek float for that bead", function()
    local tree = fake.open_tree()
    vim.api.nvim_win_set_cursor(tree, { row_of(tree, "pk-c3z"), 0 })
    local f = fake.peek(tree, "K", "pk-c3z")
    assert.are.equal(1, #fake.peeks(), "K opened more than one float: " .. fake.describe_floats())
    assert.are.equal(f, vim.api.nvim_get_current_win(), "the peek float is not focused")
  end)

  it("K on the title (not the id) of a bead row opens that bead", function()
    local tree = fake.open_tree()
    fake.cursor_on(tree, "Delta notes", 2)
    fake.peek(tree, "K", "pk-d4w")
  end)

  it("K at the end of a bead row opens that bead", function()
    local tree = fake.open_tree()
    local r = row_of(tree, "pk-b2y")
    vim.api.nvim_win_set_cursor(tree, { r, 0 })
    vim.api.nvim_win_call(tree, function()
      vim.cmd("normal! $")
    end)
    fake.peek(tree, "K", "pk-b2y")
  end)

  it("K on the header line does nothing and raises no error", function()
    local tree = fake.open_tree()
    -- a store refresh makes the tree render its header line (line 1: "beads · <root> · ...")
    fake.prefill()
    assert(vim.wait(3000, function()
      return (fake.lines_of(tree)[1] or ""):find("^beads · ") ~= nil
    end, 10), "tree has no header line:\n" .. fake.text_of(tree))
    vim.api.nvim_win_set_cursor(tree, { 1, 0 })
    local notes_before = #fake.notes
    local wins_before = #vim.api.nvim_list_wins()
    vim.v.errmsg = ""
    local ok, err = pcall(fake.press, tree, "K")
    assert.is_true(ok, "K on the header raised: " .. tostring(err))
    vim.wait(300, function()
      return false
    end, 10)
    assert.are.equal(0, #fake.peeks(), "K on the header opened a peek: " .. fake.describe_floats())
    assert.are.equal(wins_before, #vim.api.nvim_list_wins(), "K on the header opened a window")
    assert.are.equal(tree, vim.api.nvim_get_current_win(), "K on the header moved focus")
    assert.are.same({}, vim.list_slice(fake.notes, notes_before + 1), "K on the header notified")
    -- no Vim error either (e.g. the keywordprg fallback of K running :Man on the word)
    assert.are.equal("", vim.v.errmsg, "K on the header raised a Vim error")
  end)

  it("K on a bead already open in a float focuses it", function()
    local tree = fake.open_tree()
    vim.api.nvim_win_set_cursor(tree, { row_of(tree, "pk-c3z"), 0 })
    local f = fake.peek(tree, "K", "pk-c3z")
    vim.api.nvim_set_current_win(tree)
    vim.api.nvim_win_set_cursor(tree, { row_of(tree, "pk-c3z"), 0 })
    fake.press(tree, "K")
    vim.wait(300, function()
      return false
    end, 10)
    assert.are.equal(1, #fake.peeks(), "second K opened another float: " .. fake.describe_floats())
    assert.are.equal(f, vim.api.nvim_get_current_win(), "second K did not focus the open float")
  end)

  it("with several beads marked, K opens only the bead under the cursor", function()
    local tree = fake.open_tree()
    vim.api.nvim_win_set_cursor(tree, { row_of(tree, "pk-b2y"), 0 })
    fake.press(tree, "m")
    vim.api.nvim_win_set_cursor(tree, { row_of(tree, "pk-d4w"), 0 })
    fake.press(tree, "m")
    vim.api.nvim_win_set_cursor(tree, { row_of(tree, "pk-c3z"), 0 })
    fake.peek(tree, "K", "pk-c3z")
    vim.wait(300, function()
      return false
    end, 10)
    local peeks = fake.peeks()
    assert.are.equal(1, #peeks, "K with marks opened: " .. fake.describe_floats())
    assert.are.equal("pk-c3z", fake.shown_bead(peeks[1]))
  end)

  it("keymaps.tree_view.details remaps K", function()
    require("beads").setup({ keymaps = { tree_view = { details = "<F8>" } } })
    local tree = fake.open_tree()
    assert.is_nil(fake.buf_map(vim.api.nvim_win_get_buf(tree), "n", "K"), "K still mapped with details = '<F8>'")
    vim.api.nvim_win_set_cursor(tree, { row_of(tree, "pk-d4w"), 0 })
    fake.peek(tree, "<F8>", "pk-d4w")
  end)

  it("keymaps.tree_view.details = false disables K", function()
    require("beads").setup({ keymaps = { tree_view = { details = false } } })
    local tree = fake.open_tree()
    assert.is_nil(fake.buf_map(vim.api.nvim_win_get_buf(tree), "n", "K"), "K mapped in the tree with details = false")
  end)

  it("the tree ? help lists K", function()
    local tree = fake.open_tree()
    local lines = help_lines(tree, "?")
    assert.is_true(has_details_line(lines), "tree ? help has no K line:\n" .. table.concat(lines, "\n"))
  end)

  it("the tree g? help lists K", function()
    local tree = fake.open_tree()
    local lines = help_lines(tree, "g?")
    assert.is_true(has_details_line(lines), "tree g? help has no K line:\n" .. table.concat(lines, "\n"))
  end)

  it("README.md lists K and keymaps.tree_view.details", function()
    local text = table.concat(vim.fn.readfile(fake.plugin_root .. "/README.md"), "\n")
    assert.is_truthy(text:find("`K`", 1, true), "README.md does not list `K`")
    assert.is_truthy(text:find("details", 1, true), "README.md does not name the details action")
  end)
end)
