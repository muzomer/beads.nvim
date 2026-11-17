-- Interface under test (bead beads_nvim-ge7.16): keymap overrides and g? help across views.
--   require("beads").setup({ keys = { <view> = { <action> = lhs|false } } }) configures the
--   buffer-local maps of each view; false removes that map. Keys are nested per view.
--   Action names used here (others are the implementer's choice):
--     keys.tree.refresh  (default "R")
--     keys.tree.yank_id  (default "yy")
--     keys.detail.claim  (default "C")
--   g? in a view opens a floating window listing the active keys of that view (lhs + description).
--   Every buffer-local map the plugin sets carries a non-empty desc (which-key).
--   No global (non-buffer-local) keymaps are ever set.
-- bd is a fake on PATH (tests/picker_fake.lua).

-- Snapshot global keymaps BEFORE anything from the plugin is loaded or sourced.
local MODES = { "n", "i", "x", "s", "o", "c", "t" }
local function global_maps()
  local out = {}
  for _, m in ipairs(MODES) do
    for _, km in ipairs(vim.api.nvim_get_keymap(m)) do
      out[m .. "\0" .. km.lhs] = true
    end
  end
  return out
end
local BASELINE = global_maps()

local fake = require("tests.picker_fake")

local function wins()
  return vim.api.nvim_tabpage_list_wins(0)
end

local function new_win(before)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if not before[w] then
      return w
    end
  end
end

local function snapshot_wins()
  local s = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    s[w] = true
  end
  return s
end

local function open_tree()
  local before = snapshot_wins()
  vim.cmd("Beads tree")
  local w = new_win(before)
  assert.is_not_nil(w, ":Beads tree opened no window")
  local buf = vim.api.nvim_win_get_buf(w)
  assert(vim.wait(3000, function()
    for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if l:find("op-a", 1, true) then
        return true
      end
    end
    return false
  end, 10), "tree never rendered")
  return w, buf
end

local function open_detail(id)
  vim.cmd.edit(vim.fn.fnameescape("beads://" .. id))
  local buf = vim.api.nvim_get_current_buf()
  assert(vim.wait(3000, function()
    for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if l:find(id, 1, true) then
        return true
      end
    end
    return false
  end, 10), "detail buffer never loaded")
  return vim.api.nvim_get_current_win(), buf
end

local function lhs_norm(lhs)
  return vim.fn.keytrans(vim.keycode(lhs))
end

local function buf_map(buf, mode, lhs)
  local want = lhs_norm(lhs)
  for _, km in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if lhs_norm(km.lhs) == want then
      return km
    end
  end
end

local function press(win, keys)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

-- Presses keys in win; returns the new floating window that appeared (or nil).
local function press_for_float(win, keys)
  local before = snapshot_wins()
  press(win, keys)
  local found
  vim.wait(1000, function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if not before[w] and vim.api.nvim_win_get_config(w).relative ~= "" then
        found = w
        return true
      end
    end
    return false
  end, 10)
  vim.cmd("stopinsert")
  return found
end

-- Maps from Nvim's own runtime (e.g. ftplugin/markdown.vim's [[ and ]]) are not the plugin's.
local VIMRUNTIME = vim.fs.normalize(vim.env.VIMRUNTIME)
local function from_runtime(km)
  if not km.sid or km.sid <= 0 then
    return false
  end
  local info = vim.fn.getscriptinfo({ sid = km.sid })[1]
  return info ~= nil and vim.startswith(vim.fs.normalize(info.name), VIMRUNTIME)
end

local function assert_all_desc(buf, label)
  for _, m in ipairs({ "n", "i", "x", "s", "o" }) do
    for _, km in ipairs(vim.api.nvim_buf_get_keymap(buf, m)) do
      assert(
        from_runtime(km) or type(km.desc) == "string" and km.desc ~= "",
        label .. ": buffer-local " .. m .. "-mode map " .. tostring(km.lhs) .. " has no desc"
      )
    end
  end
end

local function close_float(w)
  if w and vim.api.nvim_win_is_valid(w) then
    pcall(vim.api.nvim_win_close, w, true)
  end
end

describe("beads keymaps", function()
  before_each(function()
    fake.setup()
  end)

  after_each(function()
    vim.cmd("stopinsert")
    fake.teardown()
  end)

  it("overriding a tree key changes the mapping", function()
    require("beads").setup({ keys = { tree = { refresh = "<F5>" } } })
    local _, buf = open_tree()
    local km = buf_map(buf, "n", "<F5>")
    assert.is_not_nil(km, "overridden refresh key <F5> is not mapped in the tree buffer")
    assert.is_truthy(km.desc and km.desc:lower():find("refresh"), "desc of <F5> does not mention refresh")
    assert.is_nil(buf_map(buf, "n", "R"), "default refresh key R still mapped after override")
  end)

  it("g? in the tree opens a float listing the overridden key, not the default", function()
    require("beads").setup({ keys = { tree = { refresh = "<F5>" } } })
    local win = open_tree()
    local f = press_for_float(win, "g?")
    assert.is_not_nil(f, "g? in the tree opened no floating window")
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(f), 0, -1, false)
    local text = table.concat(lines, "\n")
    close_float(f)
    local hit = false
    for _, l in ipairs(lines) do
      if l:find("<F5>", 1, true) and l:lower():find("refresh") then
        hit = true
      end
      assert.is_nil(l:find("%f[%w]R%f[%W]"), "help still lists default key R:\n" .. text)
    end
    assert.is_true(hit, "help has no line with <F5> and refresh:\n" .. text)
  end)

  it("setting a tree key to false removes the mapping", function()
    require("beads").setup({ keys = { tree = { yank_id = false } } })
    local _, buf = open_tree()
    assert.is_nil(buf_map(buf, "n", "yy"), "yy still mapped in tree with keys.tree.yank_id = false")
    assert.is_not_nil(buf_map(buf, "n", "R"), "other tree keys were lost")
  end)

  it("setting a detail key to false removes the mapping", function()
    require("beads").setup({ keys = { detail = { claim = false } } })
    local _, buf = open_detail("op-a")
    assert.is_nil(buf_map(buf, "n", "C"), "C still mapped in detail with keys.detail.claim = false")
    assert.is_not_nil(buf_map(buf, "n", "x"), "other detail keys were lost")
  end)

  it("every buffer-local map in tree, detail, note/comment floats and help floats has a desc", function()
    require("beads").setup({})
    local twin, tbuf = open_tree()
    assert_all_desc(tbuf, "tree")
    vim.cmd("wincmd l")
    vim.cmd("only")
    local dwin, dbuf = open_detail("op-a")
    assert_all_desc(dbuf, "detail")
    for _, key in ipairs({ "n", "c" }) do
      local f = press_for_float(dwin, key)
      assert.is_not_nil(f, key .. " in detail opened no float")
      local fbuf = vim.api.nvim_win_get_buf(f)
      local ok, err = pcall(assert_all_desc, fbuf, key .. " float")
      close_float(f)
      assert(ok, err)
    end
    local dh = press_for_float(dwin, "g?")
    assert.is_not_nil(dh, "g? in the detail buffer opened no floating window")
    assert_all_desc(vim.api.nvim_win_get_buf(dh), "detail help float")
    close_float(dh)

    twin = open_tree()
    local th = press_for_float(twin, "g?")
    assert.is_not_nil(th, "g? in the tree opened no floating window")
    assert_all_desc(vim.api.nvim_win_get_buf(th), "tree help float")
    close_float(th)
  end)

  -- passes already: guards that no global keymaps are set
  it("sets no global keymaps after loading and using the plugin", function()
    require("beads").setup({})
    local twin = open_tree()
    close_float(press_for_float(twin, "g?"))
    vim.cmd("wincmd l")
    vim.cmd("only")
    local dwin = open_detail("op-a")
    close_float(press_for_float(dwin, "g?"))
    close_float(press_for_float(dwin, "n"))
    close_float(press_for_float(dwin, "c"))
    local added = {}
    for k in pairs(global_maps()) do
      if not BASELINE[k] then
        added[#added + 1] = (k:gsub("%z", " "))
      end
    end
    table.sort(added)
    assert.are.same({}, added, "global keymaps added: " .. table.concat(added, ", "))
  end)
end)
