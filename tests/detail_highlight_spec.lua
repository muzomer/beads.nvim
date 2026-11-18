-- Bead beads_nvim-4u9.8: detail buffer highlighting and relative comment times.
-- Interface under test:
--   * Frontmatter values carry extmark highlights (hl_group, any namespace) over the value text:
--       id: <id>          -> BeadsId
--       status: <s>       -> BeadsStatus<S>      (open -> BeadsStatusOpen, in_progress -> BeadsStatusInProgress)
--       priority: <n>     -> BeadsPriority<n>
--       type: <t>         -> BeadsType<T>
--       labels: [a, b]    -> some Beads* group on each label
--       parent: <id>      -> BeadsId
--       blocked_by: [ids] -> BeadsId on each id
--   * Read-only regions (Workflow, Notes, Comments) are dimmed with BeadsDim.
--   * Comment timestamps are shown relative to the clock, e.g. "2h ago", "3d ago", either in the
--     line text or as virtual text on the comment heading line. The clock is injectable:
--     require("beads").setup({ now = function() return <unix seconds> end }).
-- bd is a fake on PATH (tests/detail_winbar_fake.lua).

local fake = require("tests.detail_winbar_fake")

-- 2026-11-18T12:00:00Z
local NOW = 1795003200

local function groups_over(buf, row, col)
  return fake.groups_at(buf, row, col)
end

-- Asserts that `group` covers every byte of `word` on the frontmatter line starting with `prefix`.
local function assert_value_group(buf, prefix, word, group)
  local row, line = fake.row_of(buf, prefix)
  local s = line:find(word, #prefix + 1, true)
  assert(s, "'" .. word .. "' not on line " .. vim.inspect(line))
  for col = s - 1, s - 2 + #word do
    local gs = groups_over(buf, row, col)
    assert.is_true(
      vim.tbl_contains(gs, group),
      ("%s at %q col %d: expected %s, got %s"):format(word, line, col, group, vim.inspect(gs))
    )
  end
end

local function assert_some_beads_group(buf, prefix, word)
  local row, line = fake.row_of(buf, prefix)
  local s = line:find(word, #prefix + 1, true)
  assert(s, "'" .. word .. "' not on line " .. vim.inspect(line))
  local gs = groups_over(buf, row, s - 1)
  local found = false
  for _, g in ipairs(gs) do
    if g:match("^Beads") and g ~= "BeadsDim" then
      found = true
    end
  end
  assert.is_true(found, ("%s on %q has no Beads* value group: %s"):format(word, line, vim.inspect(gs)))
end

local function has_line_hl(buf, row, group)
  local marks = vim.api.nvim_buf_get_extmarks(buf, -1, { row, 0 }, { row, -1 }, { details = true })
  for _, m in ipairs(marks) do
    if m[4].line_hl_group == group then
      return true
    end
  end
  for _, g in ipairs(fake.groups_at(buf, row, 0)) do
    if g == group then
      return true
    end
  end
  return false
end

describe("detail frontmatter highlighting", function()
  after_each(function()
    fake.teardown()
  end)

  it("colours status, priority, type, labels and ids of an open task", function()
    fake.setup({
      labels = { "ui", "polish" },
      parent = "wb-0",
      dependencies = {
        { id = "wb-9", dependency_type = "blocks", title = "Blocker", status = "open" },
        { id = "wb-0", dependency_type = "parent-child", title = "Parent", status = "open" },
      },
    })
    require("beads").setup({})
    local buf = fake.open_detail()
    fake.wait_for(function()
      local row = fake.row_of(buf, "status: ")
      return #groups_over(buf, row, #"status: ") > 0
    end, "frontmatter highlights", 2000)
    assert_value_group(buf, "id: ", "wb-1", "BeadsId")
    assert_value_group(buf, "status: ", "open", "BeadsStatusOpen")
    assert_value_group(buf, "priority: ", "2", "BeadsPriority2")
    assert_value_group(buf, "type: ", "task", "BeadsTypeTask")
    assert_some_beads_group(buf, "labels: ", "ui")
    assert_some_beads_group(buf, "labels: ", "polish")
    assert_value_group(buf, "parent: ", "wb-0", "BeadsId")
    assert_value_group(buf, "blocked_by: ", "wb-9", "BeadsId")
  end)

  it("matches the groups to the bead (in_progress, P0, epic)", function()
    fake.setup({ status = "in_progress", priority = 0, issue_type = "epic" })
    require("beads").setup({})
    local buf = fake.open_detail()
    fake.wait_for(function()
      local row = fake.row_of(buf, "status: ")
      return #groups_over(buf, row, #"status: ") > 0
    end, "frontmatter highlights", 2000)
    assert_value_group(buf, "status: ", "in_progress", "BeadsStatusInProgress")
    assert_value_group(buf, "priority: ", "0", "BeadsPriority0")
    assert_value_group(buf, "type: ", "epic", "BeadsTypeEpic")
  end)

  it("does not colour the frontmatter keys as values", function()
    fake.setup()
    require("beads").setup({})
    local buf = fake.open_detail()
    fake.wait_for(function()
      local row = fake.row_of(buf, "status: ")
      return #groups_over(buf, row, #"status: ") > 0
    end, "frontmatter highlights", 2000)
    local row = fake.row_of(buf, "status: ")
    assert.is_false(vim.tbl_contains(groups_over(buf, row, 0), "BeadsStatusOpen"))
  end)

  it("dims the read-only Workflow, Notes and Comments regions with BeadsDim", function()
    -- passes already: guards the existing BeadsDim read-only regions
    fake.setup({ notes = "a note" })
    require("beads").setup({})
    local buf = fake.open_detail()
    for _, h in ipairs({ "## Workflow", "## Notes", "## Comments" }) do
      local row = fake.row_of(buf, h)
      assert.is_true(has_line_hl(buf, row, "BeadsDim"), h .. " not dimmed")
    end
  end)
end)

describe("detail relative comment times", function()
  after_each(function()
    fake.teardown()
  end)

  it("shows '2h ago' and '3d ago' with a fixed clock", function()
    fake.setup({
      comments = {
        { id = 1, author = "alice", text = "recent comment", created_at = "2026-11-18T10:00:00Z" },
        { id = 2, author = "bob", text = "older comment", created_at = "2026-11-15T12:00:00Z" },
      },
    })
    require("beads").setup({
      now = function()
        return NOW
      end,
    })
    local buf = fake.open_detail()
    local alice = fake.row_of(buf, "### alice")
    local bob = fake.row_of(buf, "### bob")
    fake.wait_for(function()
      return fake.shown_text(buf, alice):find("2h ago", 1, true) ~= nil
    end, "'2h ago' on alice's comment: " .. vim.inspect(fake.shown_text(buf, alice)), 2000)
    assert.is_truthy(
      fake.shown_text(buf, bob):find("3d ago", 1, true),
      "'3d ago' missing on bob's comment: " .. vim.inspect(fake.shown_text(buf, bob))
    )
    assert.is_nil(fake.shown_text(buf, alice):find("3d ago", 1, true))
  end)
end)
