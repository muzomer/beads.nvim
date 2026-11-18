-- Findings for bead beads_nvim-4u9.14 (blocker lua/beads/views/tree.lua:174): in a fresh nvim with
-- no tree or picker opened, the store of the root was never loaded, so ]b in a detail buffer said
-- 'Beads: no next bead' instead of jumping. tests/detail_jump_fake.lua's setup prefills the store,
-- so this spec switches to a brand-new root afterwards: its store has never been refreshed.

local fake = require("tests.detail_jump_fake")
local cli = require("beads.cli")
local store = require("beads.store")

describe("detail ]b / [b with the store not loaded yet (no tree open)", function()
  local prefilled_root

  before_each(function()
    fake.setup({})
    prefilled_root = cli.get_root()
    local r = vim.fn.tempname()
    vim.fn.mkdir(r, "p")
    cli.set_root(r)
    assert.are.same({}, vim.tbl_keys(store.get(r).by_id or {}), "the new root's store is already loaded")
  end)

  after_each(function()
    fake.teardown()
    pcall(vim.fn.delete, prefilled_root, "rf")
  end)

  it("]b loads the beads and opens the next bead in default tree order", function()
    local win = vim.api.nvim_get_current_win()
    fake.edit_in(win, "ep-s")
    fake.jump(win, "]b", "gc-x")
    assert.is_false(fake.said("Beads: no next bead"), "said 'Beads: no next bead' although gc-x follows ep-s")
  end)

  it("[b loads the beads and opens the previous bead in default tree order", function()
    local win = vim.api.nvim_get_current_win()
    fake.edit_in(win, "gc-x")
    fake.jump(win, "[b", "ep-s")
    assert.is_false(fake.said("Beads: no previous bead"), "said 'Beads: no previous bead' although ep-s precedes gc-x")
  end)
end)
