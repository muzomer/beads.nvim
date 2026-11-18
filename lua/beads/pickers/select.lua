-- vim.ui.select fallback (no preview, no extra actions).
local M = {}

function M.pick(source, beads, picker, release)
  vim.ui.select(beads, {
    prompt = "Beads " .. source,
    format_item = picker.format,
  }, function(item)
    if release then
      release()
    end
    if item then
      picker.open_bead(item.id)
    end
  end)
end

return M
