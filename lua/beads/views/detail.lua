-- Detail buffer beads://<id>: load, render, buffer-local keys.
local cli = require("beads.cli")
local model = require("beads.model")
local render = require("beads.buffer.render")
local workflow = require("beads.workflow")

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

local HELP = {
  "x   close bead (prompts for a reason)",
  "C   claim bead",
  "yy  yank bead id",
  "yr  yank workflow run command",
  "g?  show this help",
}

local function map(buf, lhs, fn, desc)
  vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "Beads: " .. desc })
end

local function setup_keys(buf)
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
  map(buf, "x", with_bead(function(b)
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
  end), "close")
  map(buf, "C", with_bead(function(b)
    local root = M.root(buf)
    local prev = cli.get_root_override()
    cli.set_root(root)
    cli.claim(b.id, after(root))
    cli.set_root(prev)
  end), "claim")
  map(buf, "yy", with_bead(function(b)
    vim.fn.setreg('"', b.id)
  end), "yank id")
  map(buf, "yr", with_bead(function(b)
    vim.fn.setreg('"', workflow.run_command(b))
  end), "yank run command")
  map(buf, "g?", function()
    vim.notify("Beads detail keys:\n" .. table.concat(HELP, "\n"), vim.log.levels.INFO)
  end, "help")
end

local function apply(buf, bead)
  local lines, regions = render.render(bead)
  state[buf] = { bead = bead, root = state[buf] and state[buf].root or cli.get_root() }
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
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
    setup_keys(buf)
    if id ~= "new" then
      subscribe(buf)
    end
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        state[buf] = nil
      end,
    })
  end
  if id == "new" then
    return load_new(buf)
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
