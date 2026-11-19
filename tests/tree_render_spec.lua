-- Bead beads_nvim-4u9.3: tree rendering (lua/beads/views/tree.lua via :Beads tree).
--   * Guides │ ├ └ by parent-child depth, fold marker ▾ on beads with visible children
--     (leaves get a blank of the same width), epic progress [closed/total] of direct children,
--     closed beads dimmed (BeadsDim), a header line and empty states.
-- assumption: tree line = <guides><marker slot><formatter text>[ [c/t]] where
--   guides: depth 0 none; each deeper level adds one 2-column cell per ancestor level
--   ("│ " if that ancestor still has later visible siblings, else "  "), then "├ " (more visible
--   siblings follow) or "└ " (last visible sibling); marker slot: "▾ " when the bead has visible
--   children, "  " otherwise; " [c/t]" is appended at the end of epic lines only.
-- assumption: [c/t] counts all direct children (closed included) whether or not H shows them.
-- assumption: the header is buffer line 1: "beads · <root dir name> · N open · M ready · K need you"
--   (N = status open, M = ready beads, K = beads needing the user), trailing text allowed.
-- assumption: empty states are literal lines "No beads here — <create lhs> to create" (the
--   configured keymaps.create lhs, default <leader>bc) and "Not a beads repo — run bd init".
-- `bd` is a shell script on PATH (test double): logs argv; if $FAKE_DIR/fail exists prints it to
-- stderr and exits 1; `ready` prints $FAKE_DIR/ready.json; anything else prints $FAKE_DIR/list.json.

local cli = require("beads.cli")
local store = require("beads.store")

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local FAKE_BD = [[#!/bin/sh
echo "$*" >> "$FAKE_DIR/args.log"
if [ -f "$FAKE_DIR/fail" ]; then
  cat "$FAKE_DIR/fail" >&2
  exit 1
fi
for a in "$@"; do
  if [ "$a" = "ready" ]; then
    cat "$FAKE_DIR/ready.json"
    exit 0
  fi
done
cat "$FAKE_DIR/list.json"
]]

local orig_path, orig_notify, orig_columns, bin_dir, fake_dir, root
local errors

local function bead(id, title, extra)
  local b = {
    id = id,
    title = title,
    status = "open",
    priority = 2,
    issue_type = "task",
    updated_at = "2026-11-17T10:00:00Z",
    created_at = "2026-11-17T10:00:00Z",
  }
  for k, v in pairs(extra or {}) do
    b[k] = v
  end
  return b
end

local function child_of(id, parent, title, extra)
  local e = vim.tbl_extend("force", {}, extra or {})
  e.parent = parent
  e.dependencies = { { issue_id = id, depends_on_id = parent, type = "parent-child" } }
  return bead(id, title, e)
end

local function blocks(b, blocker)
  b.dependencies = b.dependencies or {}
  table.insert(b.dependencies, { issue_id = b.id, depends_on_id = blocker, type = "blocks" })
  return b
end

local function write(name, data)
  vim.fn.writefile({ vim.json.encode(data) }, fake_dir .. "/" .. name)
end

local function set_list(items)
  write("list.json", items)
end

local function set_ready(items)
  write("ready.json", items)
end

local function wins()
  return vim.api.nvim_tabpage_list_wins(0)
end

local function open_tree()
  local before = {}
  for _, w in ipairs(wins()) do
    before[w] = true
  end
  vim.cmd("Beads tree")
  for _, w in ipairs(wins()) do
    if not before[w] then
      return w
    end
  end
end

local function lines_of(win)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

local function rtrim(s)
  return (s:gsub("%s+$", ""))
end

local function dump(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return "<no tree window>"
  end
  return table.concat(lines_of(win), "\n")
end

local function has_line(win, pred)
  for i, l in ipairs(lines_of(win)) do
    if pred(l) then
      return i, l
    end
  end
end

local function wait_text(win, text)
  return vim.wait(3000, function()
    return vim.api.nvim_win_is_valid(win) and has_line(win, function(l)
      return l:find(text, 1, true) ~= nil
    end) ~= nil
  end, 10)
end

-- Row (1-based) and text of the line whose bead is `id` (not a "blocked by" marker).
local function item(win, id)
  for i, l in ipairs(lines_of(win)) do
    local s = l:find(id, 1, true)
    if s and not l:sub(1, s - 1):find("blocked", 1, true) then
      return i, l
    end
  end
end

local function press(win, keys)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

local function new_root(beads_dir)
  root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  if beads_dir then
    vim.fn.mkdir(root .. "/.beads", "p")
  end
  cli.set_root(root)
end

describe("tree rendering", function()
  before_each(function()
    if vim.fn.exists(":Beads") ~= 2 then
      vim.cmd.source(plugin_root .. "/plugin/beads.lua")
    end
    require("beads").setup({ tree = { layout = "split" } })
    orig_columns = vim.o.columns
    vim.o.columns = 200
    orig_path = vim.env.PATH
    bin_dir = vim.fn.tempname()
    vim.fn.mkdir(bin_dir, "p")
    vim.fn.writefile(vim.split(FAKE_BD, "\n"), bin_dir .. "/bd")
    vim.fn.setfperm(bin_dir .. "/bd", "rwxr-xr-x")
    fake_dir = vim.fn.tempname()
    vim.fn.mkdir(fake_dir, "p")
    vim.env.FAKE_DIR = fake_dir
    vim.env.PATH = bin_dir .. ":" .. orig_path
    set_list({})
    set_ready({})
    errors = {}
    orig_notify = vim.notify
    vim.notify = function(msg, level, opts)
      if level and level >= vim.log.levels.ERROR then
        errors[#errors + 1] = tostring(msg)
      end
    end
    vim.v.errmsg = ""
  end)

  after_each(function()
    vim.notify = orig_notify
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
    if root then
      pcall(vim.fn.delete, root, "rf")
      root = nil
    end
    cli.set_root(nil)
    vim.env.PATH = orig_path
    vim.fn.delete(bin_dir, "rf")
    vim.fn.delete(fake_dir, "rf")
    vim.o.columns = orig_columns
    require("beads").setup({ tree = { layout = "split" } })
  end)

  it("golden: nested epics render guides, fold markers and epic progress", function()
    new_root(true)
    set_list({
      bead("ep-a", "Epic alpha", { issue_type = "epic", priority = 1 }),
      child_of("ep-b", "ep-a", "Epic bravo", { issue_type = "epic", priority = 2 }),
      child_of("tk-c", "ep-b", "Task charlie", { priority = 2 }),
      child_of("tk-d", "tk-c", "Task delta", { priority = 2 }),
      child_of("tk-e", "ep-b", "Task echo", { priority = 3 }),
      child_of("tk-f", "ep-a", "Task foxtrot", { priority = 3 }),
      child_of("tk-g", "tk-f", "Task golf", { priority = 2 }),
      blocks(bead("tk-h", "Task hotel", { priority = 3 }), "tk-c"),
    })
    local tree = open_tree()
    assert.is_not_nil(tree, ":Beads tree opened no window")
    assert(wait_text(tree, "tk-g"), "tree never rendered:\n" .. dump(tree))
    local want = {
      "▾ ○ ep-a P1 Epic alpha [0/2]",
      "├ ▾ ○ ep-b P2 Epic bravo [0/2]",
      "│ ├ ▾ ○ tk-c P2 Task charlie",
      "│ │ └   ○ tk-d P2 Task delta",
      "│ └   ○ tk-e P3 Task echo",
      "└ ▾ ○ tk-f P3 Task foxtrot",
      "  └   ○ tk-g P2 Task golf",
      "  ○ tk-h P3 Task hotel ⛔ blocked by tk-c",
    }
    local all = lines_of(tree)
    local first = has_line(tree, function(l)
      return l:find("ep-a", 1, true) ~= nil
    end)
    assert.is_not_nil(first, dump(tree))
    local got = {}
    for i = first, math.min(#all, first + #want - 1) do
      got[#got + 1] = rtrim(all[i])
    end
    assert.are.same(want, got, "tree:\n" .. dump(tree))
    for i = first + #want, #all do
      assert.are.equal("", vim.trim(all[i]), "unexpected line after the tree:\n" .. dump(tree))
    end
  end)

  it("golden: with H the closed beads are shown and the last-sibling guides move to them", function()
    new_root(true)
    set_list({
      bead("ep-a", "Epic alpha", { issue_type = "epic", priority = 1 }),
      child_of("ep-b", "ep-a", "Epic bravo", { issue_type = "epic", priority = 2 }),
      child_of("tk-c", "ep-b", "Task charlie", { priority = 2 }),
      child_of("tk-d", "ep-b", "Task delta", { priority = 2, status = "closed" }),
      child_of("tk-e", "ep-a", "Task echo", { priority = 2 }),
      child_of("tk-h", "tk-e", "Task hotel", { priority = 2 }),
      child_of("tk-g", "ep-a", "Task golf", { priority = 3, status = "closed" }),
      bead("tk-f", "Task foxtrot", { priority = 3 }),
    })
    local tree = open_tree()
    assert.is_not_nil(tree, ":Beads tree opened no window")
    assert(wait_text(tree, "tk-h"), "tree never rendered:\n" .. dump(tree))
    local function block(n)
      local all = lines_of(tree)
      local first = has_line(tree, function(l)
        return l:find("ep-a", 1, true) ~= nil
      end)
      local got = {}
      for i = first, math.min(#all, first + n - 1) do
        got[#got + 1] = rtrim(all[i])
      end
      return got
    end
    assert.are.same({
      "▾ ○ ep-a P1 Epic alpha [1/3]",
      "├ ▾ ○ ep-b P2 Epic bravo [1/2]",
      "│ └   ○ tk-c P2 Task charlie",
      "└ ▾ ○ tk-e P2 Task echo",
      "  └   ○ tk-h P2 Task hotel",
      "  ○ tk-f P3 Task foxtrot",
    }, block(6), "H off:\n" .. dump(tree))
    press(tree, "H")
    assert(wait_text(tree, "tk-g"), "H did not show closed beads:\n" .. dump(tree))
    assert.are.same({
      "▾ ○ ep-a P1 Epic alpha [1/3]",
      "├ ▾ ○ ep-b P2 Epic bravo [1/2]",
      "│ ├   ○ tk-c P2 Task charlie",
      "│ └   ✓ tk-d P2 Task delta",
      "├ ▾ ○ tk-e P2 Task echo",
      "│ └   ○ tk-h P2 Task hotel",
      "└   ✓ tk-g P3 Task golf",
      "  ○ tk-f P3 Task foxtrot",
    }, block(8), "H on:\n" .. dump(tree))
  end)

  local function progress_items()
    return {
      bead("ep-p", "Progress epic", { issue_type = "epic", priority = 1 }),
      child_of("pc-1", "ep-p", "Open one"),
      child_of("pc-2", "ep-p", "Open two"),
      child_of("pc-3", "ep-p", "Closed three", { status = "closed" }),
      child_of("pg-1", "pc-1", "Closed grandchild", { status = "closed" }),
      child_of("pg-2", "pc-1", "Open grandchild"),
    }
  end

  it("epic lines show [closed/total] of direct children, with and without H", function()
    new_root(true)
    set_list(progress_items())
    local tree = open_tree()
    assert.is_not_nil(tree, ":Beads tree opened no window")
    assert(wait_text(tree, "pc-2"), "tree never rendered:\n" .. dump(tree))
    local _, line = item(tree, "ep-p")
    assert.is_truthy(rtrim(line):find("%[1/3%]$"), "epic line lacks [1/3] (H off): " .. line)
    press(tree, "H")
    assert(wait_text(tree, "pc-3"), "H did not show closed beads:\n" .. dump(tree))
    _, line = item(tree, "ep-p")
    assert.is_truthy(rtrim(line):find("%[1/3%]$"), "epic line lacks [1/3] (H on): " .. line)
  end)

  -- Highlight extmarks (all namespaces) covering byte column `col` of 0-based `row`.
  local function marks_at(buf, row, col)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, { row, 0 }, { row, -1 }, { details = true })) do
      local d = m[4]
      if d.hl_group and m[2] == row then
        local er, ec = d.end_row or row, d.end_col or m[3]
        local covers = m[3] <= col and (er > row or col < ec)
        if covers then
          out[#out + 1] = { group = d.hl_group, priority = d.priority or 4096 }
        end
      end
    end
    return out
  end

  local function dim_wins(marks)
    local p
    for _, m in ipairs(marks) do
      if m.group == "BeadsDim" then
        p = math.max(p or -1, m.priority)
      end
    end
    if not p then
      return false
    end
    for _, m in ipairs(marks) do
      if m.group ~= "BeadsDim" and m.priority >= p then
        return false
      end
    end
    return true
  end

  it("closed beads (shown with H) and their text use BeadsDim; open beads do not", function()
    new_root(true)
    set_list(progress_items())
    local tree = open_tree()
    assert.is_not_nil(tree, ":Beads tree opened no window")
    assert(wait_text(tree, "pc-2"), "tree never rendered:\n" .. dump(tree))
    press(tree, "H")
    assert(wait_text(tree, "pc-3"), "H did not show closed beads:\n" .. dump(tree))
    local buf = vim.api.nvim_win_get_buf(tree)
    local row, line = item(tree, "pc-3")
    local checks = {
      { "id", line:find("pc-3", 1, true) - 1 },
      { "title", line:find("Closed three", 1, true) - 1 },
      { "title end", line:find("Closed three", 1, true) - 1 + #"Closed three" - 1 },
      { "status glyph", line:find("✓", 1, true) - 1 },
    }
    for _, c in ipairs(checks) do
      local marks = marks_at(buf, row - 1, c[2])
      assert.is_true(dim_wins(marks),
        "closed bead " .. c[1] .. " is not shown with BeadsDim on top: " .. vim.inspect(marks) .. "\n" .. line)
    end
    local orow, oline = item(tree, "pc-2")
    local omarks = marks_at(buf, orow - 1, oline:find("Open two", 1, true) - 1)
    for _, m in ipairs(omarks) do
      assert.are_not.equal("BeadsDim", m.group, "open bead title is dimmed: " .. oline)
    end
  end)

  it("guides and ⛔ markers are highlighted with BeadsGuide and BeadsBlocked", function()
    new_root(true)
    set_list({
      bead("ep-a", "Epic alpha", { issue_type = "epic", priority = 1 }),
      child_of("tk-b", "ep-a", "Task bravo"),
      blocks(child_of("tk-c", "ep-a", "Task charlie"), "tk-b"),
    })
    local tree = open_tree()
    assert.is_not_nil(tree, ":Beads tree opened no window")
    assert(wait_text(tree, "tk-c"), "tree never rendered:\n" .. dump(tree))
    local buf = vim.api.nvim_win_get_buf(tree)
    local row, line = item(tree, "tk-c")
    local g = line:find("└", 1, true)
    assert.is_not_nil(g, "no └ guide on the last child: " .. line)
    local groups = vim.tbl_map(function(m)
      return m.group
    end, marks_at(buf, row - 1, g - 1))
    assert.is_true(vim.tbl_contains(groups, "BeadsGuide"), "guide not BeadsGuide: " .. vim.inspect(groups))
    local s = line:find("⛔", 1, true)
    assert.is_not_nil(s, "no ⛔ marker: " .. line)
    groups = vim.tbl_map(function(m)
      return m.group
    end, marks_at(buf, row - 1, s - 1))
    assert.is_true(vim.tbl_contains(groups, "BeadsBlocked"), "⛔ not BeadsBlocked: " .. vim.inspect(groups))
  end)

  it("header line shows root name and open/ready/need-you counts, updated on store refresh", function()
    new_root(true)
    set_list({
      bead("hd-a", "Alpha"),
      blocks(bead("hd-b", "Bravo"), "hd-a"),
      blocks(bead("hd-c", "Charlie"), "hd-d"),
      bead("hd-d", "Delta", { status = "closed" }),
      bead("hd-e", "Echo", { labels = { "human" } }),
    })
    set_ready({ bead("hd-a", "Alpha"), bead("hd-c", "Charlie"), bead("hd-e", "Echo", { labels = { "human" } }) })
    local name = vim.fn.fnamemodify(root, ":t")
    local tree = open_tree()
    assert.is_not_nil(tree, ":Beads tree opened no window")
    local want = "beads · " .. name .. " · 4 open · 3 ready · 1 need you (0💬 1👤)"
    local function header_is(w)
      return vim.wait(3000, function()
        if not vim.api.nvim_win_is_valid(tree) then
          return false
        end
        local first = lines_of(tree)[1] or ""
        return first:sub(1, #w) == w
      end, 10)
    end
    assert(header_is(want), "line 1 is not '" .. want .. "':\n" .. dump(tree))
    local buf = vim.api.nvim_win_get_buf(tree)
    local groups = vim.tbl_map(function(m)
      return m.group
    end, marks_at(buf, 0, 0))
    assert.is_true(vim.tbl_contains(groups, "BeadsHeader"), "header not BeadsHeader: " .. vim.inspect(groups))

    set_list({
      bead("hd-a", "Alpha", { status = "closed" }),
      blocks(bead("hd-b", "Bravo"), "hd-a"),
      blocks(bead("hd-c", "Charlie"), "hd-d"),
      bead("hd-d", "Delta", { status = "closed" }),
      bead("hd-e", "Echo", { labels = { "human" } }),
      blocks(bead("hd-f", "Foxtrot"), "hd-g"),
      bead("hd-g", "Golf", { labels = { "human" } }),
    })
    set_ready({
      bead("hd-b", "Bravo"),
      bead("hd-c", "Charlie"),
      bead("hd-e", "Echo", { labels = { "human" } }),
      bead("hd-g", "Golf", { labels = { "human" } }),
    })
    store.refresh(root)
    local want2 = "beads · " .. name .. " · 5 open · 4 ready · 2 need you (0💬 2👤)"
    assert(header_is(want2), "header did not update to '" .. want2 .. "':\n" .. dump(tree))
  end)

  it("empty repo shows 'No beads here — <leader>bc to create' with no error", function()
    new_root(true)
    set_list({})
    local tree = open_tree()
    assert.is_not_nil(tree, ":Beads tree opened no window")
    assert(wait_text(tree, "No beads here — <leader>bc to create"), "no empty state:\n" .. dump(tree))
    assert.are.same({}, errors)
    assert.are.equal("", vim.v.errmsg)
  end)

  it("the empty state names the configured create key", function()
    require("beads").setup({ tree = { layout = "split" }, keymaps = { create = "<leader>bX" } })
    new_root(true)
    set_list({})
    local tree = open_tree()
    assert.is_not_nil(tree, ":Beads tree opened no window")
    assert(wait_text(tree, "No beads here — <leader>bX to create"), "empty state lacks the key:\n" .. dump(tree))
  end)

  it("a non-beads directory shows 'Not a beads repo — run bd init' with no error", function()
    new_root(false)
    vim.fn.writefile({ 'Error: cannot use -C directory "' .. root .. '": no beads project found' }, fake_dir .. "/fail")
    local tree = open_tree()
    assert.is_not_nil(tree, ":Beads tree opened no window")
    assert(wait_text(tree, "Not a beads repo — run bd init"), "no non-beads empty state:\n" .. dump(tree))
    assert.is_nil(has_line(tree, function(l)
      return l:find("No beads here", 1, true) ~= nil
    end), "non-beads dir also shows the empty-repo state:\n" .. dump(tree))
    assert.are.same({}, errors)
    assert.are.equal("", vim.v.errmsg)
  end)
end)
