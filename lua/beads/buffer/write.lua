-- :w on a detail buffer: diff against the snapshot, run at most one 'bd update' then one 'bd batch'.
local cli = require("beads.cli")
local diff = require("beads.buffer.diff")
local store = require("beads.store")

local M = {}

local function finish(detail, buf, root)
  store.mark_self_write(root)
  store.refresh(root)
  detail.load(buf)
end

function M.write(buf)
  local detail = require("beads.views.detail")
  local bead = detail.snapshot(buf)
  if not bead then
    vim.notify("Beads: detail buffer not loaded yet", vim.log.levels.WARN)
    return
  end
  local root = detail.root(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local plan = diff.compute(bead, lines)
  for _, w in ipairs(plan.warnings) do
    vim.notify("Beads: " .. w, vim.log.levels.WARN)
  end

  local function run_deps(update_ok)
    if #plan.deps == 0 then
      return finish(detail, buf, root)
    end
    local prev = cli.get_root_override()
    cli.set_root(root)
    cli.batch(plan.deps, function(res)
      if res.err then
        local prefix = update_ok and "update applied, but " or ""
        vim.notify(
          "Beads: " .. prefix .. "dependency (blocked_by) changes were not applied: " .. res.err,
          vim.log.levels.ERROR
        )
      end
      finish(detail, buf, root)
    end)
    cli.set_root(prev)
  end

  if plan.update then
    local prev = cli.get_root_override()
    cli.set_root(root)
    cli.run_with_files(plan.update.args, plan.update.files, function(res)
      if res.err then
        vim.notify("Beads: update failed: " .. res.err, vim.log.levels.ERROR)
        return -- keep the user's edits
      end
      run_deps(true)
    end)
    cli.set_root(prev)
  else
    run_deps(false)
  end
end

return M
