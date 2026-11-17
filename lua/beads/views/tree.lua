-- Tree view (:Beads tree): left vsplit, one per tabpage, parent-child nesting.
local cli = require("beads.cli")
local store = require("beads.store")
local workflow = require("beads.workflow")

local M = {}

local views = {} -- tabpage -> { win, buf, root, show_closed, ids, unsub, release }

local HELP = {
  "<CR>  open bead in the previous window",
  "a     add child bead",
  "x     close bead (prompts for a reason)",
  "C     claim bead",
  "R     refresh",
  "H     toggle closed beads",
  "za/zo/zc  fold",
  "yy    yank bead id",
  "yr    yank workflow run command",
  "q     close tree",
  "g?    show this help",
}

local function sorted(list)
  table.sort(list, function(a, b)
    local pa, pb = a.priority or 99, b.priority or 99
    if pa ~= pb then
      return pa < pb
    end
    return a.id < b.id
  end)
  return list
end

local function build_lines(v, st)
  local lines, ids = {}, {}
  local seen = {}
  local function visible(b)
    return v.show_closed or b.status ~= "closed"
  end
  local function emit(b, depth)
    if seen[b.id] then
      return
    end
    seen[b.id] = true
    if not visible(b) then
      -- hidden bead: still show its visible descendants at this depth
      for _, c in ipairs(sorted(st.children_of(b.id))) do
        emit(c, depth)
      end
      return
    end
    local parts = {
      string.rep("  ", depth) .. b.id,
      "P" .. tostring(b.priority or "?"),
      b.status or "?",
      b.title or "",
    }
    for _, g in ipairs(workflow.badges(b)) do
      parts[#parts + 1] = g
    end
    for _, bid in ipairs(b.blocked_by or {}) do
      local blk = st.by_id[bid]
      if not blk or blk.status ~= "closed" then
        parts[#parts + 1] = "⛔ blocked by " .. bid
      end
    end
    lines[#lines + 1] = table.concat(parts, " ")
    ids[#lines] = b.id
    for _, c in ipairs(sorted(st.children_of(b.id))) do
      emit(c, depth + 1)
    end
  end
  local roots = st.roots()
  for _, b in pairs(st.by_id) do
    if b.parent and not st.by_id[b.parent] then
      roots[#roots + 1] = b
    end
  end
  for _, b in ipairs(sorted(roots)) do
    emit(b, 0)
  end
  return lines, ids
end

local function render(v)
  if not vim.api.nvim_buf_is_valid(v.buf) then
    return
  end
  local cur_id
  if vim.api.nvim_win_is_valid(v.win) then
    cur_id = v.ids[vim.api.nvim_win_get_cursor(v.win)[1]]
  end
  local lines, ids = build_lines(v, store.get(v.root))
  v.ids = ids
  vim.bo[v.buf].modifiable = true
  vim.api.nvim_buf_set_lines(v.buf, 0, -1, false, lines)
  vim.bo[v.buf].modifiable = false
  if cur_id and vim.api.nvim_win_is_valid(v.win) then
    for row, id in pairs(ids) do
      if id == cur_id then
        vim.api.nvim_win_set_cursor(v.win, { row, 0 })
        break
      end
    end
  end
end

local function close(tab)
  local v = views[tab]
  if not v then
    return
  end
  views[tab] = nil
  if v.unsub then
    v.unsub()
  end
  if v.release then
    v.release()
  end
  if vim.api.nvim_win_is_valid(v.win) and #vim.api.nvim_tabpage_list_wins(tab) > 1 then
    pcall(vim.api.nvim_win_close, v.win, true)
  end
  if vim.api.nvim_buf_is_valid(v.buf) then
    pcall(vim.api.nvim_buf_delete, v.buf, { force = true })
  end
end

local function prev_win(v)
  local pw = vim.fn.win_getid(vim.fn.winnr("#"))
  if pw ~= 0 and pw ~= v.win and vim.api.nvim_win_is_valid(pw) then
    return pw
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= v.win and vim.api.nvim_win_get_config(w).relative == "" then
      return w
    end
  end
end

local function setup_keys(v, tab)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = v.buf, nowait = true, silent = true, desc = "Beads tree: " .. desc })
  end
  local function cur()
    return v.ids[vim.api.nvim_win_get_cursor(0)[1]]
  end
  local function with_id(fn)
    return function()
      local id = cur()
      if id then
        fn(id)
      end
    end
  end
  local function in_root(fn)
    local prev = cli.get_root_override()
    cli.set_root(v.root)
    fn()
    cli.set_root(prev)
  end
  local function after(res)
    if res.err then
      vim.notify("Beads: " .. res.err, vim.log.levels.ERROR)
    end
    store.mark_self_write(v.root)
    store.refresh(v.root)
  end
  map("<CR>", with_id(function(id)
    local pw = prev_win(v)
    if not pw then
      return
    end
    vim.api.nvim_set_current_win(pw)
    vim.cmd.edit(vim.fn.fnameescape("beads://" .. id))
  end), "open")
  map("a", with_id(function(id)
    local pw = prev_win(v)
    if not pw then
      return
    end
    vim.api.nvim_set_current_win(pw)
    require("beads.views.detail").create_child(id)
  end), "add child")
  map("x", with_id(function(id)
    vim.ui.input({ prompt = "Close reason (optional): " }, function(reason)
      if reason ~= nil then
        in_root(function()
          cli.close(id, reason, after)
        end)
      end
    end)
  end), "close bead")
  map("C", with_id(function(id)
    in_root(function()
      cli.claim(id, after)
    end)
  end), "claim")
  map("R", function()
    store.refresh(v.root)
  end, "refresh")
  map("H", function()
    v.show_closed = not v.show_closed
    render(v)
  end, "toggle closed")
  map("yy", with_id(function(id)
    vim.fn.setreg('"', id)
  end), "yank id")
  map("yr", with_id(function(id)
    local b = store.get(v.root).by_id[id]
    if b then
      vim.fn.setreg('"', workflow.run_command(b))
    end
  end), "yank run command")
  map("q", function()
    close(tab)
  end, "close")
  map("g?", function()
    vim.notify("Beads tree keys:\n" .. table.concat(HELP, "\n"), vim.log.levels.INFO)
  end, "help")
end

local function open()
  local tab = vim.api.nvim_get_current_tabpage()
  local root = cli.get_root()
  local width = (require("beads").config.tree or {}).width or 50
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "beads-tree"
  vim.cmd("topleft vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, width)
  vim.wo[win].winfixwidth = true
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldmethod = "indent"
  vim.wo[win].foldlevel = 99
  vim.bo[buf].shiftwidth = 2
  local v = { win = win, buf = buf, root = root, show_closed = false, ids = {} }
  views[tab] = v
  v.release = require("beads.watch").acquire(root)
  v.unsub = store.subscribe(root, function()
    if views[tab] == v then
      render(v)
    end
  end)
  setup_keys(v, tab)
  vim.api.nvim_create_autocmd({ "BufWipeout", "WinClosed" }, {
    buffer = buf,
    once = true,
    callback = function()
      if views[tab] == v then
        views[tab] = nil
        v.unsub()
        v.release()
      end
    end,
  })
  render(v)
  store.refresh(root)
end

function M.toggle()
  local tab = vim.api.nvim_get_current_tabpage()
  local v = views[tab]
  if v and vim.api.nvim_win_is_valid(v.win) then
    close(tab)
  else
    if v then
      close(tab)
    end
    open()
  end
end

return M
