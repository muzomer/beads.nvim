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

-- Asks "<Verb> N beads? [y/N]" for more than one bead; cb() runs on y.
function M.confirm(op, n, cb)
  if n <= 1 then
    return cb()
  end
  vim.ui.input({ prompt = ("%s %d beads? [y/N] "):format(VERB[op] or op, n) }, function(ans)
    if ans and ans:lower():match("^%s*y") then
      cb()
    end
  end)
end

-- op: "close" (opts.reason) | "claim" | "reopen". ids: list, in tree order.
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
      if op == "close" then
        cli.close(id, opts.reason, cb)
      else
        cli.claim(id, cb)
      end
    end)
  end
  step()
end

return M
