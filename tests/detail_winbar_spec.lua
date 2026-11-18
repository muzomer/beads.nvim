-- Bead beads_nvim-4u9.8: detail buffer winbar.
-- Interface under test:
--   * The window showing beads://<id> has a winbar (window-local 'winbar') whose evaluated text
--     contains "<status glyph> <id> · <type> · P<n> · <status> · VIEW|EDIT", e.g.
--     "○ wb-1 · task · P2 · open · VIEW" (type_icons off, default glyphs).
--   * Highlight groups (via %#Group# items): glyph and status -> BeadsStatus<Status>, id -> BeadsId,
--     type -> BeadsType<Type>, "P<n>" -> BeadsPriority<n>, VIEW -> BeadsModeView,
--     EDIT -> BeadsModeEdit.
--   * "[+]" (BeadsWinbarModified) while the buffer has unsaved edits;
--     "⚠ changed on disk" (BeadsWinbarChanged) after an external change arrives while modified.
--   * The winbar follows mode switches (e / <Esc><Esc>), modification and reloads.
-- bd is a fake on PATH (tests/detail_winbar_fake.lua).

local fake = require("tests.detail_winbar_fake")

local function wb()
  return fake.winbar(vim.api.nvim_get_current_win())
end

local function wait_winbar(pred, what)
  fake.wait_for(function()
    return pred(wb())
  end, what .. " (winbar: " .. vim.inspect(wb().str) .. ")", 2000)
end

local function has(s)
  return function(w)
    return w.str:find(s, 1, true) ~= nil
  end
end

local function lacks(s)
  return function(w)
    return w.str:find(s, 1, true) == nil
  end
end

local function to_edit(buf)
  vim.api.nvim_set_current_buf(buf)
  fake.press("e")
  pcall(vim.cmd, "stopinsert")
  assert.equals("edit", vim.b[buf].beads_mode)
end

local function edit_title(buf, new)
  local row = fake.row_of(buf, "# ")
  vim.api.nvim_buf_set_lines(buf, row, row + 1, false, { "# " .. new })
end

describe("detail winbar", function()
  after_each(function()
    fake.teardown()
  end)

  describe("open task P2", function()
    before_each(function()
      fake.setup()
      require("beads").setup({})
    end)

    it("shows '<glyph> <id> · <type> · P<n> · <status> · VIEW' in view mode", function()
      fake.open_detail()
      wait_winbar(has("○ wb-1 · task · P2 · open · VIEW"), "view winbar text")
      assert.is_nil(wb().str:find("EDIT", 1, true))
    end)

    it("colours glyph, id, type, priority, status and mode with Beads* groups", function()
      fake.open_detail()
      wait_winbar(has("VIEW"), "view winbar")
      local w = wb()
      assert.equals("BeadsStatusOpen", fake.winbar_group_at(w, "○"))
      assert.equals("BeadsId", fake.winbar_group_at(w, "wb-1"))
      assert.equals("BeadsTypeTask", fake.winbar_group_at(w, "task"))
      assert.equals("BeadsPriority2", fake.winbar_group_at(w, "P2"))
      assert.equals("BeadsStatusOpen", fake.winbar_group_at(w, "open"))
      assert.equals("BeadsModeView", fake.winbar_group_at(w, "VIEW"))
    end)

    it("switches to EDIT (BeadsModeEdit) on e and back to VIEW on <Esc><Esc>", function()
      local buf = fake.open_detail()
      wait_winbar(has("VIEW"), "view winbar")
      to_edit(buf)
      wait_winbar(has("· EDIT"), "edit winbar")
      assert.is_nil(wb().str:find("VIEW", 1, true))
      assert.equals("BeadsModeEdit", fake.winbar_group_at(wb(), "EDIT"))
      fake.press("<Esc><Esc>")
      wait_winbar(has("· VIEW"), "back to view winbar")
      assert.is_nil(wb().str:find("EDIT", 1, true))
    end)

    it("shows '[+]' (BeadsWinbarModified) while unsaved, and drops it after discard", function()
      local buf = fake.open_detail()
      wait_winbar(has("VIEW"), "view winbar")
      assert.is_nil(wb().str:find("modified", 1, true))
      to_edit(buf)
      edit_title(buf, "Changed title")
      assert.is_true(vim.bo[buf].modified)
      wait_winbar(has("[+]"), "modified marker")
      assert.equals("BeadsWinbarModified", fake.winbar_group_at(wb(), "[+]"))
      vim.ui.select = function(items, _, on_choice)
        for _, it in ipairs(items) do
          if tostring(it):lower():find("discard", 1, true) then
            return on_choice(it)
          end
        end
        on_choice(nil)
      end
      fake.press("<Esc><Esc>")
      fake.wait_for(function()
        return not vim.bo[buf].modified and vim.b[buf].beads_mode == "view"
      end, "discard back to view")
      wait_winbar(lacks("modified"), "modified marker gone")
      wait_winbar(has("· VIEW"), "view winbar after discard")
    end)

    it("shows '⚠ changed on disk' (BeadsWinbarChanged) on an external change while modified", function()
      local buf = fake.open_detail()
      to_edit(buf)
      edit_title(buf, "Local edit")
      wait_winbar(has("[+]"), "modified marker")
      assert.is_nil(wb().str:find("changed on disk", 1, true))
      fake.write_bead({ updated_at = "2026-11-10T11:00:00Z" })
      require("beads.store").refresh(fake.dir())
      wait_winbar(has("⚠ changed on disk"), "changed-on-disk marker")
      assert.equals("BeadsWinbarChanged", fake.winbar_group_at(wb(), "⚠ changed on disk"))
      assert.is_true(vim.bo[buf].modified, "local edits were dropped")
    end)

    it("follows the bead when an unmodified buffer reloads after an external change", function()
      fake.open_detail()
      wait_winbar(has("○ wb-1 · task · P2 · open · VIEW"), "initial winbar")
      fake.write_bead({ status = "in_progress", priority = 1, updated_at = "2026-11-10T11:00:00Z" })
      require("beads.store").refresh(fake.dir())
      wait_winbar(has("◐ wb-1 · task · P1 · in_progress · VIEW"), "winbar after reload")
      local w = wb()
      assert.equals("BeadsStatusInProgress", fake.winbar_group_at(w, "◐"))
      assert.equals("BeadsPriority1", fake.winbar_group_at(w, "P1"))
      assert.is_nil(w.str:find("changed on disk", 1, true))
    end)
  end)

  describe("blocked bug P0", function()
    before_each(function()
      fake.setup({ status = "blocked", priority = 0, issue_type = "bug" })
      require("beads").setup({})
    end)

    it("uses the bead's own status, type and priority groups", function()
      fake.open_detail()
      wait_winbar(has("● wb-1 · bug · P0 · blocked · VIEW"), "blocked bug winbar")
      local w = wb()
      assert.equals("BeadsStatusBlocked", fake.winbar_group_at(w, "blocked"))
      assert.equals("BeadsTypeBug", fake.winbar_group_at(w, "bug"))
      assert.equals("BeadsPriority0", fake.winbar_group_at(w, "P0"))
    end)
  end)
end)
