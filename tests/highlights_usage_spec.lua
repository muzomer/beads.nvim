-- Bead beads_nvim-4u9.1: no plugin code uses a highlight group outside the
-- Beads* set (defined by setup) or Neovim's standard groups, and ad-hoc
-- highlight definitions (e.g. BeadsReadonly in views/detail.lua) are gone:
-- only lua/beads/highlights.lua defines highlight groups.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function fresh_beads()
  for name in pairs(package.loaded) do
    if name == "beads" or name:match("^beads%.") then
      package.loaded[name] = nil
    end
  end
  return require("beads")
end

local function plugin_files()
  local files = vim.fn.globpath(root, "lua/beads/**/*.lua", false, true)
  vim.list_extend(files, vim.fn.globpath(root, "plugin/**/*.lua", false, true))
  return files
end

local function rel(path)
  return path:sub(#root + 2)
end

-- Group names in positions that really take a highlight group:
--   hl_group = "X" / line_hl_group = "X" / hl = "X"
--   the last string of a chunk tuple: { "text", "X" }
--   statusline / winbar items: %#X#
--   winhighlight right-hand sides: "Normal:X,..."
--   the group argument of nvim_buf_add_highlight(buf, ns, "X", ...) and
--   vim.hl.range / vim.highlight.range(buf, ns, "X", ...)
local function group_names(line)
  local out = {}
  local function add(name)
    if name and name:match("^%u[%w_]*$") then
      out[#out + 1] = name
    end
  end
  for name in line:gmatch("hl_group%s*=%s*[\"']([%w_]+)[\"']") do
    add(name)
  end
  for name in line:gmatch("[%s{,]hl%s*=%s*[\"']([%w_]+)[\"']") do
    add(name)
  end
  -- Chunk tuples: a Beads* name anywhere; other names only on virt_text /
  -- virt_lines / echo lines (plain string lists like { "Apply", "Cancel" } are not chunks).
  local chunk_line = line:find("virt_text") or line:find("virt_lines") or line:find("echo")
  for name in line:gmatch(",%s*[\"'](%u[%w_]*)[\"']%s*}") do
    if chunk_line or name:match("^Beads") then
      add(name)
    end
  end
  for name in line:gmatch("%%#([%w_]+)#") do
    add(name)
  end
  if line:find("winhighlight") or line:find("winhl") then
    for s in line:gmatch("[\"']([^\"']*)[\"']") do
      for _, rhs in s:gmatch("(%u[%w_]*):(%u[%w_]*)") do
        add(rhs)
      end
    end
  end
  for name in line:gmatch("add_highlight%s*%([^,]+,[^,]+,%s*[\"']([%w_]+)[\"']") do
    add(name)
  end
  for name in line:gmatch("%.range%s*%([^,]+,[^,]+,%s*[\"']([%w_]+)[\"']") do
    add(name)
  end
  return out
end

-- Ex commands that define highlights, inside vim.cmd / nvim_command / nvim_exec.
local function defines_hl(code)
  if code:find("nvim_set_hl") then
    return true
  end
  if not (code:find("vim%.cmd") or code:find("nvim_command") or code:find("nvim_exec")) then
    return false
  end
  return code:find("[\"'%[]hi!?%s") or code:find("[\"'%[]highlight!?%s") or code:find("vim%.cmd%.hi")
    or code:find("vim%.cmd%.highlight")
end

describe("highlights: usage in plugin code", function()
  it("only lua/beads/highlights.lua defines highlight groups", function()
    local bad = {}
    for _, f in ipairs(plugin_files()) do
      if not f:match("lua/beads/highlights%.lua$") then
        for i, line in ipairs(vim.fn.readfile(f)) do
          local code = line:gsub("%-%-.*$", "")
          if defines_hl(code) then
            bad[#bad + 1] = rel(f) .. ":" .. i .. ": " .. vim.trim(line)
          end
        end
      end
    end
    assert.are.same({}, bad)
  end)

  it("uses only defined Beads* groups or standard Neovim groups", function()
    vim.cmd("colorscheme default")
    fresh_beads().setup()
    local bad = {}
    for _, f in ipairs(plugin_files()) do
      for i, line in ipairs(vim.fn.readfile(f)) do
        local code = line:gsub("%-%-.*$", "")
        for _, name in ipairs(group_names(code)) do
          local h = vim.api.nvim_get_hl(0, { name = name })
          if next(h) == nil then
            bad[#bad + 1] = rel(f) .. ":" .. i .. ": " .. name
          end
        end
      end
    end
    assert.are.same({}, bad)
  end)

  it("does not use the ad-hoc BeadsReadonly group", function()
    local bad = {}
    for _, f in ipairs(plugin_files()) do
      for i, line in ipairs(vim.fn.readfile(f)) do
        if line:find("BeadsReadonly", 1, true) then
          bad[#bad + 1] = rel(f) .. ":" .. i
        end
      end
    end
    assert.are.same({}, bad)
  end)
end)
