-- Detail buffer beads://<id>: load, render, buffer-local keys.
local cli = require("beads.cli")
local model = require("beads.model")
local render = require("beads.buffer.render")
local workflow = require("beads.workflow")
local keys = require("beads.keys")

local M = {}

local ns = vim.api.nvim_create_namespace("beads_detail")
local state = {} -- buf -> { bead, root }

vim.api.nvim_set_hl(0, "BeadsReadonly", { link = "Comment", default = true })

function M.snapshot(buf)
  return state[buf] and state[buf].bead
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
        M.load(buf)
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
    vim.fn.setreg('"', b.id)
  end))
  map(buf, "yank_run", with_bead(function(b)
    vim.fn.setreg('"', workflow.run_command(b))
  end))
  acts.edit = function()
    M.enter_edit(buf)
  end
  acts.close = function()
    pcall(vim.cmd, "close")
  end
  return acts
end

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
  vim.bo[buf].modifiable = mode == "edit"
  if mode == "view" then
    bound[buf] = keys.bind(buf, "detail_view", view_actions(buf))
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

local function apply(buf, bead)
  local lines, regions = render.render(bead)
  state[buf] = { bead = bead, root = state[buf] and state[buf].root or cli.get_root() }
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = vim.b[buf].beads_mode == "edit"
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, r in ipairs(regions) do
    for row = r.first - 1, r.last - 1 do
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = "BeadsReadonly" })
    end
  end
end

-- Fetches the current server version of the bead; cb(bead|nil, err).
function M.fetch(buf, cb)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local id = bead_id(buf)
  local prev = cli.get_root_override()
  cli.set_root(M.root(buf))
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
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = unsub })
end

local pending_parent

-- Fills a beads://new buffer with the create template.
local function load_new(buf)
  local parent = pending_parent
  pending_parent = nil
  state[buf] = { bead = nil, root = state[buf] and state[buf].root or cli.get_root(), new = true }
  local lines = render.template({ parent = parent })
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
end

-- Opens beads://new in the current window; parent (optional) is prefilled.
function M.create_child(parent_id)
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
  vim.cmd.edit("beads://new")
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
  state[buf] = state[buf] or { root = cli.get_root() }
  if not vim.b[buf].beads_detail_init then
    vim.b[buf].beads_detail_init = true
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].swapfile = false
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].filetype = "markdown"
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
    apply(buf, model.normalize(item))
  end, { include_comments = true })
  cli.set_root(prev)
end

return M
