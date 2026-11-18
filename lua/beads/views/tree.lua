-- Tree view (:Beads tree): left vsplit, one per tabpage, parent-child nesting.
local cli = require("beads.cli")
local store = require("beads.store")
local workflow = require("beads.workflow")
local keys = require("beads.keys")

local M = {}

local NS = vim.api.nvim_create_namespace("beads_tree")

local views = {} -- tabpage -> { win, buf, root, show_closed, ids, unsub, release }

local F = require("beads.ui.format")
local sorted = F.sort

local function create_key()
  local k = (require("beads").config.keymaps or {}).create
  if type(k) == "table" then
    k = k[1]
  end
  return type(k) == "string" and k or "create"
end

local MARK_PRI, DIM_PRI = 100, 200

-- Returns lines, ids (row -> bead id), marks (row -> { {col, end_col, group, priority} }).
local function build_lines(v, st)
  local lines, ids, marks = {}, {}, {}
  local seen = {}
  local function visible(b)
    return v.show_closed or b.status ~= "closed"
  end
  -- Visible children of b; hidden children are replaced by their visible descendants.
  local function vis_children(b, stack)
    local out = {}
    for _, c in ipairs(sorted(st.children_of(b.id))) do
      if not stack[c.id] then
        if visible(c) then
          out[#out + 1] = c
        else
          stack[c.id] = true
          vim.list_extend(out, vis_children(c, stack))
          stack[c.id] = nil
        end
      end
    end
    return out
  end
  local function add_mark(row, col, end_col, group, pri)
    marks[row] = marks[row] or {}
    table.insert(marks[row], { col = col, end_col = end_col, group = group, priority = pri })
  end
  local function emit(b, depth, cells, last)
    if seen[b.id] then
      return
    end
    seen[b.id] = true
    local blockers = {}
    for _, bid in ipairs(b.blocked_by or {}) do
      local blk = st.by_id[bid]
      if not blk or blk.status ~= "closed" then
        blockers[#blockers + 1] = bid
      end
    end
    local kids = vis_children(b, { [b.id] = true })
    local text, ranges = F.format(b, { blockers = blockers })
    local guide = table.concat(cells)
    if depth > 0 then
      guide = guide .. (last and "└ " or "├ ")
    end
    local prefix = guide .. (#kids > 0 and "▾ " or "  ")
    local suffix = ""
    if b.type == "epic" then
      local direct = st.children_of(b.id)
      if #direct > 0 then
        local closed = 0
        for _, c in ipairs(direct) do
          if c.status == "closed" then
            closed = closed + 1
          end
        end
        suffix = (" [%d/%d]"):format(closed, #direct)
      end
    end
    local row = #lines + 1
    lines[row] = prefix .. text .. suffix
    ids[row] = b.id
    if #guide > 0 then
      add_mark(row, 0, #guide, "BeadsGuide", MARK_PRI)
    end
    if #kids > 0 then
      add_mark(row, #guide, #prefix, "BeadsGuide", MARK_PRI)
    end
    for _, r in ipairs(ranges) do
      add_mark(row, #prefix + r.col, #prefix + r.end_col, r.group, MARK_PRI)
    end
    if #suffix > 0 then
      add_mark(row, #prefix + #text, #prefix + #text + #suffix, "BeadsDim", MARK_PRI)
    end
    if b.status == "closed" then
      add_mark(row, #prefix, #prefix + #text, "BeadsDim", DIM_PRI)
    end
    local child_cells = vim.list_slice(cells)
    if depth > 0 then
      child_cells[#child_cells + 1] = last and "  " or "│ "
    end
    for i, c in ipairs(kids) do
      emit(c, depth + 1, child_cells, i == #kids)
    end
  end
  local roots = st.roots()
  for _, b in pairs(st.by_id) do
    if b.parent and not st.by_id[b.parent] then
      roots[#roots + 1] = b
    end
  end
  local top = {}
  local stack = {}
  for _, b in ipairs(sorted(roots)) do
    if visible(b) then
      top[#top + 1] = b
    else
      stack[b.id] = true
      vim.list_extend(top, vis_children(b, stack))
      stack[b.id] = nil
    end
  end
  for _, b in ipairs(top) do
    emit(b, 0, {}, false)
  end
  return lines, ids, marks
end

local function header_text(v, st)
  local open, need = 0, 0
  for _, b in pairs(st.by_id) do
    if b.status == "open" then
      open = open + 1
    end
    if b.status ~= "closed" and (b.waiting_user or require("beads.workflow").is_needs_me(b)) then
      need = need + 1
    end
  end
  local name = vim.fn.fnamemodify((v.root:gsub("/+$", "")), ":t")
  return ("beads · %s · %d open · %d ready · %d need you"):format(name, open, store.get(v.root).ready_n or 0, need)
end

local function render(v)
  if not vim.api.nvim_buf_is_valid(v.buf) then
    return
  end
  local cur_id
  if vim.api.nvim_win_is_valid(v.win) then
    cur_id = v.ids[vim.api.nvim_win_get_cursor(v.win)[1]]
  end
  local st = store.get(v.root)
  local lines, ids, marks = build_lines(v, st)
  if v.not_repo then
    lines, ids, marks = { "Not a beads repo — run bd init" }, {}, {}
  elseif v.loaded then
    local head = { header_text(v, st) }
    if next(st.by_id) == nil then
      head[2] = "No beads here — " .. create_key() .. " to create"
    end
    local n = #head
    local nl, ni, nm = vim.list_extend(head, lines), {}, {}
    for row, id in pairs(ids) do
      ni[row + n] = id
    end
    for row, m in pairs(marks) do
      nm[row + n] = m
    end
    lines, ids, marks = nl, ni, nm
    marks[1] = { { col = 0, end_col = #lines[1], group = "BeadsHeader", priority = MARK_PRI } }
    if n == 2 then
      marks[2] = { { col = 0, end_col = #lines[2], group = "BeadsDim", priority = MARK_PRI } }
    end
  end
  v.ids = ids
  vim.bo[v.buf].modifiable = true
  vim.api.nvim_buf_set_lines(v.buf, 0, -1, false, lines)
  vim.bo[v.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(v.buf, NS, 0, -1)
  for row, ms in pairs(marks) do
    for _, m in ipairs(ms) do
      vim.api.nvim_buf_set_extmark(v.buf, NS, row - 1, m.col, {
        end_col = m.end_col,
        hl_group = m.group,
        priority = m.priority,
      })
    end
  end
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
  local acts = {}
  local function map(name, fn)
    acts[name] = fn
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
  map("open", with_id(function(id)
    local pw = prev_win(v)
    if not pw then
      return
    end
    vim.api.nvim_set_current_win(pw)
    vim.cmd.edit(vim.fn.fnameescape("beads://" .. id))
  end))
  map("add_child", with_id(function(id)
    local pw = prev_win(v)
    if not pw then
      return
    end
    vim.api.nvim_set_current_win(pw)
    require("beads.views.detail").create_child(id)
  end))
  map("close_bead", with_id(function(id)
    vim.ui.input({ prompt = "Close reason (optional): " }, function(reason)
      if reason ~= nil then
        in_root(function()
          cli.close(id, reason, after)
        end)
      end
    end)
  end))
  map("claim", with_id(function(id)
    in_root(function()
      cli.claim(id, after)
    end)
  end))
  map("refresh", function()
    store.refresh(v.root)
  end)
  map("toggle_closed", function()
    v.show_closed = not v.show_closed
    render(v)
  end)
  map("yank_id", with_id(function(id)
    vim.fn.setreg('"', id)
  end))
  map("yank_run", with_id(function(id)
    local b = store.get(v.root).by_id[id]
    if b then
      vim.fn.setreg('"', workflow.run_command(b))
    end
  end))
  map("close", function()
    close(tab)
  end)
  keys.bind(v.buf, "tree_view", acts)
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
  v.unsub = store.subscribe(root, function(_, err)
    if views[tab] ~= v then
      return
    end
    v.loaded = true
    v.not_repo = err ~= nil and err:lower():find("no beads project", 1, true) ~= nil
    render(v)
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
