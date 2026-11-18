-- fzf-lua adapter. <CR> opens; the other actions come from keymaps.picker (default ctrl-y yank id,
-- ctrl-x close, alt-r yank run command).
local render = require("beads.buffer.render")
local workflow = require("beads.workflow")

local M = {}

function M.pick(source, beads, picker, release)
  local by_id, lines = {}, {}
  for _, b in ipairs(beads) do
    by_id[b.id] = b
    lines[#lines + 1] = picker.format_ansi(b)
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
  local opts = {
    prompt = "Beads " .. source .. "> ",
    header = M.header(),
    preview = function(selected)
      local _, b = first(selected)
      if not b then
        return ""
      end
      return table.concat(render.render(b), "\n")
    end,
    actions = actions,
  }
  local ok, builtin = pcall(require, "fzf-lua.previewer.builtin")
  if ok and type(builtin) == "table" and builtin.base then
    opts.previewer = M.previewer_class(builtin.base, function(line)
      local _, b = first({ line })
      return b
    end)
  end
  picker.fzf_exec(lines, opts, release)
end

-- Header listing the active picker action keys (disabled actions omitted).
function M.header()
  local parts = { "<CR> open" }
  for _, k in ipairs(require("beads.keys").resolve("picker")) do
    parts[#parts + 1] = k[2][1] .. " " .. k[3]
  end
  return table.concat(parts, "  |  ")
end

-- fzf-lua builtin previewer showing the rendered bead with markdown highlighting.
function M.previewer_class(base, bead_of)
  local P = base:extend()
  function P:new(o, opts, fzf_win)
    base.new(self, o, opts, fzf_win)
    return self
  end
  function P:populate_preview_buf(entry_str)
    local b = bead_of(entry_str)
    local buf = self:get_tmp_buffer()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, b and render.render(b) or {})
    vim.bo[buf].filetype = "markdown"
    self:set_preview_buf(buf)
  end
  return P
end

return M
