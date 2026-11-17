-- vim.ui.select fallback (no preview, no extra actions).
local M = {}

function M.pick(source, beads, picker)
  vim.ui.select(beads, {
    prompt = "Beads " .. source,
    format_item = picker.format,
  }, function(item)
    if item then
      picker.open_bead(item.id)
    end
  end)
end

return M
