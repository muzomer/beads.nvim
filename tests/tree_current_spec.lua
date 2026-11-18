-- Bead beads_nvim-4u9.6: current bead highlight, reveal and jump flash.
-- Interface under test (public behaviour only):
--   * The tree line of the bead shown in the current / most recent detail window (beads://<id>)
--     carries an extmark with the BeadsCurrent group (hl_group or line_hl_group); exactly one
--     tree row has it. Entering another beads:// buffer moves it.
--   * On BufEnter of a beads:// buffer the tree opens the ancestor folds of that bead and scrolls
--     it into view; the focus stays in the detail window.
--   * Opening a bead from the tree (<CR>) or a picker (require("beads.views.picker").open_bead)
--     flashes the landing line: the cursor line of the detail window gets a BeadsFlash extmark,
--     removed after setup({ flash_ms = <ms> }) (default 350); flash_ms = false shows none.
--   * A bead whose detail buffer was wiped and that is no longer current keeps no highlight.
-- `bd` is replaced by a shell script on PATH (test double): `show <id>` prints show_<id>.json,
-- `list --label ...` (the human-questions lookup) prints [], anything else prints list.json.

local cli = require("beads.cli")
local store = require("beads.store")

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local FAKE_BD = [[#!/bin/sh
prev=""
for a in "$@"; do
  if [ "$prev" = "show" ]; then
    if [ -f "$FAKE_DIR/show_$a.json" ]; then
      cat "$FAKE_DIR/show_$a.json"
    else
      echo "[]"
    fi
    exit 0
  fi
  if [ "$a" = "--label" ]; then
    echo "[]"
    exit 0
  fi
  prev="$a"
done
cat "$FAKE_DIR/list.json"
]]

local orig_path, bin_dir, fake_dir, orig_columns, orig_lines

local function bead(id, title, extra)
  local b = {
    id = id,
    title = title,
    status = "open",
    priority = 2,
    issue_type = "task",
    description = "Body of " .. id,
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

-- ep-a > { ch-b, ep-s > { gc-x, gc-y } }, ep-t > { tc-1, tc-2 }, root leaf bl-d.
local function base_items()
  return {
    bead("ep-a", "Epic alpha", { issue_type = "epic", priority = 1 }),
    child_of("ch-b", "ep-a", "Child bravo"),
    child_of("ep-s", "ep-a", "Sub epic", { issue_type = "epic" }),
    child_of("gc-x", "ep-s", "Grandchild xray"),
    child_of("gc-y", "ep-s", "Grandchild yankee"),
    bead("ep-t", "Epic tango", { issue_type = "epic", priority = 3 }),
    child_of("tc-1", "ep-t", "Tango one"),
    child_of("tc-2", "ep-t", "Tango two"),
    bead("bl-d", "Leaf delta"),
  }
end

-- 60 priority-0 root beads sorted before everything else, so gc-x is far below the first screen.
local function with_fillers()
  local items = {}
  for i = 1, 60 do
    items[#items + 1] = bead(("fl-%02d"):format(i), "Filler " .. i, { priority = 0 })
  end
  vim.list_extend(items, base_items())
  return items
end

local function set_list(items)
  vim.fn.writefile({ vim.json.encode(items) }, fake_dir .. "/list.json")
  for _, b in ipairs(items) do
    vim.fn.writefile({ vim.json.encode({ b }) }, fake_dir .. "/show_" .. b.id .. ".json")
  end
end

local function prefill()
  local done = false
  store.refresh(cli.get_root(), function()
    done = true
  end)
  assert(vim.wait(3000, function()
    return done
  end, 10), "store refresh never completed")
end

local function wins()
  return vim.api.nvim_tabpage_list_wins(0)
end

local function lines_of(win)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

local function row_of(win, id)
  for i, l in ipairs(lines_of(win)) do
    local s = l:find(id, 1, true)
    if s and not l:sub(1, s - 1):find("blocked", 1, true) then
      return i
    end
  end
  return nil
end

local function dump(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return "<no tree window>"
  end
  return table.concat(lines_of(win), "\n")
end

local function wcall(win, fn)
  return vim.api.nvim_win_call(win, fn)
end

-- Rows (1-based, sorted) of `buf` carrying an extmark with highlight `group`, over all namespaces.
local function hl_rows(buf, group)
  local set = {}
  if not vim.api.nvim_buf_is_valid(buf) then
    return {}
  end
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    local d = m[4] or {}
    if d.hl_group == group or d.line_hl_group == group then
      set[m[2] + 1] = true
    end
  end
  local rows = vim.tbl_keys(set)
  table.sort(rows)
  return rows
end

local function current_rows(tree)
  return hl_rows(vim.api.nvim_win_get_buf(tree), "BeadsCurrent")
end

local function only_row(rows, row)
  return #rows == 1 and rows[1] == row
end

local function wait_current(tree, id)
  return vim.wait(2000, function()
    local r = row_of(tree, id)
    return r ~= nil and only_row(current_rows(tree), r)
  end, 10)
end

local function current_msg(tree, id)
  return ("expected exactly %s's row (%s) to carry BeadsCurrent, got rows {%s}:\n%s"):format(
    id,
    tostring(row_of(tree, id)),
    table.concat(current_rows(tree), ","),
    dump(tree)
  )
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
  return nil
end

local function ready_tree(last_id)
  local tree = open_tree()
  assert.is_not_nil(tree, ":Beads tree opened no window")
  assert(vim.wait(3000, function()
    return vim.api.nvim_win_is_valid(tree)
      and row_of(tree, last_id or "bl-d") ~= nil
      and (lines_of(tree)[1] or ""):find("^beads ·") ~= nil
  end, 10), "tree never rendered:\n" .. dump(tree))
  wcall(tree, function()
    vim.cmd("silent! normal! zR")
  end)
  return tree
end

-- The non-tree, non-floating window of this tabpage.
local function main_win(tree)
  for _, w in ipairs(wins()) do
    if w ~= tree and vim.api.nvim_win_get_config(w).relative == "" then
      return w
    end
  end
end

local function detail_loaded(buf)
  return vim.api.nvim_buf_is_valid(buf)
    and table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("Body of", 1, true) ~= nil
end

local function edit_in(win, id)
  vim.api.nvim_set_current_win(win)
  vim.cmd.edit(vim.fn.fnameescape("beads://" .. id))
  local buf = vim.api.nvim_get_current_buf()
  assert(vim.wait(3000, function()
    return detail_loaded(buf)
  end, 10), "detail beads://" .. id .. " never loaded")
  return buf
end

local function press(win, keys)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

-- Every BeadsFlash row of every buffer, as "buf:row" strings.
local function all_flashes()
  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    for _, r in ipairs(hl_rows(b, "BeadsFlash")) do
      out[#out + 1] = b .. ":" .. r
    end
  end
  return out
end

-- True when the cursor line of `win` carries a BeadsFlash extmark.
local function flash_on_cursor(win)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  return vim.tbl_contains(hl_rows(vim.api.nvim_win_get_buf(win), "BeadsFlash"), row)
end

local function setup_plugin(opts)
  require("beads").setup(opts or {})
end

describe("tree current bead, reveal and jump flash", function()
  before_each(function()
    if vim.fn.exists(":Beads") ~= 2 then
      vim.cmd.source(plugin_root .. "/plugin/beads.lua")
    end
    setup_plugin({})
    orig_columns = vim.o.columns
    orig_lines = vim.o.lines
    vim.o.columns = 200
    vim.o.lines = 30
    orig_path = vim.env.PATH
    bin_dir = vim.fn.tempname()
    vim.fn.mkdir(bin_dir, "p")
    vim.fn.writefile(vim.split(FAKE_BD, "\n"), bin_dir .. "/bd")
    vim.fn.setfperm(bin_dir .. "/bd", "rwxr-xr-x")
    fake_dir = vim.fn.tempname()
    vim.fn.mkdir(fake_dir, "p")
    vim.env.FAKE_DIR = fake_dir
    vim.env.PATH = bin_dir .. ":" .. orig_path
    local r = vim.fn.tempname()
    vim.fn.mkdir(r, "p")
    cli.set_root(r)
    set_list(base_items())
    prefill()
  end)

  after_each(function()
    -- let pending flash-clear timers (largest flash_ms used: 600) fire before buffers go away
    vim.wait(650, function()
      return #all_flashes() == 0
    end, 10)
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
    pcall(vim.fn.delete, cli.get_root(), "rf")
    cli.set_root(nil)
    vim.env.PATH = orig_path
    vim.fn.delete(bin_dir, "rf")
    vim.fn.delete(fake_dir, "rf")
    vim.o.columns = orig_columns
    vim.o.lines = orig_lines
    setup_plugin({})
  end)

  it("opening beads://X marks X's tree line with BeadsCurrent; opening Y moves it", function()
    local tree = ready_tree()
    local main = main_win(tree)
    assert.is_not_nil(main, "no main window next to the tree")
    edit_in(main, "ch-b")
    assert(wait_current(tree, "ch-b"), current_msg(tree, "ch-b"))
    edit_in(main, "tc-1")
    assert(wait_current(tree, "tc-1"), current_msg(tree, "tc-1"))
  end)

  it("re-entering an already loaded beads:// buffer moves the highlight back (BufEnter)", function()
    local tree = ready_tree()
    local main = main_win(tree)
    local buf_b = edit_in(main, "ch-b")
    assert(wait_current(tree, "ch-b"), current_msg(tree, "ch-b"))
    edit_in(main, "tc-1")
    assert(wait_current(tree, "tc-1"), current_msg(tree, "tc-1"))
    vim.api.nvim_set_current_win(main)
    vim.cmd.buffer(buf_b)
    assert(wait_current(tree, "ch-b"), current_msg(tree, "ch-b"))
  end)

  it("the highlight survives a store refresh that re-renders the tree", function()
    local tree = ready_tree()
    local main = main_win(tree)
    edit_in(main, "tc-2")
    assert(wait_current(tree, "tc-2"), current_msg(tree, "tc-2"))
    local items = { bead("aa-new", "New root", { priority = 0 }) }
    vim.list_extend(items, base_items())
    set_list(items)
    store.refresh(cli.get_root())
    assert(vim.wait(3000, function()
      return row_of(tree, "aa-new") ~= nil
    end, 10), "tree did not re-render on refresh:\n" .. dump(tree))
    assert(wait_current(tree, "tc-2"), current_msg(tree, "tc-2"))
  end)

  it("a detail opened before the tree is marked when the tree opens", function()
    edit_in(vim.api.nvim_get_current_win(), "bl-d")
    local tree = ready_tree()
    assert(wait_current(tree, "bl-d"), current_msg(tree, "bl-d"))
  end)

  it("entering a bead inside a folded epic opens its folds and scrolls it into view, keeping focus", function()
    set_list(with_fillers())
    prefill()
    local tree = ready_tree("gc-y")
    local main = main_win(tree)
    wcall(tree, function()
      vim.cmd("silent! normal! zM")
      vim.api.nvim_win_set_cursor(tree, { 1, 0 })
      vim.cmd("silent! normal! gg")
    end)
    local rx = row_of(tree, "gc-x")
    vim.cmd.redraw()
    local info = vim.fn.getwininfo(tree)[1]
    assert.are_not.equal(-1, wcall(tree, function()
      return vim.fn.foldclosed(rx)
    end), "setup: gc-x is not folded after zM:\n" .. dump(tree))
    assert.is_true(rx > info.botline, "setup: gc-x is already on screen (botline " .. info.botline .. ")")

    vim.api.nvim_set_current_win(main)
    vim.cmd.edit(vim.fn.fnameescape("beads://gc-x"))
    local dbuf = vim.api.nvim_get_current_buf()
    assert(vim.wait(3000, function()
      return detail_loaded(dbuf)
    end, 10), "detail beads://gc-x never loaded")

    local revealed = vim.wait(3000, function()
      rx = row_of(tree, "gc-x")
      if not rx then
        return false
      end
      local closed = wcall(tree, function()
        return vim.fn.foldclosed(rx)
      end)
      vim.cmd.redraw()
      local wi = vim.fn.getwininfo(tree)[1]
      return closed == -1 and rx >= wi.topline and rx <= wi.botline
    end, 10)
    local wi = vim.fn.getwininfo(tree)[1]
    assert(
      revealed,
      ("gc-x (row %s) not revealed: foldclosed=%s, view %d..%d"):format(
        tostring(rx),
        tostring(rx and wcall(tree, function()
          return vim.fn.foldclosed(rx)
        end)),
        wi.topline,
        wi.botline
      )
    )
    assert.are.equal(main, vim.api.nvim_get_current_win(), "focus left the detail window")
    assert.are.equal(dbuf, vim.api.nvim_get_current_buf(), "the detail buffer is no longer current")
    assert(wait_current(tree, "gc-x"), current_msg(tree, "gc-x"))
  end)

  it("<CR> in the tree flashes the landing line of the detail window", function()
    local tree = ready_tree()
    local main = main_win(tree)
    vim.api.nvim_set_current_win(tree)
    vim.api.nvim_win_set_cursor(tree, { row_of(tree, "ch-b"), 0 })
    press(tree, "<CR>")
    assert.are.equal(main, vim.api.nvim_get_current_win(), "<CR> did not land in the main window")
    assert.are.equal("beads://ch-b", vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()))
    assert(vim.wait(1000, function()
      return flash_on_cursor(main)
    end, 5), "no BeadsFlash on the landing line; flashes: {" .. table.concat(all_flashes(), ",") .. "}")
  end)

  it("picker open_bead flashes the landing line of the detail window", function()
    local tree = ready_tree()
    local main = main_win(tree)
    vim.api.nvim_set_current_win(main)
    require("beads.views.picker").open_bead("tc-1")
    assert.are.equal("beads://tc-1", vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()))
    assert(vim.wait(1000, function()
      return flash_on_cursor(main)
    end, 5), "no BeadsFlash on the landing line; flashes: {" .. table.concat(all_flashes(), ",") .. "}")
  end)

  it("the flash is removed after flash_ms", function()
    setup_plugin({ flash_ms = 600 })
    local tree = ready_tree()
    local main = main_win(tree)
    vim.api.nvim_set_current_win(tree)
    vim.api.nvim_win_set_cursor(tree, { row_of(tree, "tc-2"), 0 })
    press(tree, "<CR>")
    assert(vim.wait(1000, function()
      return flash_on_cursor(main)
    end, 5), "no BeadsFlash on the landing line")
    local seen = vim.uv.hrtime()
    vim.wait(150, function()
      return false
    end, 10)
    assert.is_true(
      #all_flashes() > 0 or (vim.uv.hrtime() - seen) / 1e6 > 550,
      "the flash vanished long before flash_ms = 600"
    )
    assert(vim.wait(2000, function()
      return #all_flashes() == 0
    end, 10), "BeadsFlash still present well after flash_ms: {" .. table.concat(all_flashes(), ",") .. "}")
  end)

  it("flash_ms = false shows no flash on tree or picker jumps", function()
    setup_plugin({ flash_ms = false })
    local tree = ready_tree()
    local main = main_win(tree)
    local saw = false
    local function watch_for(ms)
      vim.wait(ms, function()
        if #all_flashes() > 0 then
          saw = true
        end
        return false
      end, 5)
    end
    vim.api.nvim_set_current_win(tree)
    vim.api.nvim_win_set_cursor(tree, { row_of(tree, "ch-b"), 0 })
    press(tree, "<CR>")
    if #all_flashes() > 0 then
      saw = true
    end
    -- the jump path ran: the detail loaded and the tree marks it as current
    assert(wait_current(tree, "ch-b"), current_msg(tree, "ch-b"))
    watch_for(500)
    vim.api.nvim_set_current_win(main)
    require("beads.views.picker").open_bead("tc-1")
    if #all_flashes() > 0 then
      saw = true
    end
    assert(wait_current(tree, "tc-1"), current_msg(tree, "tc-1"))
    watch_for(500)
    assert.is_false(saw, "a BeadsFlash appeared with flash_ms = false")
  end)

  it("no highlight remains for a wiped detail buffer that is no longer current", function()
    local tree = ready_tree()
    local main = main_win(tree)
    local buf_b = edit_in(main, "ch-b")
    assert(wait_current(tree, "ch-b"), current_msg(tree, "ch-b"))
    vim.api.nvim_set_current_win(main)
    vim.cmd("enew")
    -- still the most recent detail
    assert(wait_current(tree, "ch-b"), "most recent detail lost its mark on :enew\n" .. current_msg(tree, "ch-b"))
    vim.api.nvim_buf_delete(buf_b, { force = true })
    assert(vim.wait(3000, function()
      return #current_rows(tree) == 0
    end, 10), "BeadsCurrent left on rows {" .. table.concat(current_rows(tree), ",") .. "}:\n" .. dump(tree))
    store.refresh(cli.get_root())
    vim.wait(300, function()
      return false
    end, 10)
    assert.are.same({}, current_rows(tree), "a refresh brought back the wiped bead's highlight")
  end)

  it("wiping a non-current detail leaves the mark on the current one", function()
    local tree = ready_tree()
    local main = main_win(tree)
    local buf_b = edit_in(main, "ch-b")
    edit_in(main, "tc-1")
    assert(wait_current(tree, "tc-1"), current_msg(tree, "tc-1"))
    vim.api.nvim_buf_delete(buf_b, { force = true })
    vim.wait(200, function()
      return false
    end, 10)
    assert(wait_current(tree, "tc-1"), current_msg(tree, "tc-1"))
  end)
end)
