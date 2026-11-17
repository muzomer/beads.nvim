-- Interface under test (bead beads_nvim-ge7.1):
--   :Beads with no args, or with an unknown subcommand, reports usage through
--   vim.notify (message contains "usage", any case).
--   :Beads <Tab> completes the subcommands:
--     tree, ready, list, search, needs, epics, show, create, cd

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local SUBCOMMANDS = { "tree", "ready", "list", "search", "needs", "epics", "show", "create", "cd" }

local function capture_notify(fn)
  local messages = {}
  local orig = vim.notify
  vim.notify = function(msg, level, opts)
    table.insert(messages, tostring(msg))
  end
  local ok, err = pcall(fn)
  vim.notify = orig
  assert(ok, err)
  return table.concat(messages, "\n")
end

describe(":Beads", function()
  before_each(function()
    if vim.fn.exists(":Beads") ~= 2 then
      vim.cmd.source(root .. "/plugin/beads.lua")
    end
  end)

  it("shows usage when called with no arguments", function()
    local out = capture_notify(function()
      vim.cmd("Beads")
    end)
    assert.is_truthy(out:lower():find("usage", 1, true), "expected usage message, got: " .. out)
  end)

  it("shows usage for an unknown subcommand", function()
    local out = capture_notify(function()
      vim.cmd("Beads definitely-not-a-subcommand")
    end)
    assert.is_truthy(out:lower():find("usage", 1, true), "expected usage message, got: " .. out)
  end)

  it("completes all subcommands", function()
    local completions = vim.fn.getcompletion("Beads ", "cmdline")
    for _, sub in ipairs(SUBCOMMANDS) do
      assert.is_true(vim.tbl_contains(completions, sub), "missing completion: " .. sub)
    end
  end)
end)
