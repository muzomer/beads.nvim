-- Detail buffer beads://<id>: load, render, buffer-local keys.
local cli = require("beads.cli")
local model = require("beads.model")
local render = require("beads.buffer.render")
local workflow = require("beads.workflow")
local keys = require("beads.keys")

local M = {}

local ns = vim.api.nvim_create_namespace("beads_detail")
local state = {} -- buf -> { bead, root }

require("beads.highlights").apply()

function M.snapshot(buf)
  return state[buf] and state[buf].bead
end

-- True when buf is a read-only peek float's buffer.
function M.is_float(buf)
  return state[buf] ~= nil and state[buf].reload ~= nil
end

function M.root(buf)
  return state[buf] and state[buf].root or cli.get_root()
end

local function bead_id(buf)
  return (vim.api.nvim_buf_get_name(buf):gsub("^beads://", ""))
end

local function view_actions(buf)
  local acts = {}
  local function map(_, name, fn)
    acts[name] = fn
  end
  local function with_bead(fn)
    return function()
      local b = M.snapshot(buf)
      if b then
        fn(b)
      end
    end
  end
  local function after(root)
    return function(res)
      if res.err then
        vim.notify("Beads: " .. res.err, vim.log.levels.ERROR)
      end
      require("beads.store").mark_self_write(root)
      require("beads.store").refresh(root)
      if vim.api.nvim_buf_is_valid(buf) then
        if state[buf] and state[buf].reload then
          state[buf].reload() -- a peek float repaints itself
        else
          M.load(buf)
        end
      end
    end
  end
  map(buf, "close_bead", with_bead(function(b)
    local root = M.root(buf)
    vim.ui.input({ prompt = "Close reason (optional): " }, function(reason)
      if reason == nil then
        return
      end
      local prev = cli.get_root_override()
      cli.set_root(root)
      cli.close(b.id, reason, after(root))
      cli.set_root(prev)
    end)
  end))
  map(buf, "claim", with_bead(function(b)
    local root = M.root(buf)
    local prev = cli.get_root_override()
    cli.set_root(root)
    cli.claim(b.id, after(root))
    cli.set_root(prev)
  end))
  local function text_float(title, send)
    return function()
      local b = M.snapshot(buf)
      if not b then
        return
      end
      local root = M.root(buf)
      local fbuf = vim.api.nvim_create_buf(false, true)
      vim.bo[fbuf].buftype = "acwrite"
      vim.bo[fbuf].bufhidden = "wipe"
      vim.bo[fbuf].filetype = "markdown"
      vim.api.nvim_buf_set_name(fbuf, "beads-float:" .. title .. ":" .. b.id .. ":" .. fbuf)
      local width = math.min(70, math.max(20, vim.o.columns - 4))
      local win = vim.api.nvim_open_win(fbuf, true, {
        relative = "editor",
        width = width,
        height = 8,
        row = math.max(0, math.floor((vim.o.lines - 8) / 2)),
        col = math.max(0, math.floor((vim.o.columns - width) / 2)),
        style = "minimal",
        border = "rounded",
        title = string.format(
          " %s (%s confirm, %s cancel) ",
          title,
          keys.first("input", "submit") or "",
          keys.first("input", "cancel") or ""
        ),
      })
      local function close()
        if vim.api.nvim_win_is_valid(win) then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
      local function confirm()
        local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false), "\n"))
        vim.bo[fbuf].modified = false
        close()
        if text == "" then
          return
        end
        local prev = cli.get_root_override()
        cli.set_root(root)
        send(b.id, text, after(root))
        cli.set_root(prev)
      end
      vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = fbuf, callback = confirm })
      keys.bind_input(fbuf, confirm, close)
      vim.cmd("startinsert")
    end
  end
  map(buf, "note", text_float("Note", cli.append_note))
  map(buf, "comment", text_float("Comment", cli.comment))
  map(buf, "yank_id", with_bead(function(b)
    workflow.yank(b.id)
  end))
  map(buf, "yank_run", with_bead(function(b)
    workflow.yank(workflow.run_command(b))
  end))
  acts.peek = function()
    require("beads.views.peek").at_cursor(M.root(buf))
  end
  acts.details = function()
    require("beads.views.peek").at_cursor(M.root(buf), true)
  end
  acts.open_thread = function()
    local idx = M.thread_at(buf, vim.api.nvim_win_get_cursor(0)[1])
    if idx then
      require("beads.views.thread").open(buf, idx)
    end
  end
  local function jump(dir)
    return function()
      local st = state[buf]
      local h = M.questions_heading(buf)
      if not (st and st.bead and st.bead.threads and h) then
        return
      end
      local row = vim.api.nvim_win_get_cursor(0)[1]
      local target
      for k, t in ipairs(st.bead.threads) do
        local l = h + k
        if t.needs == "user" then
          if dir > 0 and l > row and (not target or l < target) then
            target = l
          elseif dir < 0 and l < row and (not target or l > target) then
            target = l
          end
        end
      end
      if target then
        vim.api.nvim_win_set_cursor(0, { target, 0 })
      end
    end
  end
  acts.next_waiting = jump(1)
  acts.prev_waiting = jump(-1)
  local function step(dir)
    local function go(st, count)
      local order = require("beads.views.tree").order(st.root)
      local idx
      for i, id in ipairs(order) do
        if id == st.bead.id then
          idx = i
        end
      end
      local target = idx and order[idx + dir * math.max(count, 1)]
      if not target then
        if dir > 0 then
          vim.notify("Beads: no next bead", vim.log.levels.INFO)
        else
          vim.notify("Beads: no previous bead", vim.log.levels.INFO)
        end
        return
      end
      M.edit(target, st.root)
      -- flash once the new bead has loaded (the load replaces the buffer lines asynchronously)
      local win, nbuf, tries = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf(), 0
      local function flash_when_loaded()
        tries = tries + 1
        if not (vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == nbuf) then
          return
        end
        local loaded = state[nbuf] and state[nbuf].bead and state[nbuf].bead.id == target
        if loaded or tries > 100 then
          require("beads.flash").flash(win)
        else
          vim.defer_fn(flash_when_loaded, 20)
        end
      end
      flash_when_loaded()
    end
    return function()
      local st = state[buf]
      if not (st and st.bead) then
        return
      end
      local store = require("beads.store")
      if store.is_loaded(st.root) then
        go(st, vim.v.count1)
        return
      end
      local n = vim.v.count1
      store.refresh(st.root, function()
        if state[buf] == st and vim.api.nvim_buf_is_valid(buf) then
          go(st, n)
        end
      end)
    end
  end
  acts.next_bead = step(1)
  acts.prev_bead = step(-1)
  acts.edit = function()
    M.enter_edit(buf)
  end
  acts.ask = function()
    M.ask(buf)
  end
  acts.close = function()
    pcall(vim.cmd, "close")
  end
  return acts
end

-- The detail view's actions for a peek float buffer; `st` ({ root, bead, reload }) is its state:
-- actions read st.bead / st.root and call st.reload(cb) to repaint after a change.
function M.attach_float(buf, st)
  state[buf] = st
  return view_actions(buf)
end

function M.detach_float(buf)
  state[buf] = nil
end

local attach_winbar

local bound = {} -- buf -> list of { mode, lhs } set for the current mode

local function edit_actions(buf)
  return {
    save = function()
      vim.cmd("stopinsert")
      vim.cmd("write")
    end,
    view = function()
      if not vim.bo[buf].modified then
        return M.enter_view(buf)
      end
      local choices = { "Discard unsaved edits", "Keep editing" }
      vim.ui.select(choices, { prompt = "Beads: unsaved edits" }, function(choice)
        if choice == choices[1] and vim.api.nvim_buf_is_valid(buf) then
          M.enter_view(buf)
          vim.bo[buf].modified = false
          M.load(buf)
        end
      end)
    end,
  }
end

local function set_mode(buf, mode)
  keys.unbind(buf, bound[buf])
  vim.b[buf].beads_mode = mode
  attach_winbar(buf)
  vim.bo[buf].modifiable = mode == "edit"
  if mode == "view" then
    bound[buf] = keys.bind(buf, "detail_view", view_actions(buf), { ask = { "n", "x" } })
  else
    local acts = edit_actions(buf)
    if state[buf] and state[buf].new then
      acts.view = nil
    end
    bound[buf] = keys.bind(buf, "detail_edit", acts, { save = { "n", "i" } })
  end
end

function M.enter_edit(buf)
  if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].beads_mode ~= "edit" then
    set_mode(buf, "edit")
  end
end

function M.enter_view(buf)
  if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].beads_mode ~= "view" then
    set_mode(buf, "view")
  end
end

local apply

local ASK_SECTIONS = { description = true, design = true, acceptance = true, workflow = true, notes = true, comments = true, questions = true }

-- Section name of buffer line `row`: the nearest "## X" heading above it, "title" on the "# " line.
local function section_at(buf, row)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, row, false)
  for i = #lines, 1, -1 do
    local name = lines[i]:match("^## (%a+)")
    if name and ASK_SECTIONS[name:lower()] then
      return name:lower()
    end
    if lines[i]:match("^# ") then
      return "title"
    end
  end
  return "frontmatter"
end

local function titled(root, id)
  local b = require("beads.store").get(root).by_id[id]
  return b and b.title and (id .. " - " .. b.title) or id
end

local function build_prompt(root, bead, thread, lines)
  local out = {
    "A question about bead " .. bead.id .. " (" .. (bead.title or "") .. ") needs your answer.",
    "",
    "Section: " .. thread.section,
  }
  if thread.quote then
    out[#out + 1] = "Quote: " .. thread.quote
  end
  out[#out + 1] = "Thread: " .. thread.id
  if bead.parent and bead.parent ~= "" then
    out[#out + 1] = "Parent: " .. titled(root, bead.parent)
  end
  for _, id in ipairs(bead.blocked_by or {}) do
    out[#out + 1] = "Blocked by: " .. titled(root, id)
  end
  vim.list_extend(out, { "", "Question:", thread.messages[1].body, "", "The bead as rendered:", "" })
  vim.list_extend(out, lines)
  vim.list_extend(out, {
    "",
    "Answer with the beads-ask CLI (the thread id is " .. thread.id .. "):",
    "  beads-ask reply " .. thread.id .. " <body|->",
    "  beads-ask propose " .. thread.id .. " --field <title|description|design|acceptance> <value|->",
  })
  return table.concat(out, "\n")
end

-- Asks a question about the section under the cursor, or the visual selection (becomes the quote).
function M.ask(buf)
  local st = state[buf]
  if not (st and st.bead) then
    return
  end
  local root, bead = st.root, st.bead
  local quote, row
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local a, b = vim.fn.getpos("v"), vim.fn.getpos(".")
    quote = table.concat(vim.fn.getregion(a, b, { type = mode }), "\n")
    row = math.min(a[2], b[2])
    vim.cmd("normal! \27")
    if quote == "" then
      quote = nil
    end
  else
    row = vim.api.nvim_win_get_cursor(0)[1]
  end
  local section = section_at(buf, row)
  local title = "Ask " .. bead.id
  if quote then
    local q = vim.split(quote, "\n", { plain = true })[1]
    title = title .. ' "' .. (#q > 40 and q:sub(1, 40) .. "..." or q) .. '"'
  elseif section then
    title = title .. " (" .. section .. ")"
  end
  require("beads.views.input").open({
    title = title,
    on_submit = function(text, send)
      local ok, thread = pcall(require("beads.questions.store").add, root, {
        bead = bead.id,
        section = section,
        quote = quote,
        messages = { { author = "user", body = text } },
      })
      if not ok or not thread then
        vim.notify("Beads: could not store the question: " .. tostring(thread), vim.log.levels.ERROR)
        return
      end
      if send then
        local lines = vim.api.nvim_buf_is_valid(buf) and (render.render(bead)) or {}
        workflow.deliver(root, build_prompt(root, bead, thread, lines), "question stored.", {
          bead = bead.id,
          thread = thread.id,
          base_n = #(thread.messages or {}),
        })
      end
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      M.refresh_threads(buf, function()
        local cfg = require("beads").config.ask or {}
        if cfg.open_after_send == false then
          return
        end
        local cur = state[buf]
        for i, t in ipairs(cur and cur.bead and cur.bead.threads or {}) do
          if t.id == thread.id then
            return require("beads.views.thread").open(buf, i)
          end
        end
      end)
    end,
  })
end

-- Re-reads the threads of every open detail buffer of `root` (a questions.json change).
function M.refresh_root_threads(root)
  for buf, st in pairs(state) do
    if st.root == root and st.bead and vim.api.nvim_buf_is_valid(buf) then
      M.refresh_threads(buf)
    end
  end
end

-- Line number of the "## Questions" heading in the buffer, or nil.
function M.questions_heading(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i = #lines, 1, -1 do
    if lines[i] == "## Questions" then
      return i
    end
  end
end

-- Index of the snapshot thread shown on buffer line `row`, or nil.
function M.thread_at(buf, row)
  local st = state[buf]
  local h = M.questions_heading(buf)
  if not (st and st.bead and st.bead.threads and h) then
    return nil
  end
  local k = row - h
  return st.bead.threads[k] and k or nil
end

-- Threads of bead `id`: stored ones plus the async human ones; cb(threads).
function M.gather(root, id, cb)
  local ok, threads = pcall(require("beads.questions.store").list, root, { bead = id })
  threads = ok and threads or {}
  require("beads.questions.human").list(root, function(res)
    for _, t in ipairs(res.data or {}) do
      if t.bead == id then
        threads[#threads + 1] = t
      end
    end
    cb(threads)
  end)
end

-- Re-reads the threads and updates the Questions section in place, keeping unsaved edits.
function M.refresh_threads(buf, cb)
  local st = state[buf]
  if not (st and st.bead) then
    return
  end
  if st.reload then
    return st.reload(cb)
  end
  M.gather(st.root, st.bead.id, function(threads)
    local cur = state[buf]
    if not (vim.api.nvim_buf_is_valid(buf) and cur and cur.bead) then
      return
    end
    if not vim.bo[buf].modified then
      local b = cur.bead
      b.threads = threads
      apply(buf, b)
    else
      cur.bead.threads = threads
      local lines, regions = render.render(cur.bead)
      local tail = {}
      for _, r in ipairs(regions) do
        if r.name == "questions" then
          tail = vim.list_slice(lines, r.first, r.last)
        end
      end
      local h = M.questions_heading(buf)
      local from = h and h - 1 or vim.api.nvim_buf_line_count(buf)
      local was = vim.bo[buf].modifiable
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, from, -1, false, tail)
      vim.bo[buf].modifiable = was
      for row = from, from + #tail - 1 do
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = "BeadsDim" })
      end
    end
    vim.api.nvim_exec_autocmds("User", { pattern = "BeadsThreadsRefreshed", data = buf, modeline = false })
    if cb then
      cb()
    end
  end)
end

local FRONT = { status = true, priority = true, type = true, assignee = true, parent = true }
local SECTION = { description = "Description", design = "Design", acceptance = "Acceptance" }

-- Writes a proposed field value into the buffer as an unsaved edit and switches to EDIT mode.
-- Returns an error string when the field cannot be applied.
function M.apply_field(buf, field, value)
  if not vim.api.nvim_buf_is_valid(buf) then
    return "buffer is gone"
  end
  if state[buf] and state[buf].reload then
    return "a peek float is read-only; open the bead in the main window"
  end
  value = tostring(value)
  if field == "title" or FRONT[field] then
    value = value:gsub("%s*\n%s*", " ")
  end
  M.enter_edit(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if field == "title" then
    for i, l in ipairs(lines) do
      if l:match("^# ") then
        vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { "# " .. value })
        return nil
      end
    end
  elseif FRONT[field] then
    for i = 2, #lines do
      if lines[i] == "---" then
        break
      end
      if lines[i]:match("^" .. field .. ":") then
        vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { field .. ": " .. value })
        return nil
      end
    end
  elseif SECTION[field] then
    local heads = { "## Description", "## Design", "## Acceptance", "## Workflow" }
    for i, l in ipairs(lines) do
      if l == "## " .. SECTION[field] then
        local stop = #lines + 1
        for j = i + 1, #lines do
          if vim.tbl_contains(heads, lines[j]) then
            stop = j
            break
          end
        end
        local new = vim.split(value, "\n", { plain = true })
        new[#new + 1] = ""
        vim.api.nvim_buf_set_lines(buf, i, stop - 1, false, new)
        return nil
      end
    end
  else
    return "cannot apply a proposal for field '" .. tostring(field) .. "'"
  end
  return "field '" .. field .. "' not found in the buffer"
end

local function ts_seconds(iso)
  local y, mo, d, h, mi, sec = tostring(iso):match("^(%d+)-(%d+)-(%d+)[T ](%d+):(%d+):?(%d*)")
  if not y then
    return nil
  end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  if mo <= 2 then
    y = y - 1
  end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (mo + (mo > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  return days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + (tonumber(sec) or 0)
end

-- "2h ago" style text for an ISO timestamp, relative to the injectable clock (setup({ now = fn })).
function M.relative(iso)
  local t = ts_seconds(iso)
  if not t then
    return nil
  end
  local now_fn = require("beads").config.now
  local diff = (type(now_fn) == "function" and now_fn() or os.time()) - t
  if diff < 60 then
    return "just now"
  elseif diff < 3600 then
    return math.floor(diff / 60) .. "m ago"
  elseif diff < 86400 then
    return math.floor(diff / 3600) .. "h ago"
  end
  return math.floor(diff / 86400) .. "d ago"
end

local function cap(s)
  return (s:gsub("_(%a)", function(c)
    return c:upper()
  end):gsub("^%a", string.upper))
end

local function highlight_values(buf, lines, bead)
  local function mark(row, word_from, group)
    local line = lines[row + 1]
    local s, e = line:find("%S.*%S", word_from)
    if not s then
      s, e = line:find("%S", word_from)
    end
    if s then
      vim.api.nvim_buf_set_extmark(buf, ns, row, s - 1, { end_col = e, hl_group = group })
    end
  end
  local function each_item(row, from, group)
    local line = lines[row + 1]
    local br = line:match("^[^%[]*%[()")
    if not br then
      return
    end
    for pos, item in line:gmatch("()([^,%[%]%s][^,%[%]]*)") do
      if pos >= br then
        item = item:gsub("%s+$", "")
        vim.api.nvim_buf_set_extmark(buf, ns, row, pos - 1, { end_col = pos - 1 + #item, hl_group = group })
      end
    end
  end
  for i = 2, #lines do
    if lines[i] == "---" then
      break
    end
    local row, key = i - 1, lines[i]:match("^([%w_]+):")
    if key then
      local from = #key + 2
      if key == "id" or key == "parent" then
        mark(row, from, "BeadsId")
      elseif key == "status" and bead.status then
        mark(row, from, "BeadsStatus" .. cap(bead.status))
      elseif key == "priority" then
        mark(row, from, "BeadsPriority" .. tostring(bead.priority == nil and 2 or bead.priority))
      elseif key == "type" then
        mark(row, from, "BeadsType" .. cap(bead.type or "task"))
      elseif key == "labels" then
        each_item(row, from, "BeadsBadgeAgent")
      elseif key == "blocked_by" then
        each_item(row, from, "BeadsId")
      end
    end
  end
end

local function relative_times(buf, bead, regions)
  local first
  for _, r in ipairs(regions) do
    if r.name == "comments" then
      first = r.first
    end
  end
  if not first then
    return
  end
  local row = first -- 0-based row of the first line after "## Comments"
  for _, c in ipairs(bead.comments or {}) do
    local rel = M.relative(c.created_at)
    if rel then
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { virt_text = { { " (" .. rel .. ")", "BeadsDim" } }, virt_text_pos = "eol" })
    end
    local n = (c.text ~= nil and c.text ~= "") and #vim.split(c.text, "\n", { plain = true }) or 0
    row = row + 1 + n + 1
  end
end

-- Winbar text for the window being drawn (evaluated by the 'winbar' option).
function M.winbar(win)
  win = win or vim.g.statusline_winid or vim.api.nvim_get_current_win()
  if win == 0 then
    win = vim.api.nvim_get_current_win()
  end
  local buf = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win)
  local st = buf and state[buf]
  if not st then
    return ""
  end
  local function esc(x)
    return (tostring(x):gsub("%%", "%%%%"))
  end
  local mode = vim.b[buf].beads_mode == "edit" and "EDIT" or "VIEW"
  local out = {}
  local b = st.bead
  if b then
    local status = b.status or ""
    out[#out + 1] = "%#BeadsStatus" .. cap(status) .. "#" .. esc(require("beads.glyphs").status(status))
    out[#out + 1] = " %#BeadsId#" .. esc(b.id)
    out[#out + 1] = " %#BeadsWinbar#· %#BeadsType" .. cap(b.type or "task") .. "#" .. esc(b.type or "task")
    local p = b.priority == nil and 2 or b.priority
    out[#out + 1] = " %#BeadsWinbar#· %#BeadsPriority" .. p .. "#P" .. p
    out[#out + 1] = " %#BeadsWinbar#· %#BeadsStatus" .. cap(status) .. "#" .. esc(status)
    out[#out + 1] = " %#BeadsWinbar#· "
  else
    out[#out + 1] = "%#BeadsWinbar#NEW · "
  end
  out[#out + 1] = "%#BeadsMode" .. (mode == "EDIT" and "Edit" or "View") .. "#" .. mode
  if vim.bo[buf].modified then
    out[#out + 1] = "%#BeadsWinbar#  %#BeadsWinbarModified#[+]"
  end
  if st.changed then
    out[#out + 1] = "%#BeadsWinbar#  %#BeadsWinbarChanged#⚠ changed on disk"
  end
  local spin = b and require("beads.progress").waiting(st.root, b.id)
  if spin then
    out[#out + 1] = "%#BeadsWinbar#  " .. require("beads.progress").glyph() .. " " .. spin
  end
  out[#out + 1] = "%#BeadsWinbar#"
  return table.concat(out)
end

local WINBAR_EXPR = "%{%v:lua.require'beads.views.detail'.winbar()%}"

attach_winbar = function(buf)
  require("beads.progress").watch("detail" .. buf, {
    valid = function()
      return vim.api.nvim_buf_is_valid(buf) and state[buf] ~= nil and vim.fn.bufwinid(buf) ~= -1
    end,
    update = function()
      vim.cmd("redrawstatus!")
    end,
  })
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    vim.api.nvim_set_option_value("winbar", WINBAR_EXPR, { scope = "local", win = w })
  end
  vim.cmd("redrawstatus!")
end

apply = function(buf, bead)
  local lines, regions = render.render(bead)
  state[buf] = { bead = bead, root = state[buf] and state[buf].root or cli.get_root() }
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = vim.b[buf].beads_mode == "edit"
  M.decorate(buf, bead, lines, regions)
  attach_winbar(buf)
end

-- The detail highlighting (dim regions, values, relative comment times) of a rendered bead.
function M.decorate(buf, bead, lines, regions)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, r in ipairs(regions) do
    for row = r.first - 1, r.last - 1 do
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = "BeadsDim" })
    end
  end
  highlight_values(buf, lines, bead)
  relative_times(buf, bead, regions)
end

-- Fetches bead `id` (with comments) from bd in `root`; cb(bead|nil, err).
function M.fetch_bead(root, id, cb)
  local prev = cli.get_root_override()
  cli.set_root(root)
  cli.show(id, function(res)
    if res.err then
      return cb(nil, res.err)
    end
    local item = type(res.data) == "table" and (res.data[1] or res.data) or nil
    if not item or not item.id then
      return cb(nil, "bead not found: " .. id)
    end
    cb(model.normalize(item))
  end, { include_comments = true })
  cli.set_root(prev)
end

-- Fetches the current server version of the bead; cb(bead|nil, err).
function M.fetch(buf, cb)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  M.fetch_bead(M.root(buf), bead_id(buf), cb)
end

-- Opens a split with the server rendering of the bead and diffs it against the detail buffer.
function M.show_diff(buf, server)
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    vim.api.nvim_set_current_buf(buf)
    win = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_set_current_win(win)
  vim.cmd("diffthis")
  vim.cmd("rightbelow vsplit")
  local sbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[sbuf].buftype = "nofile"
  vim.bo[sbuf].bufhidden = "wipe"
  vim.bo[sbuf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(sbuf, 0, -1, false, (render.render(server)))
  vim.bo[sbuf].modifiable = false
  vim.api.nvim_win_set_buf(0, sbuf)
  vim.cmd("diffthis")
end

local function warn_changed(buf)
  if state[buf] then
    state[buf].changed = true
    pcall(vim.cmd.redrawstatus)
  end
  if #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true, type = "virt_lines" }) > 0 then
    return
  end
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
    virt_lines = { { { "Beads: changed externally; :w will offer reload / force / diff", "WarningMsg" } } },
    virt_lines_above = true,
  })
end

local function subscribe(buf)
  local id = bead_id(buf)
  local unsub
  unsub = require("beads.store").subscribe(state[buf].root, function(st)
    if not vim.api.nvim_buf_is_valid(buf) or not state[buf] then
      return
    end
    local cur, seen = st.by_id[id], state[buf].bead
    if not cur or not seen or cur.updated_at == seen.updated_at then
      return
    end
    if vim.bo[buf].modified then
      warn_changed(buf)
    else
      M.load(buf)
    end
  end)
  local release = require("beads.watch").acquire(state[buf].root)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      unsub()
      release()
    end,
  })
end

local pending_parent
local pending_root -- root for a buffer being opened from a view (consumed by load / load_new)

-- Fills a beads://new buffer with the create template.
local function load_new(buf)
  local parent = pending_parent
  pending_parent = nil
  state[buf] = { bead = nil, root = state[buf] and state[buf].root or pending_root or cli.get_root(), new = true }
  local lines = render.template({ parent = parent })
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
end

-- Opens beads://new in the current window; parent (optional) is prefilled.
function M.create_child(parent_id, root)
  local existing = vim.fn.bufnr("beads://new")
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    if vim.bo[existing].modified and not parent_id then
      vim.api.nvim_set_current_buf(existing)
      return
    end
    if vim.api.nvim_get_current_buf() == existing then
      vim.cmd("enew")
    end
    pcall(vim.api.nvim_buf_delete, existing, { force = true })
  end
  pending_parent = parent_id
  pending_root = root
  pcall(vim.cmd.edit, "beads://new")
  pending_root = nil
end

-- Opens beads://<id> in the current window, loading and writing with `root` (default: the cli root).
function M.edit(id, root)
  pending_root = root
  local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape("beads://" .. id))
  pending_root = nil
  if not ok then
    error(err, 0)
  end
end

function M.open_new()
  M.create_child(nil)
end

-- True when buf is an unsaved beads://new buffer.
function M.is_new(buf)
  return state[buf] ~= nil and state[buf].new == true
end

-- After a successful create: rename to beads://<id> and reload as a normal detail buffer.
function M.adopt(buf, id)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local root = state[buf] and state[buf].root or cli.get_root()
  state[buf] = { root = root }
  vim.api.nvim_buf_set_name(buf, "beads://" .. id)
  vim.bo[buf].modified = false
  -- drop the alternate buffer left by the rename
  local old = vim.fn.bufnr("beads://new")
  if old ~= -1 and old ~= buf then
    pcall(vim.api.nvim_buf_delete, old, { force = true })
  end
  subscribe(buf)
  state[buf].new = nil
  M.enter_view(buf)
  M.load(buf)
end

-- (Re)loads the buffer from bd; safe to call from BufReadCmd or after a write.
function M.load(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local id = bead_id(buf)
  state[buf] = state[buf] or { root = pending_root or cli.get_root() }
  if not vim.b[buf].beads_detail_init then
    vim.b[buf].beads_detail_init = true
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].swapfile = false
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].filetype = "markdown"
    vim.api.nvim_create_autocmd({ "BufWinEnter", "TextChanged", "TextChangedI" }, {
      buffer = buf,
      callback = function()
        attach_winbar(buf)
      end,
    })
    if id ~= "new" then
      subscribe(buf)
    end
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        state[buf] = nil
        bound[buf] = nil
      end,
    })
  end
  if id == "new" then
    load_new(buf)
    set_mode(buf, "edit")
    return
  end
  if not vim.b[buf].beads_mode then
    set_mode(buf, "view")
  end
  local prev = cli.get_root_override()
  cli.set_root(state[buf].root)
  cli.show(id, function(res)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if res.err then
      vim.notify("Beads: " .. res.err, vim.log.levels.ERROR)
      return
    end
    local item = type(res.data) == "table" and (res.data[1] or res.data) or nil
    if not item or not item.id then
      vim.notify("Beads: bead not found: " .. id, vim.log.levels.ERROR)
      return
    end
    local bead = model.normalize(item)
    M.gather(state[buf].root, bead.id, function(threads)
      if not vim.api.nvim_buf_is_valid(buf) or not state[buf] then
        return
      end
      bead.threads = threads
      apply(buf, bead)
    end)
  end, { include_comments = true })
  cli.set_root(prev)
end

return M
