-- Bead beads_nvim-4gx.8: setup({ keymaps = false }) creates no maps at all.
-- Interface under test: after require("beads").setup({ keymaps = false }) no global map is added,
--   and the detail buffer and the tree buffer get no buffer-local maps from the plugin
--   (maps from Nvim's own runtime, e.g. ftplugin/markdown.vim, are ignored).
-- setup() is called exactly once in this file (each spec file runs in its own nvim).

local MODES = { "n", "i", "x", "s", "o", "c", "t" }
local function global_maps()
  local out = {}
  for _, m in ipairs(MODES) do
    for _, km in ipairs(vim.api.nvim_get_keymap(m)) do
      out[m .. " " .. km.lhs] = true
    end
  end
  return out
end
local BASELINE = global_maps()

local fake = require("tests.picker_fake")

local VIMRUNTIME = vim.fs.normalize(vim.env.VIMRUNTIME)
local function from_runtime(km)
  if not km.sid or km.sid <= 0 then
    return false
  end
  local info = vim.fn.getscriptinfo({ sid = km.sid })[1]
  return info ~= nil and vim.startswith(vim.fs.normalize(info.name), VIMRUNTIME)
end

local function plugin_buf_maps(buf)
  local out = {}
  for _, m in ipairs({ "n", "i", "x", "s", "o" }) do
    for _, km in ipairs(vim.api.nvim_buf_get_keymap(buf, m)) do
      if not from_runtime(km) then
        out[#out + 1] = m .. " " .. km.lhs
      end
    end
  end
  return out
end

describe("beads keymaps = false", function()
  it("adds no global maps and no buffer-local maps in detail and tree", function()
    fake.setup()
    local ok, err = pcall(function()
      require("beads").setup({ keymaps = false })
      local added = {}
      for k in pairs(global_maps()) do
        if not BASELINE[k] then
          added[#added + 1] = k
        end
      end
      assert.are.same({}, added, "global keymaps added: " .. table.concat(added, ", "))

      vim.cmd.edit("beads://op-a")
      local dbuf = vim.api.nvim_get_current_buf()
      assert(vim.wait(2000, function()
        return require("beads.views.detail").snapshot(dbuf) ~= nil
      end, 10), "detail buffer never loaded")
      assert.are.same({}, plugin_buf_maps(dbuf), "detail buffer has plugin maps")

      vim.cmd("Beads tree")
      local tbuf = vim.api.nvim_get_current_buf()
      assert.is_true(tbuf ~= dbuf, ":Beads tree did not focus the tree")
      assert.are.same({}, plugin_buf_maps(tbuf), "tree buffer has plugin maps")
    end)
    fake.teardown()
    assert(ok, err)
  end)
end)
