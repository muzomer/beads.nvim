-- Bead beads_nvim-4u9.14: ]b / [b in a detail buffer's VIEW mode open the next / previous bead in
-- tree order, in the same window (replacing the bead shown), keeping VIEW mode.
-- Interface under test (key presses only):
--   * keymaps.detail.view.next_bead (default "]b") / prev_bead (default "[b").
--   * Order = the order the tree displays (parent before children, depth-first), using the open
--     tree's sort, filter and closed visibility (H); folds do not hide beads. With no tree open:
--     default sort (priority), no filter, closed beads hidden.
--   * A count moves that many beads (2]b skips one).
--   * At the last / first bead nothing changes and 'Beads: no next bead' / 'Beads: no previous
--     bead' is shown.
--   * The tree's BeadsCurrent mark follows the jump; the landing line flashes (BeadsFlash).
-- Fixture and fake bd: tests/detail_jump_fake.lua.
-- assumption: the end messages may go through vim.notify or the message history (:messages).
-- assumption: a count that overshoots the list is not tested (not specified).

local fake = require("tests.detail_jump_fake")

local function header(tree)
  return fake.lines_of(tree)[1] or ""
end

describe("detail ]b / [b jump", function()
  before_each(function()
    fake.setup({})
  end)

  after_each(function()
    fake.teardown()
  end)

  describe("with no tree open", function()
    it("]b opens the next bead in default tree order in the same window, keeping VIEW; [b goes back", function()
      local win = vim.api.nvim_get_current_win()
      fake.edit_in(win, "ep-s")
      fake.jump(win, "]b", "gc-x")
      fake.jump(win, "[b", "ep-s")
    end)

    it("skips closed beads", function()
      local win = vim.api.nvim_get_current_win()
      fake.edit_in(win, "ep-a")
      fake.jump(win, "]b", "ep-s")
      fake.jump(win, "[b", "ep-a")
    end)

    it("walks the whole default order forwards", function()
      local win = vim.api.nvim_get_current_win()
      local order = fake.DEFAULT_ORDER
      fake.edit_in(win, order[1])
      for i = 2, #order do
        fake.jump(win, "]b", order[i])
      end
    end)

    it("a count moves that many beads", function()
      local win = vim.api.nvim_get_current_win()
      fake.edit_in(win, "ep-a")
      fake.jump(win, "2]b", "gc-x")
      fake.jump(win, "3]b", "ep-t")
      fake.jump(win, "2[b", "gc-y")
    end)

    it("]b at the last bead stays put and says 'Beads: no next bead'", function()
      local win = vim.api.nvim_get_current_win()
      local buf = fake.edit_in(win, "tc-2")
      local cursor = vim.api.nvim_win_get_cursor(win)
      fake.press(win, "]b")
      assert(vim.wait(1000, function()
        return fake.said("Beads: no next bead")
      end, 10), "no 'Beads: no next bead' message; notify got: " .. vim.inspect(fake.notes))
      vim.wait(200, function()
        return false
      end, 10)
      assert.are.equal(buf, vim.api.nvim_win_get_buf(win), "]b at the last bead changed the buffer")
      assert.are.same(cursor, vim.api.nvim_win_get_cursor(win), "]b at the last bead moved the cursor")
      assert.are.equal(win, vim.api.nvim_get_current_win())
    end)

    it("[b at the first bead stays put and says 'Beads: no previous bead'", function()
      local win = vim.api.nvim_get_current_win()
      local buf = fake.edit_in(win, "ep-a")
      local cursor = vim.api.nvim_win_get_cursor(win)
      fake.press(win, "[b")
      assert(vim.wait(1000, function()
        return fake.said("Beads: no previous bead")
      end, 10), "no 'Beads: no previous bead' message; notify got: " .. vim.inspect(fake.notes))
      vim.wait(200, function()
        return false
      end, 10)
      assert.are.equal(buf, vim.api.nvim_win_get_buf(win), "[b at the first bead changed the buffer")
      assert.are.same(cursor, vim.api.nvim_win_get_cursor(win), "[b at the first bead moved the cursor")
    end)
  end)

  describe("with the tree open", function()
    it("follows the displayed default order and moves the BeadsCurrent mark", function()
      local tree = fake.open_tree()
      assert.are.same(fake.DEFAULT_ORDER, fake.tree_order(tree), "setup: unexpected tree order")
      local main = fake.main_win(tree)
      fake.edit_in(main, "gc-y")
      assert(fake.wait_current(tree, "gc-y"), fake.current_msg(tree, "gc-y"))
      fake.jump(main, "]b", "bl-d")
      assert(fake.wait_current(tree, "bl-d"), fake.current_msg(tree, "bl-d"))
      fake.jump(main, "[b", "gc-y")
      assert(fake.wait_current(tree, "gc-y"), fake.current_msg(tree, "gc-y"))
    end)

    it("the landing line flashes like other jumps", function()
      local tree = fake.open_tree()
      local main = fake.main_win(tree)
      fake.edit_in(main, "bl-d")
      -- let the open flash (if any) expire first
      vim.wait(800, function()
        return #fake.all_flashes() == 0
      end, 10)
      fake.jump(main, "]b", "ep-t")
      assert(vim.wait(1000, function()
        return fake.flash_on_cursor(main)
      end, 5), "no BeadsFlash on the landing line; flashes: {" .. table.concat(fake.all_flashes(), ",") .. "}")
    end)

    it("follows the tree's sort (sort: id)", function()
      local tree = fake.open_tree()
      local main = fake.main_win(tree)
      fake.press(tree, "s")
      fake.press(tree, "s")
      assert(vim.wait(2000, function()
        return header(tree):find("sort: id", 1, true) ~= nil
      end, 10), "setup: tree header does not show 'sort: id': " .. header(tree))
      assert(vim.wait(2000, function()
        return vim.deep_equal(fake.ID_SORT_ORDER, fake.tree_order(tree))
      end, 10), "setup: tree not in id order:\n" .. fake.dump(tree))
      fake.edit_in(main, "bl-d")
      fake.jump(main, "]b", "ep-a")
      fake.jump(main, "]b", "ep-s")
      fake.edit_in(main, "gc-y")
      fake.jump(main, "]b", "ep-t")
      fake.jump(main, "[b", "gc-y")
    end)

    it("follows the tree's filter, including dimmed ancestors", function()
      local tree = fake.open_tree()
      local main = fake.main_win(tree)
      vim.ui.input = function(_, cb)
        cb("type:epic")
      end
      fake.press(tree, "f")
      assert(vim.wait(2000, function()
        return vim.deep_equal(fake.EPIC_FILTER_ORDER, fake.tree_order(tree))
      end, 10), "setup: filter type:epic not applied:\n" .. fake.dump(tree))
      fake.edit_in(main, "ep-s")
      fake.jump(main, "]b", "ep-t")
      fake.jump(main, "[b", "ep-s")
      fake.jump(main, "[b", "ep-a")
      fake.notes = {}
      pcall(vim.cmd, "messages clear")
      local buf = vim.api.nvim_win_get_buf(main)
      fake.press(main, "[b")
      assert(vim.wait(1000, function()
        return fake.said("Beads: no previous bead")
      end, 10), "no 'Beads: no previous bead' at the first filtered bead")
      assert.are.equal(buf, vim.api.nvim_win_get_buf(main))
    end)

    it("includes closed beads only when H shows them", function()
      local tree = fake.open_tree()
      local main = fake.main_win(tree)
      fake.edit_in(main, "ep-a")
      fake.jump(main, "]b", "ep-s")
      fake.press(tree, "H")
      assert(vim.wait(2000, function()
        return vim.deep_equal(fake.CLOSED_SHOWN_ORDER, fake.tree_order(tree))
      end, 10), "setup: H did not show the closed bead:\n" .. fake.dump(tree))
      fake.jump(main, "[b", "ch-b")
      fake.jump(main, "[b", "ep-a")
      fake.jump(main, "]b", "ch-b")
      fake.jump(main, "]b", "ep-s")
    end)

    it("beads inside closed folds are still reachable", function()
      local tree = fake.open_tree()
      local main = fake.main_win(tree)
      fake.edit_in(main, "ep-a")
      vim.api.nvim_win_call(tree, function()
        vim.cmd("silent! normal! zM")
      end)
      local rs = fake.row_of(tree, "ep-s")
      assert.are_not.equal(-1, vim.api.nvim_win_call(tree, function()
        return vim.fn.foldclosed(rs)
      end), "setup: ep-s is not inside a closed fold after zM:\n" .. fake.dump(tree))
      fake.jump(main, "]b", "ep-s")
      fake.jump(main, "]b", "gc-x")
    end)
  end)
end)
