-- gd peek: stacked, read-only floating detail views of the bead id under the cursor.
local cli = require("beads.cli")
local model = require("beads.model")
local render = require("beads.buffer.render")
local workflow = require("beads.workflow")
local keys = require("beads.keys")
local store = require("beads.store")

local M = {}

local stack = {} -- { win, buf, id, root, bead, unsub }
local origin -- window gd was first pressed in
local release -- watcher hold, taken while any float is open
local closing_all = false

local function valid(w)
  return w and vim.api.nvim_win_is_valid(w)
end

-- The existing bead whose id is the word under the cursor (nil: not a bead id).
local function bead_at_cursor(root)
  local pos = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  local col = pos[2] + 1
  local by_id = store.get(root).by_id
  for s, tok, e in line:gmatch("()([%w_%-%.]+)()") do
    if col >= s and col < e then
      tok = tok:gsub("^[%-%.]+", ""):gsub("[%-%.]+$", "")
      if by_id[tok] then
        return tok
      end
    end
  end
end

local function fallback()
  vim.api.nvim_feedkeys("gd", "n", false)
end

local function geometry(n, lines)
  local width = 20
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.max(40, width + 1)
  local row, col = 1 + 2 * (n - 1), 3 + 4 * (n - 1)
  width = math.min(width, math.floor(vim.o.columns * 0.8), vim.o.columns - col - 3)
  local height = math.min(#lines, math.floor(vim.o.lines * 0.8), vim.o.lines - row - 4)
  return { width = math.max(10, width), height = math.max(3, height), row = row, col = col }
end

local function paint(e, bead)
  if not (vim.api.nvim_buf_is_valid(e.buf) and valid(e.win)) then
    return
  end
  e.bead = bead
  local lines, regions = render.render(bead)
  vim.bo[e.buf].modifiable = true
  vim.api.nvim_buf_set_lines(e.buf, 0, -1, false, lines)
  vim.bo[e.buf].modifiable = false
  vim.bo[e.buf].modified = false
  require("beads.views.detail").decorate(e.buf, bead, lines, regions)
  local g = geometry(e.n, lines)
  vim.api.nvim_win_set_config(e.win, { relative = "editor", width = g.width, height = g.height, row = g.row, col = g.col })
end

local function fetch(e)
  local prev = cli.get_root_override()
  cli.set_root(e.root)
  cli.show(e.id, function(res)
    if res.err or not vim.api.nvim_buf_is_valid(e.buf) then
      return
    end
    local item = type(res.data) == "table" and (res.data[1] or res.data) or nil
    if not item or not item.id then
      return
    end
    local bead = model.normalize(item)
    require("beads.views.detail").gather(e.root, bead.id, function(threads)
      if not vim.api.nvim_buf_is_valid(e.buf) then
        return
      end
      bead.threads = threads
      paint(e, bead)
    end)
  end, { include_comments = true })
  cli.set_root(prev)
end

local function top()
  return stack[#stack]
end

local function focus_after()
  local t = top()
  if t and valid(t.win) then
    vim.api.nvim_set_current_win(t.win)
  elseif valid(origin) then
    vim.api.nvim_set_current_win(origin)
  end
end

local function forget(win)
  for i, e in ipairs(stack) do
    if e.win == win then
      table.remove(stack, i)
      if e.unsub then
        e.unsub()
      end
      break
    end
  end
  if #stack == 0 then
    if release then
      local r = release
      release = nil
      r()
    end
    if not closing_all then
      origin = nil
    end
  end
end

function M.close_top()
  local e = top()
  if not e then
    return
  end
  if valid(e.win) then
    pcall(vim.api.nvim_win_close, e.win, true)
  end
  forget(e.win)
  focus_after()
end

function M.close_all()
  closing_all = true
  for i = #stack, 1, -1 do
    local e = stack[i]
    if valid(e.win) then
      pcall(vim.api.nvim_win_close, e.win, true)
    end
    forget(e.win)
  end
  closing_all = false
  local o = origin
  origin = nil
  if valid(o) then
    vim.api.nvim_set_current_win(o)
  end
end

local function main_win()
  local function ok(w)
    return valid(w)
      and vim.api.nvim_win_get_config(w).relative == ""
      and vim.bo[vim.api.nvim_win_get_buf(w)].filetype ~= "beads-tree"
  end
  if ok(origin) then
    return origin
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if ok(w) then
      return w
    end
  end
end

local function open_in_main(e)
  local id, root = e.id, e.root
  local main = main_win()
  M.close_all()
  if not main then
    vim.cmd("topleft vsplit")
    main = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_set_current_win(main)
  require("beads.views.detail").edit(id, root)
end

local function bind(e)
  local function cur()
    return e.bead or store.get(e.root).by_id[e.id]
  end
  keys.bind(e.buf, "peek", {
    peek = function()
      M.at_cursor(e.root)
    end,
    close = M.close_top,
    close_all = M.close_all,
    open = function()
      open_in_main(e)
    end,
    yank_id = function()
      workflow.yank(e.id)
    end,
    yank_run = function()
      local b = cur()
      if b then
        workflow.yank(workflow.run_command(b))
      end
    end,
  })
end

local function open(id, root)
  for _, e in ipairs(stack) do
    if e.id == id and e.root == root and valid(e.win) then
      vim.api.nvim_set_current_win(e.win)
      return
    end
  end
  local bead = store.get(root).by_id[id]
  if not bead then
    return fallback()
  end
  if #stack == 0 then
    origin = vim.api.nvim_get_current_win()
    release = require("beads.watch").acquire(root)
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  local lines = render.render(bead)
  local n = #stack + 1
  local g = geometry(n, lines)
  g.relative = "editor"
  g.style = "minimal"
  g.border = "rounded"
  g.title = " " .. id .. " "
  local win = vim.api.nvim_open_win(buf, true, g)
  vim.wo[win].wrap = true
  local e = { win = win, buf = buf, id = id, root = root, n = n }
  stack[n] = e
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      forget(win)
      vim.schedule(function()
        if not closing_all then
          focus_after()
        end
      end)
    end,
  })
  e.unsub = store.subscribe(root, function(st)
    local cur = st.by_id[id]
    if cur and e.bead and cur.updated_at ~= e.bead.updated_at then
      fetch(e)
    end
  end)
  bind(e)
  paint(e, bead)
  fetch(e)
end

-- gd: peeks the bead id under the cursor, or runs Vim's own gd.
function M.at_cursor(root)
  root = root or cli.get_root()
  local id = bead_at_cursor(root)
  if not id then
    return fallback()
  end
  open(id, root)
end

return M
