-- Bead beads_nvim-4gx.8: overriding and disabling global keymaps.
-- Interface under test: require("beads").setup({ keymaps = { tree = "<leader>xt", list = false } })
--   maps <leader>xt to the tree toggle (with a desc), leaves <leader>bt and <leader>bl unmapped,
--   keeps the other defaults (<leader>br), and <leader>b? lists the overridden key.
-- setup() is called exactly once in this file (each spec file runs in its own nvim).

local fake = require("tests.picker_fake")

local function maparg(lhs)
  return vim.fn.maparg(lhs, "n", false, true)
end

describe("beads global keymap overrides", function()
  it("override and disable change the global maps and the help float", function()
    fake.setup()
    local ok, err = pcall(function()
      require("beads").setup({ keymaps = { tree = "<leader>xt", list = false } })
      local m = maparg("<leader>xt")
      assert.is_true(next(m) ~= nil, "<leader>xt is not mapped")
      assert.is_true(type(m.desc) == "string" and m.desc ~= "", "<leader>xt has no desc")
      assert.is_true(m.buffer ~= 1, "<leader>xt is buffer-local, not global")
      assert.are.same({}, maparg("<leader>bt"), "default <leader>bt still mapped after override")
      assert.are.same({}, maparg("<leader>bl"), "<leader>bl still mapped with keymaps.list = false")
      assert.is_true(next(maparg("<leader>br")) ~= nil, "other global defaults were lost")

      local before = {}
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        before[w] = true
      end
      vim.api.nvim_feedkeys(vim.keycode("<leader>b?"), "x", false)
      local f
      vim.wait(1000, function()
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          if not before[w] and vim.api.nvim_win_get_config(w).relative ~= "" then
            f = w
            return true
          end
        end
        return false
      end, 10)
      assert.is_not_nil(f, "<leader>b? opened no float")
      local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(f), 0, -1, false)
      local text = table.concat(lines, "\n")
      local hit = false
      for _, l in ipairs(lines) do
        if l:find("xt", 1, true) and l:lower():find("tree", 1, true) then
          hit = true
        end
        assert.is_nil(l:find("bt", 1, true), "help still lists the default tree key:\n" .. text)
      end
      assert.is_true(hit, "help has no line with the overridden tree key:\n" .. text)
    end)
    fake.teardown()
    assert(ok, err)
  end)
end)
