-- fzf-lua adapter. Keys: <CR> open, ctrl-y yank id, ctrl-x close, alt-r yank run command
-- (alt-r replaces `yr`, which is not bindable in fzf).
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
  require("fzf-lua").fzf_exec(lines, {
    prompt = "Beads " .. source .. "> ",
    preview = function(selected)
      local _, b = first(selected)
      if not b then
        return ""
      end
      return table.concat(render.render(b), "\n")
    end,
    actions = {
      ["default"] = function(selected)
        local id = first(selected)
        if id then
          picker.open_bead(id)
        end
      end,
      ["ctrl-y"] = function(selected)
        local id = first(selected)
        if id then
          picker.yank(id)
        end
      end,
      ["ctrl-x"] = function(selected)
        local id = first(selected)
        if id then
          picker.close_bead(id)
        end
      end,
      ["alt-r"] = function(selected)
        local _, b = first(selected)
        if b then
          picker.yank(workflow.run_command(b))
        end
      end,
    },
  })
end

return M
