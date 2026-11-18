-- Pickers: ready, list, search, needs, epics. Adapters: pickers/fzf.lua, pickers/select.lua.
local cli = require("beads.cli")
local store = require("beads.store")
local model = require("beads.model")
local workflow = require("beads.workflow")

local M = {}

M.sources = { "ready", "list", "search", "needs", "epics" }

local function from_store(filter, cb)
  local root = cli.get_root()
  store.refresh(root, function(state, err)
    if err then
      return cb(nil, err)
    end
    local out = {}
    for _, b in pairs(state.by_id) do
      if filter(b) then
        out[#out + 1] = b
      end
    end
    cb(require("beads.ui.format").sort(out))
  end)
end

local function from_cli(fn, ...)
  local args = { ... }
  local cb = table.remove(args)
  table.insert(args, function(res)
    if res.err then
      return cb(nil, res.err)
    end
    local beads = model.normalize_all(res.data)
    -- overlay waiting_user (not in cli output) from the store state
    store.refresh(cli.get_root(), function(state)
      for _, b in ipairs(beads) do
        local sb = state and state.by_id and state.by_id[b.id]
        if sb and sb.waiting_user then
          b.waiting_user = true
        end
      end
      cb(beads)
    end)
  end)
  fn(unpack(args))
end

function M.load(source, query, cb)
  if source == "ready" then
    from_cli(cli.ready, cb)
  elseif source == "search" then
    from_cli(cli.search, query, cb)
  elseif source == "list" then
    from_store(function(b)
      return b.status == "open" or b.status == "in_progress"
    end, cb)
  elseif source == "needs" then
    from_store(workflow.is_needs_me, cb)
  elseif source == "epics" then
    from_store(function(b)
      return b.type == "epic"
    end, cb)
  else
    cb(nil, "unknown picker source: " .. tostring(source))
  end
end

-- Plain line text (vim.ui.select).
function M.format(b)
  return (require("beads.ui.format").format(b))
end

-- Line text with ANSI colours (fzf).
function M.format_ansi(b)
  local F = require("beads.ui.format")
  return F.ansi(F.format(b))
end

-- Id of a picker line: the second field (the first is the status glyph).
function M.id_of_line(line)
  return (tostring(line or ""):gsub("\27%[[%d;]*m", "")):match("^%s*%S+%s+([%w%-%._]+)")
end

function M.yank(text)
  require("beads.workflow").yank(text)
end

function M.open_bead(id)
  vim.cmd.edit(vim.fn.fnameescape("beads://" .. id))
  require("beads.flash").flash()
end

function M.close_bead(id)
  vim.ui.input({ prompt = "Close " .. id .. " reason (optional): " }, function(reason)
    if reason == nil then
      return
    end
    local root = cli.get_root()
    cli.close(id, reason, function(res)
      if res.err then
        return vim.notify("Beads: close failed: " .. res.err, vim.log.levels.ERROR)
      end
      store.mark_self_write(root)
      store.refresh(root)
    end)
  end)
end

-- Holds the watcher on `root` while a picker is open; returns an idempotent release().
function M.hold(root)
  return require("beads.watch").acquire(root)
end

-- Runs fzf-lua's fzf_exec and releases `release` (idempotent) when the picker closes: via fzf-lua's
-- winopts.on_close hook, and additionally via the terminal buffer's end when one is current
-- (covers <Esc>, which runs no action). Without a terminal buffer (fzf-tmux) on_close is the signal.
function M.fzf_exec(lines, opts, release)
  if not release then
    return require("fzf-lua").fzf_exec(lines, opts)
  end
  local done = false
  local function once()
    if done then
      return
    end
    done = true
    vim.schedule(release) -- not inside fzf-lua's teardown
  end
  opts.winopts = opts.winopts or {}
  local prev = opts.winopts.on_close
  opts.winopts.on_close = function(...)
    if type(prev) == "function" then
      pcall(prev, ...)
    end
    once()
  end
  local ok, err = pcall(require("fzf-lua").fzf_exec, lines, opts)
  if not ok then
    once()
    error(err, 0)
  end
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype == "terminal" then
    vim.api.nvim_create_autocmd({ "TermClose", "BufWipeout", "BufHidden" }, {
      buffer = buf,
      once = true,
      callback = once,
    })
  end
end

function M.open(source, query)
  local function go(q)
    local release = M.hold(cli.get_root())
    M.load(source, q, function(beads, err)
      if err then
        release()
        return vim.notify("Beads: " .. source .. ": " .. err, vim.log.levels.ERROR)
      end
      if #beads == 0 then
        release()
        return vim.notify("Beads: " .. source .. ": nothing found", vim.log.levels.INFO)
      end
      local adapter = require("beads").config.fzf and "fzf" or "select"
      require("beads.pickers." .. adapter).pick(source, beads, M, release)
    end)
  end
  if source == "search" and (not query or query == "") then
    vim.ui.input({ prompt = "Search beads: " }, function(q)
      if q and q ~= "" then
        go(q)
      end
    end)
    return
  end
  go(query)
end

return M
