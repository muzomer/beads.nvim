-- Interface under test (bead beads_nvim-4gx.2):
--   require("beads").setup(opts) prepends <plugin>/bin to $PATH, so `beads-ask`
--   (bin/beads-ask, executable) resolves inside nvim.
--   skills/beads-ask/SKILL.md: agent instructions documenting every subcommand
--   (list, show, reply, resolve, propose) and their options, with name/description
--   frontmatter like code-review.nvim's skills/nvim-code-review/SKILL.md.

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local bin_dir = plugin_root .. "/bin"

describe("beads-ask on $PATH", function()
  local orig_path

  before_each(function()
    orig_path = vim.env.PATH
    local kept = {}
    for _, p in ipairs(vim.split(orig_path or "", ":", { plain = true })) do
      if vim.fn.fnamemodify(p, ":p"):gsub("/$", "") ~= bin_dir then
        kept[#kept + 1] = p
      end
    end
    vim.env.PATH = table.concat(kept, ":")
  end)

  after_each(function()
    vim.env.PATH = orig_path
  end)

  it("resolves to the plugin's bin/beads-ask after setup", function()
    require("beads").setup({})
    assert.equals(bin_dir .. "/beads-ask", vim.fn.exepath("beads-ask"))
  end)

  it("setup twice does not add bin/ to $PATH twice", function()
    require("beads").setup({})
    require("beads").setup({})
    local n = 0
    for _, p in ipairs(vim.split(vim.env.PATH, ":", { plain = true })) do
      if p == bin_dir then
        n = n + 1
      end
    end
    assert.equals(1, n)
  end)
end)

describe("skills/beads-ask/SKILL.md", function()
  local path = plugin_root .. "/skills/beads-ask/SKILL.md"

  local function text()
    assert.equals(1, vim.fn.filereadable(path), "missing " .. path)
    return table.concat(vim.fn.readfile(path), "\n")
  end

  it("has name/description frontmatter", function()
    local s = text()
    assert.is_truthy(s:match("^%-%-%-\n"), "no frontmatter")
    assert.is_truthy(s:find("\nname: beads%-ask\n"), "no 'name: beads-ask'")
    assert.is_truthy(s:find("\ndescription: "), "no description")
  end)

  for _, sub in ipairs({ "list", "show", "reply", "resolve", "propose" }) do
    it("documents 'beads-ask " .. sub .. "'", function()
      assert.is_truthy(text():find("beads-ask " .. sub, 1, true))
    end)
  end

  it("documents the options, proposal fields and stdin body", function()
    local s = text()
    for _, w in ipairs({ "--author", "--needs", "--json", "--field", "title", "description", "design", "acceptance" }) do
      assert.is_truthy(s:find(w, 1, true), "SKILL.md does not mention " .. w)
    end
    assert.is_truthy(s:lower():find("stdin", 1, true), "SKILL.md does not mention stdin")
  end)
end)
