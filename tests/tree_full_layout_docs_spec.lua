-- Bead beads_nvim-i7f: README and the tree help (?) describe the default view and tree.layout.
-- assumption: README.md names the option `tree.layout` and both values "full" and "split", and
--   says that "full" is the default (a line with tree.layout and the word "default").
-- assumption: the tree help (keymaps tree_view help, ? / g?) has a line naming `tree.layout`.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function help_text()
  local before = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    before[w] = true
  end
  require("beads.keys").help_float("tree_view")
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if not before[w] and vim.api.nvim_win_get_config(w).relative ~= "" then
      local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), "\n")
      pcall(vim.api.nvim_win_close, w, true)
      return text
    end
  end
  error("the tree help opened no float", 0)
end

describe("tree.layout docs", function()
  before_each(function()
    require("beads").setup({})
  end)

  it("README describes tree.layout with the values full (default) and split", function()
    local lines = vim.fn.readfile(root .. "/README.md")
    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("tree.layout", 1, true), "README does not mention tree.layout")
    assert.is_truthy(text:find('"full"', 1, true), 'README does not mention the value "full"')
    assert.is_truthy(text:find('"split"', 1, true), 'README does not mention the value "split"')
    local said_default = false
    for _, l in ipairs(lines) do
      if l:find("tree.layout", 1, true) and l:lower():find("default", 1, true) then
        said_default = true
      end
    end
    assert.is_true(said_default, "no README line says what tree.layout defaults to")
  end)

  it("the tree help mentions tree.layout", function()
    local text = help_text()
    assert.is_truthy(text:find("tree.layout", 1, true), "tree help does not mention tree.layout:\n" .. text)
  end)
end)
