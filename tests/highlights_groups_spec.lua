-- Bead beads_nvim-4u9.1: highlight groups.
-- Interface under test:
--   require("beads").setup() defines every Beads* group of the epic design
--   (beads_nvim-4u9) with `default = true` (usually a link to a standard group),
--   and re-applies them on ColorScheme.
-- Observable proof of re-application: `:colorscheme` runs `:hi clear`, which
-- drops the `default` flag of surviving links and removes attribute groups;
-- re-applying with `default = true` brings the flag / group back.

local function fresh_beads()
  for name in pairs(package.loaded) do
    if name == "beads" or name:match("^beads%.") then
      package.loaded[name] = nil
    end
  end
  return require("beads")
end

local GROUPS = {
  "BeadsId",
  "BeadsTitle",
  "BeadsDim",
  "BeadsStatusOpen",
  "BeadsStatusInProgress",
  "BeadsStatusBlocked",
  "BeadsStatusClosed",
  "BeadsStatusDeferred",
  "BeadsPriority0",
  "BeadsPriority1",
  "BeadsPriority2",
  "BeadsPriority3",
  "BeadsPriority4",
  "BeadsTypeEpic",
  "BeadsTypeBug",
  "BeadsTypeFeature",
  "BeadsTypeTask",
  "BeadsTypeChore",
  "BeadsBadgeUser",
  "BeadsBadgeAgent",
  "BeadsBlocked",
  "BeadsCurrent",
  "BeadsFlash",
  "BeadsFold",
  "BeadsGuide",
  "BeadsHeader",
  "BeadsModeView",
  "BeadsModeEdit",
}

local function hl(name)
  return vim.api.nvim_get_hl(0, { name = name })
end

local function all_hl_names()
  local names = {}
  for name in pairs(vim.api.nvim_get_hl(0, {})) do
    names[#names + 1] = name
  end
  return names
end

-- Follow links until a group that is not Beads*; return its name (or nil on a cycle/dead end).
local function resolve(name)
  local seen = {}
  while name and name:match("^Beads") do
    if seen[name] then
      return nil
    end
    seen[name] = true
    local h = hl(name)
    if not h.link then
      return name -- a Beads group with its own attributes
    end
    name = h.link
  end
  return name
end

describe("highlights: groups after setup", function()
  before_each(function()
    fresh_beads().setup()
  end)

  for _, name in ipairs(GROUPS) do
    it(name .. " exists as a default (overridable) group", function()
      local h = hl(name)
      assert.is_true(next(h) ~= nil, name .. " is not defined")
      assert.is_true(h.default == true, name .. " is not defined with default = true: " .. vim.inspect(h))
      if h.link then
        local target = resolve(name)
        assert.is_not_nil(target, name .. " link chain does not resolve")
        if not target:match("^Beads") then
          assert.is_true(next(hl(target)) ~= nil, name .. " links to undefined group " .. target)
        end
      end
    end)
  end

  it("defines at least one BeadsWinbar* group", function()
    local found = false
    for _, name in ipairs(all_hl_names()) do
      if name:match("^BeadsWinbar") then
        found = true
        assert.is_true(hl(name).default == true, name .. " is not defined with default = true")
      end
    end
    assert.is_true(found, "no BeadsWinbar* highlight group defined")
  end)
end)

describe("highlights: user and colourscheme overrides", function()
  it("keeps a user definition made before setup", function()
    vim.cmd("highlight BeadsId guifg=#123456")
    fresh_beads().setup()
    local h = hl("BeadsId")
    assert.are.equal(0x123456, h.fg)
    assert.is_nil(h.link)
  end)

  it("lets a user :hi override a group after setup", function()
    fresh_beads().setup()
    vim.cmd("highlight! link BeadsTitle ErrorMsg")
    assert.are.equal("ErrorMsg", hl("BeadsTitle").link)
  end)
end)

describe("highlights: ColorScheme", function()
  it("re-applies every group after :colorscheme", function()
    fresh_beads().setup()
    vim.cmd("colorscheme default")
    for _, name in ipairs(GROUPS) do
      local h = hl(name)
      assert.is_true(next(h) ~= nil, name .. " lost after :colorscheme")
      assert.is_true(h.default == true, name .. " not re-applied (default flag missing) after :colorscheme")
    end
  end)

  it("re-applies after a colourscheme that runs :hi clear and fires ColorScheme", function()
    fresh_beads().setup()
    vim.cmd("highlight clear")
    vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "fake" })
    for _, name in ipairs(GROUPS) do
      assert.is_true(hl(name).default == true, name .. " not re-applied on ColorScheme")
    end
  end)
end)
