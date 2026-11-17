-- Bead beads_nvim-4gx.8: default global keymaps (set by require("beads").setup()).
-- Interface under test: after setup(), normal-mode global maps
--   <leader>bt toggle tree, <leader>br ready picker, <leader>bl list picker,
--   <leader>bs search picker (prompts for the query via vim.ui.input), <leader>bn needs-me picker,
--   <leader>be epics picker, <leader>bc create bead (beads://new),
--   <leader>b? help float with the keys that work where you are.
-- fzf-lua is absent, so pickers use vim.ui.select (stubbed). bd is a fake (tests/picker_fake.lua).

local fake = require("tests.picker_fake")

local captured

local function stub_ui()
  captured = nil
  vim.ui.select = function(items, opts, on_choice)
    captured = { items = items, opts = opts or {}, on_choice = on_choice }
  end
  vim.ui.input = function(_, cb)
    cb("foo")
  end
end

local function picked_ids()
  assert(vim.wait(2000, function()
    return captured ~= nil
  end, 10), "no picker opened (vim.ui.select never called)")
  local fmt = captured.opts.format_item or tostring
  local lines = {}
  for i, it in ipairs(captured.items) do
    lines[i] = fmt(it)
  end
  return fake.ids_of(lines)
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

local function snapshot_wins()
  local s = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    s[w] = true
  end
  return s
end

local function press_for_float(keys)
  local before = snapshot_wins()
  press(keys)
  local found
  vim.wait(1000, function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if not before[w] and vim.api.nvim_win_get_config(w).relative ~= "" then
        found = w
        return true
      end
    end
    return false
  end, 10)
  return found
end

local function float_text(w)
  local t = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), "\n")
  pcall(vim.api.nvim_win_close, w, true)
  return t
end

describe("beads global keymaps", function()
  before_each(function()
    fake.setup()
    package.loaded["fzf-lua"] = nil
    package.preload["fzf-lua"] = function()
      error("fzf-lua is not installed (test)")
    end
    require("beads").setup({})
    stub_ui()
  end)

  after_each(function()
    fake.teardown()
  end)

  it("<leader>bt toggles the tree", function()
    local before = snapshot_wins()
    press("<leader>bt")
    local tree
    assert(vim.wait(2000, function()
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if not before[w] then
          tree = w
          return true
        end
      end
      return false
    end, 10), "<leader>bt opened no window")
    vim.api.nvim_set_current_win(tree)
    press("<leader>bt")
    assert(vim.wait(1000, function()
      return not vim.api.nvim_win_is_valid(tree)
    end, 10), "<leader>bt did not close the tree")
  end)

  for _, case in ipairs({
    { "<leader>br", "ready" },
    { "<leader>bl", "list" },
    { "<leader>bn", "needs" },
    { "<leader>be", "epics" },
  }) do
    it(case[1] .. " opens the " .. case[2] .. " picker", function()
      press(case[1])
      assert.are.same(fake.sorted(fake.EXPECTED[case[2]]), picked_ids())
    end)
  end

  it("<leader>bs prompts for the query and opens the search picker", function()
    local prompted = false
    vim.ui.input = function(_, cb)
      prompted = true
      cb("foo")
    end
    press("<leader>bs")
    assert.are.same(fake.sorted(fake.EXPECTED.search), picked_ids())
    assert.is_true(prompted, "no query prompt")
    local searched = false
    for _, a in ipairs(fake.args_log()) do
      if a:match("search%s+foo") then
        searched = true
      end
    end
    assert.is_true(searched, "bd search foo was not run")
  end)

  it("<leader>bc opens beads://new", function()
    press("<leader>bc")
    pcall(vim.cmd, "stopinsert")
    assert(fake.wait_buf("beads://new"), "current buffer is " .. vim.api.nvim_buf_get_name(0))
  end)

  it("<leader>b? in a plain buffer opens a help float listing the global keys", function()
    local f = press_for_float("<leader>b?")
    assert.is_not_nil(f, "<leader>b? opened no float")
    local text = float_text(f)
    local hit = false
    for _, l in ipairs(vim.split(text, "\n")) do
      if l:find("bt", 1, true) and l:lower():find("tree", 1, true) then
        hit = true
      end
    end
    assert.is_true(hit, "help has no line for the global tree key:\n" .. text)
  end)

  it("<leader>b? in a detail buffer lists the detail view keys", function()
    vim.cmd.edit("beads://op-a")
    local buf = vim.api.nvim_get_current_buf()
    assert(vim.wait(2000, function()
      return require("beads.views.detail").snapshot(buf) ~= nil
    end, 10), "detail buffer never loaded")
    local f = press_for_float("<leader>b?")
    assert.is_not_nil(f, "<leader>b? opened no float in the detail buffer")
    local text = float_text(f)
    assert.is_truthy(text:find("yr", 1, true), "help does not list the detail key yr:\n" .. text)
  end)

  it("? in the tree opens the tree help float", function()
    vim.cmd("Beads tree")
    local tbuf = vim.api.nvim_get_current_buf()
    local km
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(tbuf, "n")) do
      if m.lhs == "?" then
        km = m
      end
    end
    assert.is_not_nil(km, "? is not mapped in the tree")
    local f = press_for_float("?")
    assert.is_not_nil(f, "? in the tree opened no float")
    local text = float_text(f)
    assert.is_truthy(text:lower():find("refresh", 1, true), "tree help does not list refresh:\n" .. text)
  end)
end)
