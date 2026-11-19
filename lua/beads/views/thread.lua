-- Thread float: the conversation of one question thread, opened from the detail buffer's
-- Questions section. Keys: keymaps.thread.
local keys = require("beads.keys")
local qstore = require("beads.questions.store")
local human = require("beads.questions.human")
local workflow = require("beads.workflow")

local M = {}

local function lines_of(t)
  local out = { ("Thread %s (%s%s)"):format(t.id, t.status or "open", t.human and ", human" or ""), "" }
  for _, m in ipairs(t.messages or {}) do
    out[#out + 1] = "[" .. (m.author or "?") .. "]"
    for _, l in ipairs(vim.split(m.body or "", "\n", { plain = true })) do
      out[#out + 1] = "  " .. l
    end
    if m.proposal then
      local pl = vim.split(tostring(m.proposal.value), "\n", { plain = true })
      out[#out + 1] = ("  proposal: %s = %s"):format(tostring(m.proposal.field), pl[1])
      for i = 2, #pl do
        out[#out + 1] = "    " .. pl[i]
      end
    end
    out[#out + 1] = ""
  end
  return out
end

local function transcript(t)
  local out = { ("Question thread %s"):format(t.id) }
  if t.section and t.section ~= "" then
    out[#out + 1] = "Section: " .. tostring(t.section)
  end
  if t.quote and t.quote ~= "" then
    out[#out + 1] = "Quote: " .. tostring(t.quote)
  end
  out[#out + 1] = ""
  for _, m in ipairs(t.messages or {}) do
    out[#out + 1] = (m.author == "agent" and "A: " or "Q: ") .. (m.body or "")
    out[#out + 1] = ""
  end
  return table.concat(out, "\n")
end

-- Saves the resolved thread as ONE bead comment, once. saved_comment is set before the call (so
-- a second x while it runs adds nothing) and cleared again if bd fails.
local function save_comment(root, tid)
  local t = qstore.get(root, tid)
  if not t or t.saved_comment then
    return
  end
  pcall(qstore.mark_saved, root, tid, true)
  require("beads.cli").comments_add(t.bead, transcript(t), function(res)
    if res.err then
      pcall(qstore.mark_saved, root, tid, false)
      local why = (vim.split(res.err, "\n", { plain = true })[1] or ""):sub(1, 120)
      vim.notify("Beads: the thread comment was not saved on the bead (" .. why .. ")", vim.log.levels.WARN)
    end
  end)
end

local function latest_proposal(t)
  for i = #(t.messages or {}), 1, -1 do
    if t.messages[i].proposal then
      return t.messages[i].proposal
    end
  end
end

-- Opens the float for threads[idx] of the detail buffer `dbuf`.
function M.open(dbuf, idx)
  local detail = require("beads.views.detail")
  local root = detail.root(dbuf)
  local cur = detail.snapshot(dbuf).threads[idx]
  local tid = cur.id

  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[fbuf].bufhidden = "wipe"
  vim.bo[fbuf].filetype = "markdown"
  local win = vim.api.nvim_open_win(fbuf, true, {
    relative = "editor",
    width = 60,
    height = 5,
    row = 0,
    col = 0,
    style = "minimal",
    border = "rounded",
    title = " Thread ",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  local function threads()
    local b = detail.snapshot(dbuf)
    return b and b.threads or {}
  end
  local function current()
    for _, t in ipairs(threads()) do
      if t.id == tid then
        return t
      end
    end
  end
  local progress = require("beads.progress")
  local stage_row -- buffer line (1-based) of the stage line, or nil
  -- Sizes the float to its content: up to 80% of the editor, centered.
  local function resize()
    if not (vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(fbuf)) then
      return
    end
    local maxw = math.max(1, math.min(vim.o.columns - 2, math.max(20, math.floor(vim.o.columns * 0.8))))
    local maxh = math.max(3, math.floor(vim.o.lines * 0.8))
    local want = 0
    for _, l in ipairs(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false)) do
      want = math.max(want, vim.fn.strdisplaywidth(l))
    end
    local width = math.min(maxw, math.max(60, want + 2))
    if vim.api.nvim_win_get_width(win) ~= width then
      vim.api.nvim_win_set_config(win, { relative = "editor", width = width, row = 0, col = 0 })
    end
    local height = math.min(maxh, math.max(1, vim.api.nvim_win_text_height(win, {}).all))
    local row = math.max(0, math.floor((vim.o.lines - height - 2) / 2))
    local col = math.max(0, math.floor((vim.o.columns - width - 2) / 2))
    vim.api.nvim_win_set_config(win, { relative = "editor", width = width, height = height, row = row, col = col })
  end
  local function stage_line()
    local t = current()
    local text = t and progress.stage_text(root, t.bead, t.id)
    return text and ("  " .. text)
  end
  local function render()
    local t = current()
    if not (t and vim.api.nvim_buf_is_valid(fbuf)) then
      return close()
    end
    local lines = lines_of(t)
    local sl = stage_line()
    stage_row = nil
    if sl then
      lines[#lines + 1] = sl
      stage_row = #lines
    end
    vim.bo[fbuf].modifiable = true
    vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
    vim.bo[fbuf].modifiable = false
    resize()
  end
  -- Redraws only the stage line (spinner frame, stage change).
  local function update_stage()
    if not (vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(fbuf)) then
      return
    end
    local sl = stage_line()
    if (sl ~= nil) ~= (stage_row ~= nil) then
      return render()
    end
    if sl then
      local cur = vim.api.nvim_buf_get_lines(fbuf, stage_row - 1, stage_row, false)[1]
      if cur ~= sl then
        vim.bo[fbuf].modifiable = true
        vim.api.nvim_buf_set_lines(fbuf, stage_row - 1, stage_row, false, { sl })
        vim.bo[fbuf].modifiable = false
            resize()
      end
    end
  end
  progress.watch("thread" .. fbuf, {
    valid = function()
      return vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(fbuf)
    end,
    update = update_stage,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    callback = function()
      if not vim.api.nvim_win_is_valid(win) then
        return true
      end
        resize()
    end,
  })
  local function refresh()
    if not vim.api.nvim_buf_is_valid(dbuf) then
      return close()
    end
    detail.refresh_threads(dbuf, render)
  end
  local function fail(err)
    vim.notify("Beads: " .. err, vim.log.levels.ERROR)
  end

  local acts = {}
  acts.close = close
  acts.reply = function()
    local t = current()
    if not t then
      return
    end
    require("beads.views.input").open({
      title = "Reply " .. t.bead .. " " .. t.id,
      on_submit = function(text, send)
        if t.human then
          human.answer(root, t.bead, text, function(res)
            if res.err then
              fail(res.err)
            elseif send then
              local prompt = ("Human answer on %s: %s\nRead the bead notes with bd show %s and continue."):format(
                t.bead,
                text,
                t.bead
              )
              require("beads.workflow").deliver(root, prompt, "answer stored.", { bead = t.bead, thread = t.id })
            end
            refresh()
          end)
        else
          local ok, err = pcall(qstore.reply, root, t.id, "user", text)
          if not ok then
            fail(tostring(err))
          elseif err == nil then
            vim.notify("Beads: thread " .. t.id .. " is gone; reply not stored", vim.log.levels.WARN)
          elseif send then
            local prompt = ("Reply on %s thread %s: %s\nRead it with beads-ask and answer with beads-ask reply %s."):format(
              t.bead,
              t.id,
              text,
              t.id
            )
            require("beads.workflow").deliver(root, prompt, "reply stored.", {
              bead = t.bead,
              thread = t.id,
              base_n = #(t.messages or {}) + 1,
            })
          end
          refresh()
        end
      end,
    })
  end
  acts.resolve = function()
    local t = current()
    if not t then
      return
    end
    if t.human then
      return vim.notify("Beads: a human thread is resolved by answering it (reply)", vim.log.levels.WARN)
    end
    local ok, err = pcall(qstore.resolve, root, t.id)
    if not ok then
      fail(tostring(err))
    else
      save_comment(root, t.id)
    end
    refresh()
  end
  acts.apply = function()
    local t = current()
    local p = t and latest_proposal(t)
    if not p then
      return vim.notify("Beads: this thread has no proposal", vim.log.levels.WARN)
    end
    if detail.is_float(dbuf) then
      return vim.notify("Beads: a peek float is read-only; open the bead in the main window", vim.log.levels.WARN)
    end
    local b = detail.snapshot(dbuf)
    local old = b and ({ title = b.title, description = b.description, design = b.design, acceptance = b.acceptance })[p.field]
    local prompt = ("Apply proposal to %s?\n- %s\n+ %s"):format(tostring(p.field), tostring(old or ""), tostring(p.value))
    local choices = { "Apply proposal", "Cancel" }
    vim.ui.select(choices, { prompt = prompt }, function(choice)
      if choice ~= choices[1] then
        return
      end
      close()
      local err = detail.apply_field(dbuf, p.field, p.value)
      if err then
        fail(err)
      end
    end)
  end
  local function step(d)
    return function()
      local list = threads()
      for i, t in ipairs(list) do
        if t.id == tid then
          local n = list[(i - 1 + d) % #list + 1]
          tid = n.id
          return render()
        end
      end
    end
  end
  acts.next = step(1)
  acts.prev = step(-1)
  acts.yank_run = function()
    local t = current()
    local b = detail.snapshot(dbuf)
    if t and t.human and b then
      workflow.yank(workflow.run_command(b))
    end
  end
  acts.peek = function()
    require("beads.views.peek").at_cursor(root)
  end
  acts.details = function()
    require("beads.views.peek").at_cursor(root, true)
  end
  keys.bind(fbuf, "thread", acts)
  vim.api.nvim_create_autocmd("User", {
    pattern = "BeadsThreadsRefreshed",
    callback = function(a)
      if not vim.api.nvim_buf_is_valid(fbuf) then
        return true
      end
      if a.data == dbuf then
        render()
      end
    end,
  })
  render()
end

return M
