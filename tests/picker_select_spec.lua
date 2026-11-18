-- Interface under test (bead beads_nvim-ge7.13): pickers via :Beads ready|list|search|needs|epics
-- with fzf-lua ABSENT, so the vim.ui.select adapter (lua/beads/pickers/select.lua) is used.
--   Sources: ready (bd ready --json), list (open + in_progress from the store),
--   search (bd search <q> --json; :Beads search <q>), needs (workflow.is_needs_me), epics (type epic).
--   Line: status glyph, id, P<priority>, title, workflow badges (bead beads_nvim-4u9.2).
--   Choosing an item opens beads://<id>.
-- vim.ui.select is stubbed to capture items; lines are read via opts.format_item (or tostring).
-- bd is a fake on PATH (tests/picker_fake.lua).

local fake = require("tests.picker_fake")

local captured

local function stub_select()
  captured = nil
  vim.ui.select = function(items, opts, on_choice)
    captured = { items = items, opts = opts or {}, on_choice = on_choice }
  end
  vim.ui.input = function(_, cb)
    cb("foo")
  end
end

local function lines()
  local fmt = captured.opts.format_item or tostring
  local out = {}
  for i, it in ipairs(captured.items) do
    out[i] = fake.strip(fmt(it))
  end
  return out
end

local function run(cmd)
  vim.cmd(cmd)
  assert(vim.wait(2000, function()
    return captured ~= nil
  end, 10), cmd .. " never called vim.ui.select")
  return lines()
end

describe("pickers without fzf-lua (vim.ui.select)", function()
  before_each(function()
    fake.setup()
    package.loaded["fzf-lua"] = nil
    package.preload["fzf-lua"] = function()
      error("fzf-lua is not installed (test)")
    end
    require("beads").setup({})
    assert.is_false(require("beads").config.fzf)
    stub_select()
  end)

  after_each(function()
    fake.teardown()
  end)

  it(":Beads ready lists the beads from bd ready --json", function()
    local l = run("Beads ready")
    assert.are.same(fake.sorted(fake.EXPECTED.ready), fake.ids_of(l))
    local called = false
    for _, a in ipairs(fake.args_log()) do
      if a:find("ready", 1, true) then
        called = true
      end
    end
    assert.is_true(called, "bd ready was not run")
  end)

  it(":Beads list lists only open and in_progress beads from the store", function()
    local l = run("Beads list")
    assert.are.same(fake.sorted(fake.EXPECTED.list), fake.ids_of(l))
  end)

  it(":Beads search foo lists the beads from bd search foo --json", function()
    local l = run("Beads search foo")
    assert.are.same(fake.sorted(fake.EXPECTED.search), fake.ids_of(l))
    local called = false
    for _, a in ipairs(fake.args_log()) do
      if a:match("search%s+foo") then
        called = true
      end
    end
    assert.is_true(called, "bd search foo was not run; log:\n" .. table.concat(fake.args_log(), "\n"))
  end)

  it(":Beads needs lists only beads labeled human or needs-review", function()
    local l = run("Beads needs")
    assert.are.same(fake.sorted(fake.EXPECTED.needs), fake.ids_of(l))
  end)

  it(":Beads epics lists only beads of type epic", function()
    local l = run("Beads epics")
    assert.are.same(fake.sorted(fake.EXPECTED.epics), fake.ids_of(l))
  end)

  it("a line shows status glyph, id, priority, title and workflow badges", function()
    local l = run("Beads list")
    local line
    for _, x in ipairs(l) do
      if fake.line_id(x) == "op-a" then
        line = x
      end
    end
    assert.is_not_nil(line, "no line for op-a")
    local p_id = line:find("op-a", 1, true)
    local p_prio = line:find("P1", 1, true)
    local p_status = line:find(require("beads.glyphs").status("open"), 1, true)
    local p_title = line:find("Open alpha", 1, true)
    assert.is_not_nil(p_prio, "priority P1 missing: " .. line)
    assert.is_not_nil(p_status, "status missing: " .. line)
    assert.is_not_nil(p_title, "title missing: " .. line)
    assert.is_true(p_id < p_prio and p_prio < p_title, "id, priority, title out of order: " .. line)
    assert.is_truthy(line:find("✓", 1, true), "verdict badge missing: " .. line)
    assert.is_truthy(line:find("👤", 1, true), "human badge missing: " .. line)
  end)

  it("choosing an item opens the detail buffer beads://<id>", function()
    local l = run("Beads list")
    local idx
    for i, x in ipairs(l) do
      if fake.line_id(x) == "ot-g" then
        idx = i
      end
    end
    assert.is_not_nil(idx, "no line for ot-g")
    captured.on_choice(captured.items[idx], idx)
    assert(fake.wait_buf("beads://ot-g"), "current buffer is " .. vim.api.nvim_buf_get_name(0))
  end)

  it("cancelling the selection opens nothing", function()
    local before = vim.api.nvim_buf_get_name(0)
    run("Beads ready")
    captured.on_choice(nil, nil)
    vim.wait(200, function()
      return false
    end, 10)
    assert.are.equal(before, vim.api.nvim_buf_get_name(0))
  end)
end)
