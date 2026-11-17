-- Bead beads_nvim-4gx.8: README.md lists all default keys.
-- Assumption: every key appears as a markdown code span, e.g. `x` or `<leader>bt`.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local KEYS = {
  -- global
  "<leader>bt", "<leader>br", "<leader>bl", "<leader>bs", "<leader>bn", "<leader>be", "<leader>bc", "<leader>b?",
  -- detail view
  "e", "i", "x", "C", "n", "c", "yy", "yr", "q", "?", "g?",
  -- detail edit
  "<C-s>", "<Esc><Esc>",
  -- tree
  "<CR>", "a", "R", "H",
  -- input floats
  "<Esc>",
  -- fzf picker
  "ctrl-y", "alt-r", "ctrl-x",
}

describe("README.md", function()
  it("lists every default key as a code span", function()
    local path = root .. "/README.md"
    assert.equals(1, vim.fn.filereadable(path), "README.md missing")
    local text = table.concat(vim.fn.readfile(path), "\n")
    local missing = {}
    for _, k in ipairs(KEYS) do
      if not text:find("`" .. k .. "`", 1, true) then
        missing[#missing + 1] = k
      end
    end
    assert.are.same({}, missing, "README.md does not list: " .. table.concat(missing, ", "))
  end)

end)
