-- Bead beads_nvim-4u9.5: tree.position config in a fresh session (plenary runs each spec file in
-- its own nvim, so no position is remembered yet). With setup({ tree = { position = "right" } })
-- a plain :Beads tree opens the tree on the right at the default width ("auto" since beads_nvim-4u9.13).
-- `bd` is replaced by a shell script on PATH (test double) that prints one bead for any call.

local cli = require("beads.cli")

local function auto_width(t)
  -- beads_nvim-4u9.13: default width "auto" = longest visible line clamped 24..floor(columns / 2).
  local m = 0
  vim.api.nvim_win_call(t, function()
    local l, last = 1, vim.fn.line("$")
    while l <= last do
      m = math.max(m, vim.fn.strdisplaywidth(vim.fn.getline(l)))
      local e = vim.fn.foldclosedend(l)
      l = (e > 0 and e or l) + 1
    end
  end)
  return math.max(24, math.min(math.floor(vim.o.columns / 2), m))
end

local function wait_auto_width(t)
  vim.wait(1000, function()
    return vim.api.nvim_win_get_width(t) == auto_width(t)
  end, 10)
  return auto_width(t)
end

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

describe("tree.position config", function()
  local orig_path, bin_dir, root, orig_columns, orig_lines

  before_each(function()
    if vim.fn.exists(":Beads") ~= 2 then
      vim.cmd.source(plugin_root .. "/plugin/beads.lua")
    end
    orig_columns, orig_lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 120, 40
    orig_path = vim.env.PATH
    bin_dir = vim.fn.tempname()
    vim.fn.mkdir(bin_dir, "p")
    local json = vim.json.encode({
      {
        id = "bl-d",
        title = "Leaf delta",
        status = "open",
        priority = 2,
        issue_type = "task",
        updated_at = "2026-11-17T10:00:00Z",
        created_at = "2026-11-17T10:00:00Z",
      },
    })
    vim.fn.writefile({ "#!/bin/sh", "cat <<'EOF'", json, "EOF" }, bin_dir .. "/bd")
    vim.fn.setfperm(bin_dir .. "/bd", "rwxr-xr-x")
    vim.env.PATH = bin_dir .. ":" .. orig_path
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    cli.set_root(root)
  end)

  after_each(function()
    pcall(vim.cmd, "silent! tabonly!")
    pcall(vim.cmd, "silent! only!")
    pcall(vim.cmd, "enew!")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if b ~= vim.api.nvim_get_current_buf() then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    vim.wait(100, function()
      return false
    end, 10)
    cli.set_root(nil)
    vim.fn.delete(root, "rf")
    vim.env.PATH = orig_path
    vim.fn.delete(bin_dir, "rf")
    vim.o.columns, vim.o.lines = orig_columns, orig_lines
    require("beads").setup({})
  end)

  it("a plain :Beads tree opens at the configured position", function()
    require("beads").setup({ tree = { position = "right" } })
    local main = vim.api.nvim_get_current_win()
    vim.cmd("Beads tree")
    local tree
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "beads-tree" then
        tree = w
      end
    end
    assert.is_not_nil(tree, ":Beads tree opened no tree window")
    local p = vim.api.nvim_win_get_position(tree)
    local expected = wait_auto_width(tree)
    local width = vim.api.nvim_win_get_width(tree)
    assert.are.equal(vim.o.columns, p[2] + width, "tree is not at the right edge")
    assert.are.equal(0, vim.api.nvim_win_get_position(main)[2], "editor window is not left of the tree")
    assert.are.equal(expected, width)
  end)
end)
