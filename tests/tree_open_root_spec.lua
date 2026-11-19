-- Bead beads_nvim-4u9.9: beads opened from the tree load and write with the tree's root, even
-- after ':Beads cd' pointed the cli somewhere else.
--
-- `bd` is replaced by a shell script on PATH (test double for the external binary). It logs every
-- argv to $FAKE_DIR/calls.log and answers from files under the -C root, so a call made with the
-- wrong root gets different data:
--   list        -> <root>/.fake/list.json (else [])
--   show <id>   -> <root>/.fake/show-<id>.json (else [])
--   create      -> {"id":"ta-9"}
--   context     -> a non-embedded backend (the watcher falls back to focus refresh)
--   other       -> {}
-- Root A holds bead ta-1 "Alpha from A" (and ta-9 after the create); root B holds nothing.

local cli = require("beads.cli")
local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local FAKE_BD = [[#!/bin/sh
r=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-C" ]; then r="$a"; fi
  prev="$a"
done
printf '%s\n' "$*" >> "$FAKE_DIR/calls.log"
prev=""
for a in "$@"; do
  case "$a" in
    context)
      printf '{"backend":"dolt","beads_dir":"%s/.beads","database":"db","dolt_mode":"server","repo_root":"%s","is_redirected":false,"is_worktree":false,"schema_version":1}\n' "$r" "$r"
      exit 0 ;;
    list)
      if [ -f "$r/.fake/list.json" ]; then cat "$r/.fake/list.json"; else echo '[]'; fi
      exit 0 ;;
    ready) echo '[]'; exit 0 ;;
    create) echo '{"id":"ta-9"}'; exit 0 ;;
  esac
  if [ "$prev" = "show" ]; then
    if [ -f "$r/.fake/show-$a.json" ]; then cat "$r/.fake/show-$a.json"; else echo '[]'; fi
    exit 0
  fi
  prev="$a"
done
echo '{}'
]]

local orig_path, orig_cwd, orig_notify, bin_dir, fake_dir
local A, B

local function bead(id, title, extra)
  local b = {
    id = id,
    title = title,
    description = "desc " .. id,
    status = "open",
    priority = 2,
    issue_type = "task",
    created_at = "2026-11-17T10:00:00Z",
    updated_at = "2026-11-17T10:00:00Z",
  }
  for k, v in pairs(extra or {}) do
    b[k] = v
  end
  return b
end

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return vim.fn.resolve(d)
end

local function norm(p)
  return (tostring(p or ""):gsub("/+$", ""))
end

-- Logged calls whose subcommand is `sub`, as { root = <-C arg>, line = <argv> }.
local function calls(sub)
  local out = {}
  local log = fake_dir .. "/calls.log"
  if vim.fn.filereadable(log) == 0 then
    return out
  end
  for _, line in ipairs(vim.fn.readfile(log)) do
    local words = vim.split(line, " ", { plain = true })
    local r, has = nil, false
    for i, w in ipairs(words) do
      if words[i - 1] == "-C" then
        r = w
      end
      if w == sub then
        has = true
      end
    end
    if has then
      out[#out + 1] = { root = norm(r), line = line }
    end
  end
  return out
end

local function roots_of(list)
  local t = {}
  for _, c in ipairs(list) do
    t[#t + 1] = c.root
  end
  return table.concat(t, ", ")
end

local function wait_for(pred, what, ms)
  assert(vim.wait(ms or 5000, pred, 10), "timed out waiting for " .. what)
end

local function settle(ms)
  vim.wait(ms or 200, function()
    return false
  end, 10)
end

local function tree_win()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "beads-tree" then
      return w
    end
  end
end

local function line_of(buf, text)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:find(text, 1, true) then
      return i
    end
  end
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false)
end

-- Opens the tree at A, waits for ta-1, then ':Beads cd B'. Leaves the cursor on ta-1 in the tree.
local function tree_at_A_then_cd_B()
  vim.cmd("Beads cd " .. vim.fn.fnameescape(A))
  vim.cmd("Beads tree")
  local win
  wait_for(function()
    win = tree_win()
    return win ~= nil and line_of(vim.api.nvim_win_get_buf(win), "ta-1") ~= nil
  end, "tree to list ta-1")
  vim.cmd("Beads cd " .. vim.fn.fnameescape(B))
  assert.are.equal(norm(B), norm(cli.get_root()), ":Beads cd did not change the cli root")
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { line_of(vim.api.nvim_win_get_buf(win), "ta-1"), 0 })
  return win
end

describe("beads opened from the tree use the tree's root", function()
  before_each(function()
    orig_path = vim.env.PATH
    orig_cwd = vim.fn.getcwd()
    orig_notify = vim.notify
    vim.notify = function() end
    bin_dir = tmpdir()
    fake_dir = tmpdir()
    vim.fn.writefile(vim.split(FAKE_BD, "\n"), bin_dir .. "/bd")
    vim.fn.setfperm(bin_dir .. "/bd", "rwxr-xr-x")
    vim.env.FAKE_DIR = fake_dir
    vim.env.PATH = bin_dir .. ":" .. orig_path
    A, B = tmpdir(), tmpdir()
    vim.fn.mkdir(A .. "/.fake", "p")
    vim.fn.mkdir(B .. "/.fake", "p")
    vim.fn.writefile({ vim.json.encode({ bead("ta-1", "Alpha from A") }) }, A .. "/.fake/list.json")
    vim.fn.writefile({ vim.json.encode({ bead("ta-1", "Alpha from A") }) }, A .. "/.fake/show-ta-1.json")
    vim.fn.writefile(
      { vim.json.encode({ bead("ta-9", "Child from A", { parent = "ta-1" }) }) },
      A .. "/.fake/show-ta-9.json"
    )
    cli.set_root(nil)
    require("beads").setup({ tree = { layout = "split" } })
    if vim.fn.exists("#BeadsDetail#BufReadCmd") == 0 then
      vim.cmd.source(repo .. "/plugin/beads.lua")
    end
  end)

  after_each(function()
    if tree_win() then
      pcall(require("beads.views.tree").toggle)
    end
    pcall(vim.cmd, "silent! only!")
    pcall(vim.cmd, "silent! %bwipeout!")
    settle(200)
    vim.notify = orig_notify
    vim.env.PATH = orig_path
    vim.cmd.cd(vim.fn.fnameescape(orig_cwd))
    cli.set_root(nil)
    vim.fn.delete(bin_dir, "rf")
    vim.fn.delete(fake_dir, "rf")
  end)

  it("<CR> after ':Beads cd' elsewhere loads the bead from the tree's root", function()
    local twin = tree_at_A_then_cd_B()
    local shows_before = #calls("show")
    press("<CR>")
    local buf
    wait_for(function()
      buf = vim.api.nvim_get_current_buf()
      return vim.api.nvim_buf_get_name(buf):find("beads://ta-1", 1, true) ~= nil
    end, "beads://ta-1 to open")
    assert.are_not.equal(twin, vim.api.nvim_get_current_win(), "bead opened in the tree window")
    wait_for(function()
      return #calls("show") > shows_before
    end, "bd show")
    settle(300)
    local shows = vim.list_slice(calls("show"), shows_before + 1)
    for _, c in ipairs(shows) do
      assert.are.equal(norm(A), c.root, "bd show ran with the wrong root (" .. roots_of(shows) .. "); tree root is " .. A)
    end
    wait_for(function()
      return line_of(buf, "Alpha from A") ~= nil
    end, "the bead from root A to render")
    assert.are.equal(norm(A), norm(require("beads.views.detail").root(buf)))
  end)

  it(":w on a bead opened from the tree writes to the tree's root", function()
    tree_at_A_then_cd_B()
    press("<CR>")
    local buf
    wait_for(function()
      buf = vim.api.nvim_get_current_buf()
      return vim.api.nvim_buf_get_name(buf):find("beads://ta-1", 1, true) ~= nil
        and line_of(buf, "Alpha from A") ~= nil
    end, "beads://ta-1 to load from root A")
    local detail = require("beads.views.detail")
    detail.enter_edit(buf)
    local n = line_of(buf, "Alpha from A")
    local l = vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1]
    vim.api.nvim_buf_set_lines(buf, n - 1, n, false, { (l:gsub("Alpha from A", "Alpha edited")) })
    vim.cmd("write")
    wait_for(function()
      return #calls("update") > 0
    end, "bd update after :w")
    local ups = calls("update")
    for _, c in ipairs(ups) do
      assert.are.equal(norm(A), c.root, "bd update ran with the wrong root (" .. roots_of(ups) .. "); tree root is " .. A)
    end
  end)

  it("a (add child) after ':Beads cd' elsewhere creates the child in the tree's root", function()
    tree_at_A_then_cd_B()
    press("a")
    local buf
    wait_for(function()
      buf = vim.api.nvim_get_current_buf()
      return vim.api.nvim_buf_get_name(buf):find("beads://new", 1, true) ~= nil
    end, "beads://new to open")
    local detail = require("beads.views.detail")
    assert.are.equal(norm(A), norm(detail.root(buf)), "beads://new opened from the tree is not bound to the tree's root")
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local set = false
    for i, l in ipairs(lines) do
      if l:match("^# ") or l == "#" then
        lines[i] = "# Child from A"
        set = true
        break
      end
    end
    assert.is_true(set, "no '# ' title line in the create template")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.cmd("write")
    wait_for(function()
      return #calls("create") > 0
    end, "bd create after :w")
    local cr = calls("create")
    assert.are.equal(1, #cr)
    assert.are.equal(norm(A), cr[1].root, "bd create ran with the wrong root (" .. cr[1].root .. "); tree root is " .. A)
  end)
end)
