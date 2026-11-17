-- fzf-lua adapter. <CR> opens; the other actions come from keymaps.picker (default ctrl-y yank id,
-- ctrl-x close, alt-r yank run command).
local render = require("beads.buffer.render")
local workflow = require("beads.workflow")

local M = {}

function M.pick(source, beads, picker)
  local by_id, lines = {}, {}
  for _, b in ipairs(beads) do
    by_id[b.id] = b
    lines[#lines + 1] = picker.format(b)
  end
  local function first(selected)
    local id = selected and selected[1] and picker.id_of_line(selected[1])
    return id, id and by_id[id]
  end
  local actions = {
    ["default"] = function(selected)
      local id = first(selected)
      if id then
        picker.open_bead(id)
      end
    end,
  }
  local handlers = {
    yank_id = function(selected)
      local id = first(selected)
      if id then
        picker.yank(id)
      end
    end,
    close = function(selected)
      local id = first(selected)
      if id then
        picker.close_bead(id)
      end
    end,
    yank_run = function(selected)
      local _, b = first(selected)
      if b then
        picker.yank(workflow.run_command(b))
      end
    end,
  }
  for action, lhs in pairs(require("beads.keys").picker_keys()) do
    for _, key in ipairs(lhs) do
      actions[key] = handlers[action]
    end
  end
  require("fzf-lua").fzf_exec(lines, {
    prompt = "Beads " .. source .. "> ",
    preview = function(selected)
      local _, b = first(selected)
      if not b then
        return ""
      end
      return table.concat(render.render(b), "\n")
    end,
    actions = actions,
  })
end

return M
