-- Bead beads_nvim-4u9.9: one 'Beads:' message prefix everywhere; the :Beads subcommand list is
-- defined once (plugin/beads.lua completion uses command.lua's list, which includes 'questions');
-- the dead 'not implemented yet' fallback is gone; README's detail VIEW table lists 'a' (ask).
--
-- Static checks over the plugin sources (lua/ and plugin/). A "message" is the first argument of
-- vim.notify / vim.notify_once / vim.api.nvim_echo; it must be a string literal starting "Beads: ".
-- assumption: prompts (vim.ui.input / vim.ui.select) and error() calls are not messages.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function sources()
  local files = vim.fn.globpath(root .. "/lua", "**/*.lua", false, true)
  vim.list_extend(files, vim.fn.globpath(root .. "/plugin", "**/*.lua", false, true))
  table.sort(files)
  return files
end

local function read(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

local function rel(path)
  return path:sub(#root + 2)
end

local function line_at(text, pos)
  local _, n = text:sub(1, pos):gsub("\n", "")
  return n + 1
end

describe("message prefix", function()
  it("every vim.notify / nvim_echo message is a string literal starting with 'Beads: '", function()
    local bad, seen = {}, 0
    for _, f in ipairs(sources()) do
      local text = read(f)
      for _, pat in ipairs({ "vim%.notify_once%(", "vim%.notify%(", "vim%.api%.nvim_echo%(" }) do
        local init = 1
        while true do
          local s, e = text:find(pat, init)
          if not s then
            break
          end
          init = e + 1
          seen = seen + 1
          local arg = text:sub(e + 1):match("^%s*(.-)\n") or ""
          local after = text:sub(e + 1):gsub("^%s*", "")
          if pat:find("nvim_echo", 1, true) then
            -- nvim_echo({ { "msg", hl } }, ...)
            after = after:gsub("^{%s*{%s*", "")
          end
          if not (after:match('^"Beads: ') or after:match("^'Beads: ")) then
            bad[#bad + 1] = ("%s:%d: %s"):format(rel(f), line_at(text, s), vim.trim(arg ~= "" and arg or after:sub(1, 60)))
          end
        end
      end
    end
    assert.is_true(seen > 0, "no vim.notify calls found; is the scan pointed at the right place?")
    assert.are.same({}, bad, "messages without the 'Beads: ' prefix:\n" .. table.concat(bad, "\n"))
  end)

  it("no lowercase 'beads:' prefix appears in a string (keymap descs may say 'Beads <group>:')", function()
    local bad = {}
    for _, f in ipairs(sources()) do
      for i, l in ipairs(vim.fn.readfile(f)) do
        for str in l:gmatch('"([^"]*)"') do
          if str:match("^beads: ") then
            bad[#bad + 1] = ("%s:%d: %s"):format(rel(f), i, str)
          end
        end
      end
    end
    assert.are.same({}, bad, "other message prefixes:\n" .. table.concat(bad, "\n"))
  end)

  it("the dead 'not implemented yet' fallback is gone", function()
    local bad = {}
    for _, f in ipairs(sources()) do
      if read(f):find("not implemented", 1, true) then
        bad[#bad + 1] = rel(f)
      end
    end
    assert.are.same({}, bad)
  end)
end)

describe(":Beads subcommand list", function()
  before_each(function()
    if vim.fn.exists(":Beads") ~= 2 then
      vim.g.loaded_beads = nil
      vim.cmd.source(root .. "/plugin/beads.lua")
    end
  end)

  it("completion offers exactly command.subcommands (including questions)", function()
    local subs = require("beads.command").subcommands
    assert.is_true(vim.tbl_contains(subs, "questions"))
    local items = vim.fn.getcompletion("Beads ", "cmdline")
    table.sort(items)
    local want = vim.deepcopy(subs)
    table.sort(want)
    assert.are.same(want, items)
    assert.are.same({ "questions" }, vim.fn.getcompletion("Beads qu", "cmdline"))
  end)

  it("the list is written out in one file only", function()
    local holders = {}
    for _, f in ipairs(sources()) do
      local text = read(f)
      -- a table literal naming several subcommands in a row
      if text:find('"tree",%s*"ready",%s*"list"') or text:find('"cd",%s*"poke",%s*"output"') then
        holders[#holders + 1] = rel(f)
      end
    end
    assert.are.equal(1, #holders, "subcommand list defined in: " .. table.concat(holders, ", "))
  end)
end)

describe("README detail VIEW table", function()
  it("has a row for a (ask)", function()
    local lines = vim.fn.readfile(root .. "/README.md")
    local start
    for i, l in ipairs(lines) do
      if l:find("keymaps.detail.view", 1, true) and l:match("^|") then
        start = i
        break
      end
    end
    assert.is_not_nil(start, "detail VIEW key table (header naming keymaps.detail.view) not found")
    local found = false
    for i = start + 1, #lines do
      local l = lines[i]
      if not l:match("^|") then
        break
      end
      if l:find("`a`", 1, true) and l:find("`ask`", 1, true) then
        found = true
      end
    end
    assert.is_true(found, "README detail VIEW table has no `a` / `ask` row")
  end)
end)
