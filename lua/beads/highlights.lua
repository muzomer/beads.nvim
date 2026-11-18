-- All Beads* highlight groups. Defined with default = true (links to standard
-- groups) so colourschemes and user :hi override them; re-applied on ColorScheme.
local M = {}

local links = {
  BeadsId = "Identifier",
  BeadsTitle = "Normal",
  BeadsDim = "Comment",
  BeadsStatusOpen = "DiagnosticInfo",
  BeadsStatusInProgress = "DiagnosticWarn",
  BeadsStatusBlocked = "DiagnosticError",
  BeadsStatusClosed = "DiagnosticOk",
  BeadsStatusDeferred = "Comment",
  BeadsPriority0 = "ErrorMsg",
  BeadsPriority1 = "DiagnosticError",
  BeadsPriority2 = "DiagnosticWarn",
  BeadsPriority3 = "DiagnosticInfo",
  BeadsPriority4 = "Comment",
  BeadsTypeEpic = "Special",
  BeadsTypeBug = "DiagnosticError",
  BeadsTypeFeature = "Function",
  BeadsTypeTask = "Normal",
  BeadsTypeChore = "Comment",
  BeadsBadgeUser = "DiagnosticWarn",
  BeadsBadgeAgent = "DiagnosticHint",
  BeadsBlocked = "DiagnosticError",
  BeadsCurrent = "CursorLine",
  BeadsFlash = "IncSearch",
  BeadsMarked = "DiagnosticWarn",
  BeadsFold = "Folded",
  BeadsGuide = "NonText",
  BeadsHeader = "Title",
  BeadsWinbar = "WinBar",
  BeadsWinbarModified = "DiagnosticWarn",
  BeadsWinbarChanged = "DiagnosticError",
  BeadsModeView = "DiagnosticInfo",
  BeadsModeEdit = "DiagnosticWarn",
}

function M.apply()
  for name, link in pairs(links) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

function M.setup()
  M.apply()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("BeadsHighlights", { clear = true }),
    callback = M.apply,
  })
end

return M
