-- Bead beads_nvim-4gx.8: detail buffer VIEW and EDIT modes.
-- Interface under test:
--   * beads://<id> opens in VIEW mode: 'modifiable' off, vim.b.beads_mode == "view",
--     require("beads").mode() == "view" while it is the current buffer.
--     Buffer-local normal-mode keys (each with a desc): e, i (edit), x (close bead), C (claim),
--     n (note float), c (comment float), yy (yank id), yr (yank run command), q (close window),
--     ? and g? (help float; its title contains the mode name).
--   * e or i switch to EDIT mode: 'modifiable' on, vim.b.beads_mode == "edit", mode() == "edit",
--     the view action maps are gone (x deletes a character). EDIT keys: g? (help, title shows
--     "edit"), <C-s> save (normal + insert), <Esc><Esc> (normal) back to view.
--   * :w (or <C-s>) in EDIT mode saves through the existing path and returns to VIEW on success;
--     a failed update or a refused write (conflict prompt cancelled) stays in EDIT with the edits.
--   * <Esc><Esc> without edits returns to VIEW at once. With edits it asks first through
--     vim.ui.select; choosing the item containing "discard" (case-insensitive) drops the edits and
--     returns to VIEW, cancelling (nil) keeps EDIT and the edits.
--   * beads://new (:Beads create) opens directly in EDIT mode.
-- bd is a fake on PATH (tests/modes_fake.lua).

local fake = require("tests.modes_fake")

local function select_spy(answer)
  local calls = {}
  vim.ui.select = function(items, opts, on_choice)
    opts = opts or {}
    calls[#calls + 1] = { items = items, opts = opts }
    local fmt = opts.format_item or tostring
    if answer == "discard" then
      for _, it in ipairs(items) do
        if tostring(fmt(it)):lower():find("discard", 1, true) then
          return on_choice(it)
        end
      end
      error("no 'discard' item in prompt: " .. vim.inspect(items))
    end
    on_choice(nil)
  end
  return calls
end

local function edit_mode(buf)
  vim.api.nvim_set_current_buf(buf)
  fake.press("e")
  pcall(vim.cmd, "stopinsert")
  assert.is_true(fake.is_edit(buf), "e did not switch to edit mode")
end

local VIEW_KEYS = { "e", "i", "x", "C", "n", "c", "yy", "yr", "q", "?", "g?" }

describe("beads detail view/edit modes", function()
  before_each(function()
    fake.setup()
    require("beads").setup({})
  end)

  after_each(function()
    fake.teardown()
  end)

  it("beads://<id> opens in view mode, read-only", function()
    local buf = fake.open_detail()
    assert.is_false(vim.bo[buf].modifiable, "detail buffer is modifiable in view mode")
    assert.equals("view", vim.b[buf].beads_mode)
    assert.equals("view", require("beads").mode())
  end)

  it("view mode has buffer-local maps with desc for e, i, x, C, n, c, yy, yr, q, ?, g?", function()
    local buf = fake.open_detail()
    for _, k in ipairs(VIEW_KEYS) do
      local km = fake.buf_map(buf, "n", k)
      assert.is_not_nil(km, "no buffer-local view map for " .. k)
      assert.is_true(type(km.desc) == "string" and km.desc ~= "", "view map " .. k .. " has no desc")
    end
  end)

  it("x in view mode closes the bead with the prompted reason", function()
    fake.open_detail()
    vim.ui.input = function(_, cb)
      cb("done here")
    end
    fake.press("x")
    fake.wait_for(function()
      return fake.count("close") >= 1
    end, "bd close")
    assert.is_true(fake.count("done here") >= 1, "close reason not passed: " .. vim.inspect(fake.log()))
  end)

  it("C in view mode claims the bead", function()
    fake.open_detail()
    fake.press("C")
    fake.wait_for(function()
      return fake.count("--claim") >= 1
    end, "bd update --claim")
  end)

  it("n and c in view mode open input floats", function()
    fake.open_detail()
    for _, k in ipairs({ "n", "c" }) do
      local f = fake.press_for_float(k)
      assert.is_not_nil(f, k .. " opened no float in view mode")
      fake.close_float(f)
    end
  end)

  it("yy and yr in view mode yank id and run command", function()
    fake.open_detail()
    vim.fn.setreg('"', "")
    fake.press("yy")
    assert.equals("fx-1", vim.fn.getreg('"'))
    fake.press("yr")
    assert.equals("/beads-workflow:run-bead fx-1", vim.fn.getreg('"'))
  end)

  it("q in view mode closes the window", function()
    local buf = fake.open_detail()
    vim.cmd("split")
    local win = vim.api.nvim_get_current_win()
    assert.equals(buf, vim.api.nvim_win_get_buf(win))
    fake.press("q")
    assert.is_false(vim.api.nvim_win_is_valid(win), "q did not close the window")
  end)

  for _, k in ipairs({ "?", "g?" }) do
    it(k .. " in view mode opens a help float whose title shows the view mode", function()
      fake.open_detail()
      local f = fake.press_for_float(k)
      assert.is_not_nil(f, k .. " opened no float")
      local title, text = fake.float_title(f), fake.float_text(f)
      fake.close_float(f)
      assert.is_truthy(title:lower():find("view", 1, true), "help title lacks the mode: " .. title)
      assert.is_truthy(text:find("yy", 1, true), "help does not list yy:\n" .. text)
    end)
  end

  for _, k in ipairs({ "e", "i" }) do
    it(k .. " switches to edit mode and removes the view maps", function()
      local buf = fake.open_detail()
      fake.press(k)
      pcall(vim.cmd, "stopinsert")
      assert.is_true(vim.bo[buf].modifiable, "not modifiable after " .. k)
      assert.equals("edit", vim.b[buf].beads_mode)
      assert.equals("edit", require("beads").mode())
      for _, v in ipairs(VIEW_KEYS) do
        if v ~= "g?" then
          assert.is_nil(fake.buf_map(buf, "n", v), "view map " .. v .. " still set in edit mode")
        end
      end
    end)
  end

  it("x in edit mode deletes a character", function()
    local buf = fake.open_detail()
    edit_mode(buf)
    local before = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local closes = fake.count("close")
    fake.press("x")
    assert.equals(before:sub(2), vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    vim.wait(200)
    assert.equals(closes, fake.count("close"), "x in edit mode ran bd close")
  end)

  it("edit mode maps g?, <C-s> (normal + insert) and <Esc><Esc>, each with a desc", function()
    local buf = fake.open_detail()
    edit_mode(buf)
    for _, m in ipairs({ { "n", "g?" }, { "n", "<C-s>" }, { "i", "<C-s>" }, { "n", "<Esc><Esc>" } }) do
      local km = fake.buf_map(buf, m[1], m[2])
      assert.is_not_nil(km, "no buffer-local " .. m[1] .. "-mode map " .. m[2] .. " in edit mode")
      assert.is_true(type(km.desc) == "string" and km.desc ~= "", m[2] .. " has no desc")
    end
  end)

  it("g? in edit mode opens a help float whose title shows the edit mode", function()
    local buf = fake.open_detail()
    edit_mode(buf)
    local f = fake.press_for_float("g?")
    assert.is_not_nil(f, "g? opened no float in edit mode")
    local title = fake.float_title(f)
    fake.close_float(f)
    assert.is_truthy(title:lower():find("edit", 1, true), "help title lacks the mode: " .. title)
  end)

  it(":w in edit mode saves and returns to view mode", function()
    local buf = fake.open_detail()
    edit_mode(buf)
    fake.edit_title(buf, "Mode test saved")
    vim.cmd("write")
    fake.wait_for(function()
      return fake.count("update") >= 1
    end, "bd update")
    fake.wait_for(function()
      return fake.is_view(buf)
    end, "view mode after a successful save")
    assert.is_not_nil(fake.buf_map(buf, "n", "x"), "view map x not restored after save")
  end)

  it("<C-s> in edit mode saves and returns to view mode", function()
    local buf = fake.open_detail()
    edit_mode(buf)
    fake.edit_title(buf, "Mode test ctrl-s")
    fake.press("<C-s>")
    fake.wait_for(function()
      return fake.count("update") >= 1
    end, "bd update")
    fake.wait_for(function()
      return fake.is_view(buf)
    end, "view mode after <C-s>")
  end)

  it("a failed save stays in edit mode with the edits", function()
    local buf = fake.open_detail()
    edit_mode(buf)
    fake.edit_title(buf, "Mode test failing")
    fake.set_fail(true)
    vim.cmd("write")
    fake.wait_for(function()
      return fake.count("update") >= 1
    end, "bd update")
    vim.wait(400)
    assert.is_true(fake.is_edit(buf), "left edit mode after a failed save")
    assert.is_true(vim.bo[buf].modified, "buffer no longer modified")
    assert.is_true(fake.has_line(buf, "# Mode test failing"), "edits lost")
  end)

  it("a refused save (external change, prompt cancelled) stays in edit mode with the edits", function()
    local buf = fake.open_detail()
    edit_mode(buf)
    fake.edit_title(buf, "Mode test conflict")
    fake.write_bead({ updated_at = "2026-11-17T17:00:00Z", priority = 3 })
    local prompts = select_spy(nil)
    vim.cmd("write")
    fake.wait_for(function()
      return #prompts > 0
    end, "conflict prompt")
    vim.wait(300)
    assert.equals(0, fake.count("update"), "write was not refused")
    assert.is_true(fake.is_edit(buf), "left edit mode after a refused save")
    assert.is_true(vim.bo[buf].modified)
    assert.is_true(fake.has_line(buf, "# Mode test conflict"), "edits lost")
  end)

  it("<Esc><Esc> without edits returns to view mode without asking", function()
    local buf = fake.open_detail()
    edit_mode(buf)
    local prompts = select_spy(nil)
    fake.press("<Esc><Esc>")
    fake.wait_for(function()
      return fake.is_view(buf)
    end, "view mode after <Esc><Esc>", 1000)
    assert.equals(0, #prompts, "asked although there were no edits")
  end)

  it("<Esc><Esc> with edits asks; cancelling keeps edit mode and the edits", function()
    local buf = fake.open_detail()
    edit_mode(buf)
    fake.edit_title(buf, "Mode test keep")
    local prompts = select_spy(nil)
    fake.press("<Esc><Esc>")
    vim.wait(300)
    assert.equals(1, #prompts, "no confirmation prompt for unsaved edits")
    assert.is_true(fake.is_edit(buf), "left edit mode although the prompt was cancelled")
    assert.is_true(fake.has_line(buf, "# Mode test keep"), "edits lost")
    assert.is_true(vim.bo[buf].modified)
    assert.equals(0, fake.count("update"), "<Esc><Esc> saved")
  end)

  it("<Esc><Esc> with edits asks; confirming discards the edits and returns to view mode", function()
    local buf = fake.open_detail()
    edit_mode(buf)
    fake.edit_title(buf, "Mode test discard")
    local prompts = select_spy("discard")
    fake.press("<Esc><Esc>")
    fake.wait_for(function()
      return fake.is_view(buf)
    end, "view mode after discarding")
    assert.equals(1, #prompts)
    fake.wait_for(function()
      return fake.has_line(buf, "# " .. fake.TITLE) and not vim.bo[buf].modified
    end, "server version back in the buffer")
    assert.is_false(fake.has_line(buf, "# Mode test discard"), "edits not discarded")
    assert.equals(0, fake.count("update"), "<Esc><Esc> saved")
  end)

  it("beads://new opens directly in edit mode", function()
    vim.cmd("Beads create")
    local buf = vim.api.nvim_get_current_buf()
    fake.wait_for(function()
      return vim.api.nvim_buf_get_name(buf) == "beads://new" and fake.has_line(buf, "## Description")
    end, "beads://new template", 2000)
    pcall(vim.cmd, "stopinsert")
    assert.is_true(vim.bo[buf].modifiable)
    assert.equals("edit", vim.b[buf].beads_mode)
    assert.is_nil(fake.buf_map(buf, "n", "x"), "view map x set on beads://new")
  end)
end)
