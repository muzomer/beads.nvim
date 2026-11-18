-- Group executor: runs one action over several beads. Supported ops go through one `bd batch`
-- (close) or one `bd reopen <ids...>`; the rest run one bead at a time (claim). Failures are
-- summarised in one notification, the store is refreshed once, and done(failed_ids) is called.
local cli = require("beads.cli")
local store = require("beads.store")

local M = {}

local function with_root(root, fn)
  local prev = cli.get_root_override()
  cli.set_root(root)
  fn()
  cli.set_root(prev)
end

local function quote(s)
  return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

-- Past participle shown in confirmations.
local VERB = { close = "Close", claim = "Claim", reopen = "Reopen" }

-- Sorts a list of beads by id, in place.
function M.sort_by_id(list)
  table.sort(list, function(a, b)
    return a.id < b.id
  end)
  return list
end

-- Opens a float listing `lines`; returns its window id.
local function open_list(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local width = 20
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width, math.max(vim.o.columns - 4, 20))
  local height = math.min(#lines, math.max(vim.o.lines - 6, 1))
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor", row = 1, col = 1, width = width, height = height,
    style = "minimal", border = "rounded", focusable = false, zindex = 250,
  })
  vim.bo[buf].bufhidden = "wipe"
  return win
end

-- Asks "<Verb> N beads? [y/N]" for more than one bead; cb() runs on y. With `lines` (one per
-- target, "id  title") and more than 5 beads, a float lists them while the prompt is open.
function M.confirm(op, n, cb, lines)
  if n <= 1 then
    return cb()
  end
  local win = (lines and n > 5) and open_list(lines) or nil
  vim.ui.input({ prompt = ("%s %d beads? [y/N] "):format(VERB[op] or op, n) }, function(ans)
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if ans and ans:lower():match("^%s*y") then
      cb()
    end
  end)
end

-- op: "close" (opts.reason) | "claim" | "reopen" | "batch" (opts.lines: one bd batch) |
-- "update" (opts.flags: one `bd update <id> <flags>` per bead). ids: list, in tree order.
function M.run(root, op, ids, opts, done)
  opts = opts or {}
  done = done or function() end
  local total = #ids
  if total == 0 then
    return done({})
  end
  local failed, errs = {}, {}
  local function finish()
    store.mark_self_write(root)
    store.refresh(root)
    if #failed > 0 then
      if total == 1 then
        vim.notify("Beads: " .. (errs[1] or "failed"), vim.log.levels.ERROR)
      elseif #errs == #failed and op ~= "claim" then
        vim.notify("Beads: " .. errs[1], vim.log.levels.ERROR)
      else
        vim.notify("Beads: " .. #failed .. " of " .. total .. " failed: " .. table.concat(failed, ", "), vim.log.levels.ERROR)
      end
    end
    done(failed)
  end
  local function all_failed(res)
    if res.err then
      failed, errs = vim.list_slice(ids), { res.err }
    end
    store.mark_self_write(root)
    finish()
  end
  store.mark_self_write(root)
  if op == "batch" then
    return with_root(root, function()
      cli.batch(opts.lines or {}, all_failed)
    end)
  end
  if op == "close" and total > 1 then
    local lines = {}
    for _, id in ipairs(ids) do
      local reason = opts.reason
      lines[#lines + 1] = "close " .. id .. ((reason and reason ~= "") and (" " .. quote(reason)) or "")
    end
    return with_root(root, function()
      cli.batch(lines, all_failed)
    end)
  end
  if op == "reopen" then
    return with_root(root, function()
      cli.reopen(ids, all_failed)
    end)
  end
  local i = 0
  local function step()
    i = i + 1
    local id = ids[i]
    if not id then
      return finish()
    end
    local function cb(res)
      if res.err then
        failed[#failed + 1] = id
        errs[#errs + 1] = res.err
      end
      store.mark_self_write(root)
      step()
    end
    with_root(root, function()
      if op == "update" then
        cli.update(id, opts.flags or {}, cb)
      elseif op == "close" then
        cli.close(id, opts.reason, cb)
      else
        cli.claim(id, cb)
      end
    end)
  end
  step()
end

return M
