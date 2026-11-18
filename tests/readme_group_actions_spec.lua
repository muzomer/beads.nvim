-- Bead beads_nvim-qvs.1: README documents every A-menu action and the fzf picker multi-select.
--
-- assumption: the A-menu actions are documented in the "### Tree" section, after the first `A`
--   code span (prose such as "add / remove label" or a list is fine; checks are case-insensitive).
-- assumption: picker multi-select is documented in the "### fzf-lua picker" section with the keys
--   as code spans: `<Tab>`, `ctrl-x`, `ctrl-a`.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

-- Text of the README section whose heading line starts with `heading`, up to the next ### or ##.
local function section(heading)
  local lines = vim.fn.readfile(root .. "/README.md")
  local out, inside = {}, false
  for _, l in ipairs(lines) do
    if inside and l:match("^##") then
      break
    end
    if vim.startswith(l, heading) then
      inside = true
    elseif inside then
      out[#out + 1] = l
    end
  end
  assert(inside, "README.md has no section " .. heading)
  return table.concat(out, "\n")
end

-- true when `a` is followed by `b` within at most `gap` characters of words, blanks and slashes.
local function near(text, a, b, gap)
  local init = 1
  while true do
    local s, e = text:find(a, init, true)
    if not s then
      return false
    end
    local rest = text:sub(e + 1, e + gap + #b)
    local m = rest:match("^[%w%s/,]-" .. vim.pesc(b))
    if m then
      return true
    end
    init = e + 1
  end
end

describe("README.md", function()
  it("documents every action of the tree's A menu", function()
    local tree = section("### Tree")
    local at = tree:find("`A`", 1, true)
    assert(at, "Tree section does not mention `A`")
    local text = tree:sub(at):lower()
    local checks = {
      { "close", function() return text:find("close", 1, true) end },
      { "claim", function() return text:find("claim", 1, true) end },
      { "reopen", function() return text:find("reopen", 1, true) end },
      { "yank", function() return text:find("yank", 1, true) end },
      { "set priority", function() return text:find("priority", 1, true) end },
      { "set status", function() return text:find("status", 1, true) end },
      { "set assignee", function() return text:find("assignee", 1, true) end },
      { "set type", function() return text:find("type", 1, true) end },
      { "add label", function() return near(text, "add", "label", 20) end },
      { "remove label", function() return near(text, "remove", "label", 20) end },
      { "move under epic", function() return text:find("epic", 1, true) end },
      { "remove parent", function() return near(text, "remove", "parent", 20) end },
      { "blocked by", function() return text:find("blocked by", 1, true) end },
      { "remove dependency", function() return near(text, "remove", "dependenc", 20) end },
    }
    local missing = {}
    for _, c in ipairs(checks) do
      if not c[2]() then
        missing[#missing + 1] = c[1]
      end
    end
    assert.are.same({}, missing, "Tree section (from `A`) does not document: " .. table.concat(missing, ", "))
  end)

  it("documents fzf picker multi-select with <Tab>, ctrl-x and ctrl-a", function()
    local text = section("### fzf-lua picker")
    local missing = {}
    for _, k in ipairs({ "<Tab>", "ctrl-x", "ctrl-a" }) do
      if not text:find("`" .. k .. "`", 1, true) then
        missing[#missing + 1] = k
      end
    end
    assert.are.same({}, missing, "fzf-lua picker section does not list: " .. table.concat(missing, ", "))
  end)
end)
