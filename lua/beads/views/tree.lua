-- Tree view (:Beads tree): left vsplit, one per tabpage, parent-child nesting.
local cli = require("beads.cli")
local store = require("beads.store")
local keys = require("beads.keys")

local M = {}

local NS = vim.api.nvim_create_namespace("beads_tree")
local MARK_NS = vim.api.nvim_create_namespace("beads_tree_marked")
local CUR_NS = vim.api.nvim_create_namespace("beads_tree_current")
local current = {} -- { id, buf } of the most recent beads://<id> detail buffer

local views = {} -- tabpage -> { win, buf, root, show_closed, ids, marked (id -> true), unsub, release }

local F = require("beads.ui.format")
local function ordered(list, v)
  return F.sort(list, v and v.sort)
end

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
  local lines, ids, marks, folds = {}, {}, {}, {}
  local seen = {}
  -- filter: matches plus their ancestors stay; ancestors that do not match are dimmed
  local keep, matched
  if v.filter and v.filter ~= "" then
    keep, matched = {}, {}
    for id, b in pairs(st.by_id) do
      if F.matches(b, v.filter) then
        matched[id] = true
        local cur, hops = b, 0
        while cur and not keep[cur.id] and hops < 1000 do
          keep[cur.id] = true
          cur = cur.parent and st.by_id[cur.parent]
          hops = hops + 1
        end
        keep[id] = true
      end
    end
  end
  local function visible(b)
    return (v.show_closed or b.status ~= "closed") and (not keep or keep[b.id] == true)
  end
  -- Visible children of b; hidden children are replaced by their visible descendants.
  local function vis_children(b, stack)
    local out = {}
    for _, c in ipairs(ordered(st.children_of(b.id), v)) do
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
  local function emit(b, depth, cells, last, fold_depth)
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
    local nopen = 0
    for _, c in ipairs(kids) do
      if c.status ~= "closed" then
        nopen = nopen + 1
      end
    end
    folds[row] = { level = fold_depth + (#kids > 0 and 1 or 0), start = #kids > 0, n = #kids, open = nopen }
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
    if matched and not matched[b.id] then
      add_mark(row, #prefix, #prefix + #text, "BeadsDim", DIM_PRI)
    end
    local child_cells = vim.list_slice(cells)
    if depth > 0 then
      child_cells[#child_cells + 1] = last and "  " or "│ "
    end
    for i, c in ipairs(kids) do
      emit(c, depth + 1, child_cells, i == #kids, fold_depth + (#kids > 0 and 1 or 0))
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
  for _, b in ipairs(ordered(roots, v)) do
    if visible(b) then
      top[#top + 1] = b
    else
      stack[b.id] = true
      vim.list_extend(top, vis_children(b, stack))
      stack[b.id] = nil
    end
  end
  for _, b in ipairs(top) do
    emit(b, 0, {}, false, 0)
  end
  return lines, ids, marks, folds
end

-- Bead ids of `root` in the order the tree shows them (depth-first, folds ignored). Uses the open
-- tree's sort, filter and closed visibility for that root; otherwise default sort, no filter, closed hidden.
function M.order(root)
  local v = views[vim.api.nvim_get_current_tabpage()]
  local ids
  if v and v.root == root and v.ids and vim.api.nvim_win_is_valid(v.win) then
    ids = v.ids
  else
    local _
    _, ids = build_lines({ show_closed = false, root = root }, store.get(root))
  end
  local out, last = {}, 0
  for r in pairs(ids) do
    last = math.max(last, r)
  end
  for r = 1, last do
    out[#out + 1] = ids[r]
  end
  return out
end

local function header_text(v, st)
  local open, chat, human = 0, 0, 0
  for _, b in pairs(st.by_id) do
    if b.status == "open" then
      open = open + 1
    end
    if b.status ~= "closed" then
      if b.waiting_user then
        chat = chat + 1
      elseif vim.tbl_contains(b.labels or {}, "human") then
        human = human + 1
      end
    end
  end
  local name = vim.fn.fnamemodify((v.root:gsub("/+$", "")), ":t")
  local need = chat + human
  local head = ("beads · %s · %d open · %d ready · %d need you"):format(name, open, store.get(v.root).ready_n or 0, need)
  if need > 0 then
    head = head .. (" (%d💬 %d👤)"):format(chat, human)
  end
  if v.filter and v.filter ~= "" then
    head = head .. " · filter: " .. v.filter
  end
  return head .. " · sort: " .. (v.sort or "priority")
end

local fold_info = {} -- buf -> row -> { level, start, n, open }

function M.foldexpr(lnum)
  local f = (fold_info[vim.api.nvim_get_current_buf()] or {})[lnum]
  if not f then
    return 0
  end
  return (f.start and ">" or "") .. f.level
end

function M.foldtext()
  local f = (fold_info[vim.api.nvim_get_current_buf()] or {})[vim.v.foldstart]
  local line = vim.fn.getline(vim.v.foldstart):gsub("▾", "▸", 1)
  if not f then
    return line
  end
  return ("%s (%d children, %d open)"):format(line, f.n, f.open)
end

-- Records which fold-start beads are currently closed (by id); nested ones inside a closed fold keep their state.
local function save_folds(v)
  if not (vim.api.nvim_win_is_valid(v.win) and v.fold_rows) then
    return
  end
  vim.api.nvim_win_call(v.win, function()
    for row, id in pairs(v.fold_rows) do
      local fc = vim.fn.foldclosed(row)
      if fc == row then
        v.closed[id] = true
      elseif fc == -1 then
        v.closed[id] = nil
      end
    end
  end)
end

local function restore_folds(v)
  -- deepest folds first, top to bottom within a level (bucketed by level, no sorting)
  local by_level, maxlevel, maxrow = {}, 0, 0
  for row, id in pairs(v.fold_rows) do
    if v.closed[id] then
      local level = fold_info[v.buf][row].level
      by_level[level] = by_level[level] or {}
      by_level[level][row] = true
      maxlevel = math.max(maxlevel, level)
      maxrow = math.max(maxrow, row)
    end
  end
  local todo = {}
  for level = maxlevel, 0, -1 do
    for row = 1, maxrow do
      if by_level[level] and by_level[level][row] then
        todo[#todo + 1] = { row = row, level = level }
      end
    end
  end
  vim.api.nvim_win_call(v.win, function()
    vim.cmd("silent! normal! zR")
    for _, t in ipairs(todo) do
      pcall(vim.cmd, ("silent! %dfoldclose"):format(t.row))
    end
  end)
end

local function row_of_id(v, id)
  for row, rid in pairs(v.ids) do
    if rid == id then
      return row
    end
  end
end

-- Puts the BeadsCurrent line highlight on the current bead's row (none when it is not in the tree).
local function mark_current(v)
  if not vim.api.nvim_buf_is_valid(v.buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(v.buf, CUR_NS, 0, -1)
  local row = current.id and row_of_id(v, current.id)
  if row then
    vim.api.nvim_buf_set_extmark(v.buf, CUR_NS, row - 1, 0, { line_hl_group = "BeadsCurrent", priority = 50 })
  end
end

local apply_layout

-- Opens the ancestor folds of the current bead's row and scrolls it into view; focus is unchanged.
local function reveal(v)
  local row = current.id and row_of_id(v, current.id)
  if not (row and vim.api.nvim_win_is_valid(v.win)) then
    return
  end
  vim.api.nvim_win_call(v.win, function()
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    vim.cmd("silent! normal! zv")
    local top, bot = vim.fn.line("w0"), vim.fn.line("w$")
    if row < top or row > bot then
      vim.cmd("silent! normal! zz")
    end
  end)
  save_folds(v)
  apply_layout(v.win, v.pos, v)
end

local function clamp(n, lo, hi)
  return math.max(lo, math.min(hi, n))
end

-- Sizes the tree window for `pos`: a number in tree.width/height is fixed, "auto" fits the visible content.
-- v.fit records the size the plugin set, so a WinResized with another size is recognised as a manual resize.
function apply_layout(win, pos, v)
  local cfg = require("beads").config.tree or {}
  local horizontal = pos == "left" or pos == "right"
  local setting = horizontal and cfg.width or cfg.height
  if setting == nil then
    setting = "auto"
  end
  local size
  if type(setting) == "number" then
    size = setting
  elseif v and v.manual then
    size = nil
  else
    local rows = vim.api.nvim_win_call(win, function()
      local out, l, last = {}, 1, vim.fn.line("$")
      while l <= last do
        out[#out + 1] = vim.fn.getline(l)
        local e = vim.fn.foldclosedend(l)
        l = (e > 0 and e or l) + 1
      end
      return out
    end)
    if horizontal then
      local m = 0
      for _, line in ipairs(rows) do
        m = math.max(m, vim.fn.strdisplaywidth(line))
      end
      size = clamp(m, 24, cfg.max_width or math.floor(vim.o.columns / 2))
    else
      size = clamp(#rows, 6, cfg.max_height or math.floor(vim.o.lines * 0.4))
    end
  end
  if horizontal then
    vim.wo[win].winfixheight = false
    if size then
      vim.api.nvim_win_set_width(win, size)
    end
    vim.wo[win].winfixwidth = true
  else
    vim.wo[win].winfixwidth = false
    if size then
      vim.api.nvim_win_set_height(win, size)
    end
    vim.wo[win].winfixheight = true
  end
  if v and size then
    v.fit = horizontal and vim.api.nvim_win_get_width(win) or vim.api.nvim_win_get_height(win)
  end
end

-- Puts the ▍ marker (virtual text, buffer text unchanged) on the rows of marked beads.
local function paint_marks(v)
  if not vim.api.nvim_buf_is_valid(v.buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(v.buf, MARK_NS, 0, -1)
  for row, id in pairs(v.ids) do
    if v.marked and v.marked[id] then
      vim.api.nvim_buf_set_extmark(v.buf, MARK_NS, row - 1, 0, {
        virt_text = { { "▍", "BeadsMarked" } },
        virt_text_pos = "inline",
        priority = 150,
      })
    end
  end
end

local function render(v)
  if not vim.api.nvim_buf_is_valid(v.buf) then
    return
  end
  local cur_id
  if vim.api.nvim_win_is_valid(v.win) then
    cur_id = v.ids[vim.api.nvim_win_get_cursor(v.win)[1]]
  end
  save_folds(v)
  local st = store.get(v.root)
  local lines, ids, marks, folds = build_lines(v, st)
  if v.not_repo then
    lines, ids, marks, folds = { "Not a beads repo — run bd init" }, {}, {}, {}
  elseif v.loaded then
    local head = { header_text(v, st) }
    if next(st.by_id) == nil then
      head[2] = "No beads here — " .. create_key() .. " to create"
    end
    local n = #head
    local nl, ni, nm, nf = vim.list_extend(head, lines), {}, {}, {}
    for row, id in pairs(ids) do
      ni[row + n] = id
    end
    for row, f in pairs(folds) do
      nf[row + n] = f
    end
    folds = nf
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
  fold_info[v.buf] = folds
  v.fold_rows = {}
  for row, f in pairs(folds) do
    if f.start then
      v.fold_rows[row] = ids[row]
    end
  end
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
  if vim.api.nvim_win_is_valid(v.win) then
    restore_folds(v)
  end
  if cur_id and vim.api.nvim_win_is_valid(v.win) then
    for row, id in pairs(ids) do
      if id == cur_id then
        vim.api.nvim_win_set_cursor(v.win, { row, 0 })
        break
      end
    end
  end
  mark_current(v)
  paint_marks(v)
  if vim.api.nvim_win_is_valid(v.win) then
    apply_layout(v.win, v.pos, v)
  end
end

-- Tracks the most recent beads://<id> buffer: moves the tree highlight and reveals it on BufEnter.
function M.setup_current()
  local group = vim.api.nvim_create_augroup("BeadsTreeCurrent", { clear = true })
  local function each(fn)
    for _, v in pairs(views) do
      if vim.api.nvim_win_is_valid(v.win) then
        fn(v)
      end
    end
  end
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    pattern = "beads://*",
    callback = function(args)
      local id = vim.api.nvim_buf_get_name(args.buf):gsub("^beads://", "")
      current = { id = id, buf = args.buf }
      each(function(v)
        mark_current(v)
        reveal(v)
      end)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    pattern = "beads://*",
    callback = function(args)
      if current.buf == args.buf then
        current = {}
        each(mark_current)
      end
    end,
  })
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
  local function row_ids(first, last)
    local out = {}
    for r = first, last do
      if v.ids[r] then
        out[#out + 1] = v.ids[r]
      end
    end
    return out
  end
  -- Target beads: marks (tree order), else the visual line range, else the cursor bead.
  local function targets()
    local in_visual = vim.fn.mode():match("^[vV\22]") ~= nil
    local first, last = vim.fn.line("v"), vim.fn.line(".")
    if in_visual then
      vim.cmd("normal! \27")
    end
    local out, seen = {}, {}
    for r = 1, vim.api.nvim_buf_line_count(v.buf) do
      local id = v.ids[r]
      if id and v.marked[id] and not seen[id] then
        out[#out + 1] = id
        seen[id] = true
      end
    end
    local hidden = 0
    for id in pairs(v.marked) do
      if not seen[id] then
        hidden = hidden + 1
      end
    end
    if hidden > 0 then
      vim.notify("Beads: skipped " .. hidden .. " hidden mark" .. (hidden == 1 and "" or "s"))
    end
    if #out > 0 then
      return out
    end
    if in_visual then
      return row_ids(math.min(first, last), math.max(first, last))
    end
    return row_ids(last, last)
  end
  local G = require("beads.group_actions").new(function()
    return v.root
  end, function(ids, failed)
    local bad = {}
    for _, id in ipairs(failed) do
      bad[id] = true
    end
    for _, id in ipairs(ids) do
      if not bad[id] then
        v.marked[id] = nil
      end
    end
    paint_marks(v)
  end)
  local function act(op, given)
    return G.act(op, given or targets())
  end
  local function yank(what, given)
    return G.yank(what, given or targets())
  end
  map("open", with_id(function(id)
    local pw = prev_win(v)
    if not pw then
      return
    end
    vim.api.nvim_set_current_win(pw)
    require("beads.views.detail").edit(id, v.root)
    require("beads.flash").flash()
  end))
  map("add_child", with_id(function(id)
    local pw = prev_win(v)
    if not pw then
      return
    end
    vim.api.nvim_set_current_win(pw)
    require("beads.views.detail").create_child(id, v.root)
  end))
  map("close_bead", function()
    act("close")
  end)
  map("claim", function()
    act("claim")
  end)
  map("mark", function()
    local r = vim.api.nvim_win_get_cursor(0)[1]
    local last = vim.api.nvim_buf_line_count(v.buf)
    for _ = 1, vim.v.count1 do
      if r > last then
        break
      end
      local id = v.ids[r]
      if id then
        v.marked[id] = (not v.marked[id]) or nil
      end
      local fe = vim.fn.foldclosedend(r)
      r = (fe > r and fe or r) + 1
    end
    paint_marks(v)
  end)
  map("clear_marks", function()
    v.marked = {}
    paint_marks(v)
  end)
  map("actions", function()
    G.menu(targets())
  end)
  map("refresh", function()
    store.refresh(v.root)
  end)
  map("toggle_closed", function()
    v.show_closed = not v.show_closed
    render(v)
  end)
  map("filter", function()
    vim.ui.input({ prompt = "Filter (text, status: label: assignee: type:): ", default = v.filter or "" }, function(text)
      if text == nil then
        return
      end
      text = vim.trim(text)
      v.filter = text ~= "" and text or nil
      render(v)
    end)
  end)
  map("sort", function()
    local idx = 1
    for i, name in ipairs(F.SORTS) do
      if name == (v.sort or "priority") then
        idx = i
      end
    end
    v.sort = F.SORTS[idx % #F.SORTS + 1]
    render(v)
  end)
  map("fold", function()
    vim.cmd("silent! normal! za")
    apply_layout(v.win, v.pos, v)
  end)
  map("yank_id", function()
    yank("id")
  end)
  map("yank_run", function()
    yank("run")
  end)
  map("peek", function()
    require("beads.views.peek").at_cursor(v.root)
  end)
  map("layout", function()
    M.cycle(tab)
  end)
  map("close", function()
    close(tab)
  end)
  keys.bind(v.buf, "tree_view", acts, { close_bead = { "n", "x" }, claim = { "n", "x" }, actions = { "n", "x" }, yank_id = { "n", "x" }, yank_run = { "n", "x" } })
  local bound = {}
  for _, k in ipairs(keys.resolve("tree_view")) do
    for _, l in ipairs(k[2]) do
      bound[l] = true
    end
  end
  for _, z in ipairs(require("beads").config.keymaps ~= false and { "zc", "zo", "za", "zA", "zC", "zO", "zM", "zR" } or {}) do
    if not bound[z] then
    vim.keymap.set("n", z, function()
      local n = vim.v.count > 0 and tostring(vim.v.count) or ""
      vim.cmd("silent! normal! " .. n .. z)
      apply_layout(v.win, v.pos, v)
    end, { buffer = v.buf, silent = true, desc = "Beads tree: fold " .. z })
    end
  end
  local cfg = require("beads").config
  if cfg.mouse ~= false and cfg.keymaps ~= false then
    local function default_click(double)
      vim.api.nvim_feedkeys(vim.keycode(double and "<2-LeftMouse>" or "<LeftMouse>"), "n", false)
    end
    local function mouse(double)
      return function()
        local mp = vim.fn.getmousepos()
        if mp.winid ~= v.win or mp.line < 1 or not v.ids[mp.line] then
          return default_click(double)
        end
        vim.api.nvim_set_current_win(v.win)
        pcall(vim.api.nvim_win_set_cursor, v.win, { mp.line, math.max(0, mp.column - 1) })
        local id = v.ids[mp.line]
        if double then
          acts.open()
          return
        end
        local line = vim.api.nvim_buf_get_lines(v.buf, mp.line - 1, mp.line, false)[1] or ""
        local info = vim.fn.getwininfo(v.win)[1]
        local dcol = mp.wincol - info.textoff - 1
        local mi = line:find("▾", 1, true) or line:find("▸", 1, true)
        if mi and dcol == vim.fn.strdisplaywidth(line:sub(1, mi - 1)) then
          vim.cmd("silent! normal! za")
    apply_layout(v.win, v.pos, v)
          return
        end
        local b = store.get(v.root).by_id[id]
        local ti = b and b.title and line:find(b.title, 1, true)
        if ti and mp.column >= ti and mp.column < ti + #b.title then
          acts.open()
        end
      end
    end
    vim.keymap.set("n", "<LeftMouse>", mouse(false), { buffer = v.buf, silent = true, desc = "Beads tree: click" })
    vim.keymap.set("n", "<2-LeftMouse>", mouse(true), { buffer = v.buf, silent = true, desc = "Beads tree: open" })
  end
end

local POSITIONS = { "left", "bottom", "right", "top" } -- the L cycle order
local last_position -- remembered for the session

local SPLIT = { left = "topleft vsplit", right = "botright vsplit", bottom = "botright split", top = "topleft split" }
local WINCMD = { left = "H", right = "L", bottom = "J", top = "K" }

local function open(pos)
  local tab = vim.api.nvim_get_current_tabpage()
  local root = cli.get_root()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "beads-tree"
  vim.cmd(SPLIT[pos])
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldmethod = "expr"
  vim.wo[win].foldexpr = "v:lua.require'beads.views.tree'.foldexpr(v:lnum)"
  vim.wo[win].foldtext = "v:lua.require'beads.views.tree'.foldtext()"
  vim.wo[win].foldlevel = 99
  vim.bo[buf].shiftwidth = 2
  local v = { win = win, buf = buf, pos = pos, root = root, show_closed = false, ids = {}, closed = {}, marked = {} }
  views[tab] = v
  apply_layout(win, pos, v)
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
      fold_info[buf] = nil
      if views[tab] == v then
        views[tab] = nil
        v.unsub()
        v.release()
      end
    end,
  })
  local sg = vim.api.nvim_create_augroup("BeadsTreeFit" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = sg,
    callback = function()
      if views[tab] ~= v or not vim.api.nvim_win_is_valid(v.win) then
        return true
      end
      apply_layout(v.win, v.pos, v)
    end,
  })
  vim.api.nvim_create_autocmd("WinResized", {
    group = sg,
    callback = function()
      if views[tab] ~= v or not vim.api.nvim_win_is_valid(v.win) then
        return true
      end
      local horizontal = v.pos == "left" or v.pos == "right"
      local now = horizontal and vim.api.nvim_win_get_width(v.win) or vim.api.nvim_win_get_height(v.win)
      if v.fit and now ~= v.fit then
        v.manual = true
      end
    end,
  })
  render(v)
  store.refresh(root)
end

local function resolve(pos)
  if pos and not vim.tbl_contains(POSITIONS, pos) then
    vim.notify("Beads: tree position must be left, right, bottom or top", vim.log.levels.ERROR)
    return nil
  end
  return pos or last_position or (require("beads").config.tree or {}).position or "left"
end

-- Moves the open tree window of `tab` to `pos`, keeping window, buffer, folds, cursor and watcher.
local function move(v, pos)
  if v.pos ~= pos then
    vim.api.nvim_win_call(v.win, function()
      vim.cmd("wincmd " .. WINCMD[pos])
    end)
    v.pos = pos
  end
  v.manual = false
  apply_layout(v.win, pos, v)
end

-- M.toggle(): toggle, opening at the last / configured position.
-- M.toggle(pos): open the tree at pos, or move an open tree there.
function M.toggle(pos)
  local tab = vim.api.nvim_get_current_tabpage()
  local v = views[tab]
  local live = v and vim.api.nvim_win_is_valid(v.win)
  if pos == nil and live then
    close(tab)
    return
  end
  pos = resolve(pos)
  if not pos then
    return
  end
  last_position = pos
  if live then
    move(v, pos)
    return
  end
  if v then
    close(tab)
  end
  open(pos)
end

function M.cycle(tab)
  local v = views[tab]
  if not (v and vim.api.nvim_win_is_valid(v.win)) then
    return
  end
  local idx = 1
  for i, p in ipairs(POSITIONS) do
    if p == v.pos then
      idx = i
    end
  end
  M.toggle(POSITIONS[idx % #POSITIONS + 1])
end

return M
