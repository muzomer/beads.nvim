-- Bead beads_nvim-4u9.8, review findings (lua/beads/views/detail.lua:617):
--   * the detail winbar must not leak into other windows: ':split foo.txt' from a detail window,
--     and a plain ':split' sibling after ':e beads://<other>' in the original window;
--   * a detail window that switches to a non-beads buffer (':e notes.txt') must lose its winbar row.
-- bd is a fake on PATH (tests/detail_winbar_fake.lua), extended here to serve two beads by id.

local fake = require("tests.detail_winbar_fake")

local ID2 = "wb-2"

-- Replaces the fake bd (argv: -C <root> <subcommand> ...) with one that answers `show <id>` from <dir>/<id>.json and `list` with both beads.
local function serve_two_beads()
  local dir = fake.dir()
  local a = fake.bead()
  local b = fake.bead({ id = ID2, title = "Second bead", status = "in_progress", priority = 0, issue_type = "bug" })
  vim.fn.writefile({ vim.json.encode({ a }) }, dir .. "/" .. fake.ID .. ".json")
  vim.fn.writefile({ vim.json.encode({ b }) }, dir .. "/" .. ID2 .. ".json")
  vim.fn.writefile({ vim.json.encode({ a, b }) }, dir .. "/list.json")
  local q = vim.fn.shellescape
  vim.fn.writefile({
    "#!/bin/sh",
    'echo "$*" >> ' .. q(dir .. "/calls.log"),
    'prev=',
    'for a in "$@"; do',
    '  if [ "$prev" = show ]; then cat ' .. q(dir) .. '"/$a.json"; exit 0; fi',
    '  case "$a" in',
    "    list) cat " .. q(dir .. "/list.json") .. "; exit 0;;",
    "    ready) echo '[]'; exit 0;;",
    "  esac",
    '  prev="$a"',
    "done",
    "echo '{}'",
  }, dir .. "/bd")
  vim.fn.setfperm(dir .. "/bd", "rwxr-xr-x")
end

local function has_winbar_row(win)
  return vim.fn.getwininfo(win)[1].winbar == 1
end

local function wb_str(win)
  return fake.winbar(win).str
end

describe("detail winbar in other windows (findings)", function()
  before_each(function()
    fake.setup()
    serve_two_beads()
    require("beads").setup({})
  end)

  after_each(function()
    fake.teardown()
  end)

  it("':split foo.txt' from a detail window gives foo.txt no bead winbar", function()
    local win_a = vim.api.nvim_get_current_win()
    fake.open_detail()
    fake.wait_for(function()
      return wb_str(win_a):find("wb-1", 1, true)
    end, "winbar on detail window", 2000)

    vim.cmd("split " .. vim.fn.fnameescape(fake.dir() .. "/foo.txt"))
    local win_f = vim.api.nvim_get_current_win()
    assert.are_not.equal(win_a, win_f)
    vim.cmd.redraw()

    assert.is_nil(wb_str(win_f):find("wb-1", 1, true), "foo.txt window shows: " .. vim.inspect(wb_str(win_f)))
    assert.is_false(has_winbar_row(win_f), "foo.txt window has a winbar row")
    -- the detail window keeps its own winbar
    assert.truthy(wb_str(win_a):find("wb-1", 1, true))
  end)

  it("':split' then ':e foo.txt' from a detail window gives foo.txt no bead winbar", function()
    local win_a = vim.api.nvim_get_current_win()
    fake.open_detail()
    fake.wait_for(function()
      return wb_str(win_a):find("wb-1", 1, true)
    end, "winbar on detail window", 2000)

    vim.cmd("split")
    local win_s = vim.api.nvim_get_current_win()
    vim.cmd("edit " .. vim.fn.fnameescape(fake.dir() .. "/foo.txt"))
    vim.cmd.redraw()

    assert.is_nil(wb_str(win_s):find("wb-1", 1, true), "foo.txt window shows: " .. vim.inspect(wb_str(win_s)))
    assert.is_false(has_winbar_row(win_s), "foo.txt window has a winbar row")
  end)

  it("a plain ':split' sibling keeps bead A's winbar after ':e' to bead B in the original window", function()
    local win_a = vim.api.nvim_get_current_win()
    local buf_a = fake.open_detail()
    fake.wait_for(function()
      return wb_str(win_a):find("wb-1", 1, true)
    end, "winbar on detail window", 2000)

    vim.cmd("split")
    local win_s = vim.api.nvim_get_current_win()
    assert.equals(buf_a, vim.api.nvim_win_get_buf(win_s))

    vim.api.nvim_set_current_win(win_a)
    vim.cmd("edit beads://" .. ID2)
    local buf_b = vim.api.nvim_get_current_buf()
    fake.wait_for(function()
      return require("beads.views.detail").snapshot(buf_b) ~= nil
        and vim.tbl_contains(vim.api.nvim_buf_get_lines(buf_b, 0, -1, false), "# Second bead")
    end, "second detail buffer load")
    fake.wait_for(function()
      return wb_str(win_a):find(ID2, 1, true)
    end, "winbar of bead B in window A (got " .. vim.inspect(wb_str(win_a)) .. ")", 2000)
    vim.cmd.redraw()

    local s = wb_str(win_s)
    assert.equals(buf_a, vim.api.nvim_win_get_buf(win_s))
    assert.truthy(s:find("wb-1", 1, true), "sibling window shows: " .. vim.inspect(s))
    assert.is_nil(s:find(ID2, 1, true), "sibling window shows: " .. vim.inspect(s))
  end)

  it("':e notes.txt' in a detail window removes the winbar row", function()
    local win_a = vim.api.nvim_get_current_win()
    fake.open_detail()
    fake.wait_for(function()
      return wb_str(win_a):find("wb-1", 1, true)
    end, "winbar on detail window", 2000)
    assert.is_true(has_winbar_row(win_a))

    vim.cmd("edit " .. vim.fn.fnameescape(fake.dir() .. "/notes.txt"))
    vim.cmd.redraw()

    assert.equals(win_a, vim.api.nvim_get_current_win())
    assert.is_false(has_winbar_row(win_a), "notes.txt window still reserves a winbar row")
  end)
end)
