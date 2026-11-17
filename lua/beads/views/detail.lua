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

-- (Re)loads the buffer from bd; safe to call from BufReadCmd or after a write.
function M.load(buf)
  local id = bead_id(buf)
  state[buf] = state[buf] or { root = cli.get_root() }
  if not vim.b[buf].beads_detail_init then
    vim.b[buf].beads_detail_init = true
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].swapfile = false
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].filetype = "markdown"
    setup_keys(buf)
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        state[buf] = nil
      end,
    })
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
