-- Bead beads_nvim-4u9.9: a detail buffer acquires the watcher itself. With only a detail buffer
-- open (no tree), a `bd update` from a shell refreshes it when unmodified, or shows the
-- "changed externally" warning when modified. Wiping the buffer releases the watcher.
-- Integration test: real bd, embedded backend (as tests/watch_integration_spec.lua).

local helpers = require("tests.helpers")
local cli = require("beads.cli")
local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function sleep(ms)
  vim.wait(ms, function()
    return false
  end, 10)
end

local function live_fs_events()
  local n = 0
  vim.uv.walk(function(h)
    if h:get_type() == "fs_event" and not h:is_closing() then
      n = n + 1
    end
  end)
  return n
end

local function has_line(buf, text)
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:find(text, 1, true) then
      return true
    end
  end
  return false
end

local function warned(buf, win)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    for _, vl in ipairs((m[4] or {}).virt_lines or {}) do
      for _, chunk in ipairs(vl) do
        if tostring(chunk[1]):find("changed externally", 1, true) then
          return true
        end
      end
    end
  end
  local ok, bar = pcall(require("beads.views.detail").winbar, win)
  return ok and type(bar) == "string" and bar:find("changed on disk", 1, true) ~= nil
end

local function tree_open()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "beads-tree" then
      return true
    end
  end
  return false
end

-- Opens beads://<id> (no tree) in dir and waits until it is loaded and the watcher is running.
local function open_detail(dir, id, before)
  cli.set_root(dir)
  vim.cmd.edit(vim.fn.fnameescape("beads://" .. id))
  local buf = vim.api.nvim_get_current_buf()
  assert(vim.wait(10000, function()
    return require("beads.views.detail").snapshot(buf) ~= nil and has_line(buf, "watched title")
  end, 20), "detail buffer never loaded")
  assert.is_false(tree_open(), "a tree is open; this test needs a detail buffer alone")
  -- give the watcher (if any) time to start; the tests assert on behaviour, not on handles
  vim.wait(5000, function()
    return live_fs_events() > before
  end, 20)
  sleep(1500)
  return buf
end

local function bd(dir, args)
  local argv = { "bd", "-C", dir }
  vim.list_extend(argv, args)
  local r = vim.system(argv, { text = true }):wait()
  assert.are.equal(0, r.code, "bd " .. table.concat(args, " ") .. " failed: " .. tostring(r.stderr))
  return r
end

describe("detail buffer live updates without a tree (modified)", function()
  if not helpers.has_bd() then
    pending("bd executable not found")
    return
  end

  local orig_notify

  before_each(function()
    orig_notify = vim.notify
    vim.notify = function() end
    cli.set_root(nil)
    if vim.fn.exists("#BeadsDetail#BufReadCmd") == 0 then
      vim.cmd.source(repo .. "/plugin/beads.lua")
    end
  end)

  after_each(function()
    pcall(vim.cmd, "silent! %bwipeout!")
    sleep(300)
    vim.notify = orig_notify
    cli.set_root(nil)
  end)

  it("a modified detail buffer keeps the edits and shows the changed-externally warning", function()
    helpers.with_bd_repo(function(dir)
      local id = vim.json.decode(bd(dir, { "create", "watched title", "--json" }).stdout).id
      local before = live_fs_events()
      local ok, err = pcall(function()
        local buf = open_detail(dir, id, before)
        local win = vim.api.nvim_get_current_win()
        require("beads.views.detail").enter_edit(buf)
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local n
        for i, l in ipairs(lines) do
          if l:find("watched title", 1, true) then
            n = i
            break
          end
        end
        assert.is_not_nil(n, "title line not found")
        vim.api.nvim_buf_set_lines(buf, n - 1, n, false, { (lines[n]:gsub("watched title", "my local edit")) })
        assert.is_true(vim.bo[buf].modified)
        bd(dir, { "update", id, "--priority", "1" })
        assert(vim.wait(6000, function()
          return warned(buf, win)
        end, 20), "no changed-externally warning after an external bd update")
        assert.is_true(has_line(buf, "my local edit"), "local edits were lost")
        assert.is_true(vim.bo[buf].modified)
      end)
      pcall(vim.cmd, "silent! %bwipeout!")
      sleep(300)
      if not ok then
        error(err, 0)
      end
    end)
  end)
end)
