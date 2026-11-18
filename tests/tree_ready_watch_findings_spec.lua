-- Reviewer finding for bead beads_nvim-4u9.3 (lua/beads/views/tree.lua:348): the tree's extra
-- `bd ready` call (for the header's ready count) rewrites the Dolt manifest like any bd read.
-- When it finishes after the watcher's quiet window (lua/beads/watch.lua, 400ms after a store
-- notification), its manifest event must not make the watcher refresh the store again: that
-- refresh notifies the tree, which runs `bd ready` again, in a loop for as long as the tree is open.
--
-- `bd` is a shell script on PATH (test double, same approach as tests/watch_findings_spec.lua):
-- it records every call in $FAKE_DIR/calls; `context` reports the embedded backend; `list` and
-- `ready` rewrite the root's manifest like the real bd; `ready` first sleeps 0.6s (> 400ms).

local cli = require("beads.cli")

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local FAKE_BD = [[#!/bin/sh
r=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-C" ]; then r="$a"; fi
  prev="$a"
done
if [ -z "$r" ]; then r=$(pwd); fi
printf '%s\n' "$*" >> "$FAKE_DIR/calls"
m="$r/.beads/embeddeddolt/db/.dolt/noms/manifest"
rewrite() {
  if [ -f "$m" ]; then
    cp "$m" "$m.tmp" && mv "$m.tmp" "$m"
  fi
}
case " $* " in
  *" context "*)
    printf '{"backend":"dolt","beads_dir":"%s/.beads","database":"db","dolt_mode":"embedded","repo_root":"%s","is_redirected":false,"is_worktree":false,"schema_version":1}\n' "$r" "$r"
    ;;
  *" ready "*)
    sleep 0.6
    rewrite
    cat "$FAKE_DIR/ready.json"
    ;;
  *" list "*)
    rewrite
    cat "$FAKE_DIR/list.json"
    ;;
  *)
    printf '{}\n'
    ;;
esac
]]

local orig_path, orig_notify, orig_columns, bin_dir, fake_dir, root

local function bead(id, title)
  return {
    id = id,
    title = title,
    status = "open",
    priority = 2,
    issue_type = "task",
    updated_at = "2026-11-17T10:00:00Z",
    created_at = "2026-11-17T10:00:00Z",
  }
end

local function write(name, data)
  vim.fn.writefile({ vim.json.encode(data) }, fake_dir .. "/" .. name)
end

local function calls(sub)
  local f = fake_dir .. "/calls"
  if vim.fn.filereadable(f) == 0 then
    return 0
  end
  local n = 0
  for _, line in ipairs(vim.fn.readfile(f)) do
    if (" " .. line .. " "):find(sub, 1, true) then
      n = n + 1
    end
  end
  return n
end

local function sleep(ms)
  vim.wait(ms, function()
    return false
  end, 10)
end

local function open_tree()
  local before = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    before[w] = true
  end
  vim.cmd("Beads tree")
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if not before[w] then
      return w
    end
  end
end

local function first_line(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return ""
  end
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, 1, false)[1] or ""
end

describe("tree header ready count with the fs watcher", function()
  before_each(function()
    if vim.fn.exists(":Beads") ~= 2 then
      vim.cmd.source(plugin_root .. "/plugin/beads.lua")
    end
    require("beads").setup({})
    orig_columns = vim.o.columns
    vim.o.columns = 200
    orig_notify = vim.notify
    vim.notify = function() end
    orig_path = vim.env.PATH
    bin_dir = vim.fn.tempname()
    vim.fn.mkdir(bin_dir, "p")
    vim.fn.writefile(vim.split(FAKE_BD, "\n"), bin_dir .. "/bd")
    vim.fn.setfperm(bin_dir .. "/bd", "rwxr-xr-x")
    fake_dir = vim.fn.tempname()
    vim.fn.mkdir(fake_dir, "p")
    vim.env.FAKE_DIR = fake_dir
    vim.env.PATH = bin_dir .. ":" .. orig_path
    root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/.beads/embeddeddolt/db/.dolt/noms", "p")
    vim.fn.writefile({ "x" }, root .. "/.beads/last-touched")
    vim.fn.writefile({ "manifest-v1" }, root .. "/.beads/embeddeddolt/db/.dolt/noms/manifest")
    cli.set_root(root)
    write("list.json", { bead("tk-a", "Task alpha"), bead("tk-b", "Task bravo") })
    write("ready.json", { bead("tk-a", "Task alpha") })
  end)

  after_each(function()
    -- closing the tree releases the watcher (fs_event handles and timer)
    pcall(vim.cmd, "silent! tabonly!")
    pcall(vim.cmd, "silent! only!")
    pcall(vim.cmd, "enew!")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if b ~= vim.api.nvim_get_current_buf() then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    -- let any bd still running (ready sleeps 0.6s) exit before its files go away
    sleep(900)
    vim.notify = orig_notify
    cli.set_root(nil)
    vim.env.PATH = orig_path
    vim.fn.delete(bin_dir, "rf")
    vim.fn.delete(fake_dir, "rf")
    vim.fn.delete(root, "rf")
    root = nil
    vim.o.columns = orig_columns
    require("beads").setup({})
  end)

  it("a slow bd ready (manifest rewritten after the quiet window) does not start a refresh loop", function()
    local tree = open_tree()
    assert.is_not_nil(tree, ":Beads tree opened no window")
    assert(vim.wait(3000, function()
      return calls(" context ") > 0
    end, 10), "the watcher never ran bd context (tree did not acquire the watcher)")
    assert(vim.wait(4000, function()
      return first_line(tree):find("1 ready", 1, true) ~= nil
    end, 10), "header never showed the ready count; line 1: " .. first_line(tree))
    -- the first bd ready has finished and rewritten the manifest; give the watcher time to react
    sleep(800)
    local list_base, ready_base = calls(" list "), calls(" ready ")
    sleep(3000)
    assert.are.equal(
      list_base,
      calls(" list "),
      "bd list kept running with no external change: the bd ready manifest rewrite triggers watcher refreshes"
    )
    assert.are.equal(ready_base, calls(" ready "), "bd ready kept running with no external change")
    assert.is_true(calls(" list ") <= 2, "more than 2 bd list calls for one tree open: " .. calls(" list "))
    assert.is_truthy(first_line(tree):find("1 ready", 1, true), "header lost the ready count")
  end)
end)
