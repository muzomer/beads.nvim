-- :w on a detail buffer: diff against the snapshot, run at most one 'bd update' then one 'bd batch'.
local cli = require("beads.cli")
local diff = require("beads.buffer.diff")
local store = require("beads.store")

local M = {}

local function finish(detail, buf, root)
  store.mark_self_write(root)
  store.refresh(root)
  if vim.api.nvim_buf_is_valid(buf) then
    detail.load(buf)
  end
end

-- :w on beads://new: one 'bd create', then rename + reload.
local creating = {}

local function do_create(buf)
  if creating[buf] then
    return
  end
  local detail = require("beads.views.detail")
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local plan = diff.create(lines)
  if vim.trim(plan.args[3] or "") == "" then
    vim.notify("Beads: title is required (set the '# ' heading)", vim.log.levels.ERROR)
    return
  end
  -- 'blocks:<id>' would make the new bead block <id>; a bare id makes it depend on (be blocked by) <id>.
  for i, a in ipairs(plan.args) do
    if plan.args[i - 1] == "--deps" then
      plan.args[i] = (a:gsub("blocks:", ""))
    end
  end
  local root = detail.root(buf)
  local prev = cli.get_root_override()
  cli.set_root(root)
  creating[buf] = true
  cli.run_with_files(plan.args, plan.files, function(res)
    creating[buf] = nil
    if res.err then
      vim.notify("Beads: create failed: " .. res.err, vim.log.levels.ERROR)
      return -- keep the user's edits
    end
    local item = type(res.data) == "table" and (res.data[1] or res.data) or nil
    if not item or not item.id then
      vim.notify("Beads: create succeeded but no id was returned", vim.log.levels.ERROR)
      return
    end
    store.mark_self_write(root)
    store.refresh(root)
    detail.adopt(buf, item.id)
  end)
  cli.set_root(prev)
end

local function do_write(buf)
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

-- Re-fetches the bead first; a changed updated_at refuses the write and offers reload / force / diff.
function M.write(buf)
  local detail = require("beads.views.detail")
  if detail.is_new(buf) then
    return do_create(buf)
  end
  local seen = detail.snapshot(buf)
  if not seen then
    return do_write(buf)
  end
  detail.fetch(buf, function(server, err)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if err then
      vim.notify("Beads: cannot check for external changes: " .. err, vim.log.levels.ERROR)
      return
    end
    if server.updated_at == seen.updated_at then
      return do_write(buf)
    end
    local choices = { "Reload (discard my edits)", "Force (apply my edits)", "Diff (compare with server)" }
    vim.ui.select(choices, { prompt = "Beads: bead changed externally" }, function(choice)
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if choice == choices[1] then
        detail.load(buf)
      elseif choice == choices[2] then
        do_write(buf)
      elseif choice == choices[3] then
        detail.show_diff(buf, server)
      end
    end)
  end)
end

return M
