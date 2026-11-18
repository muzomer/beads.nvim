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
  local width = math.min(80, math.max(30, vim.o.columns - 4))
  local height = math.min(20, math.max(5, vim.o.lines - 6))
  local win = vim.api.nvim_open_win(fbuf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " Thread ",
  })
  vim.wo[win].wrap = true

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
  local function render()
    local t = current()
    if not (t and vim.api.nvim_buf_is_valid(fbuf)) then
      return close()
    end
    vim.bo[fbuf].modifiable = true
    vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines_of(t))
    vim.bo[fbuf].modifiable = false
  end
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
    vim.ui.input({ prompt = "Reply: " }, function(text)
      if not text or vim.trim(text) == "" then
        return
      end
      if t.human then
        human.answer(root, t.bead, text, function(res)
          if res.err then
            fail(res.err)
          end
          refresh()
        end)
      else
        local ok, err = pcall(qstore.reply, root, t.id, "user", text)
        if not ok then
          fail(tostring(err))
        end
        refresh()
      end
    end)
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
    end
    refresh()
  end
  acts.apply = function()
    local t = current()
    local p = t and latest_proposal(t)
    if not p then
      return vim.notify("Beads: this thread has no proposal", vim.log.levels.WARN)
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
      vim.fn.setreg('"', workflow.run_command(b))
    end
  end
  acts.peek = function()
    require("beads.views.peek").at_cursor(root)
  end
  keys.bind(fbuf, "thread", acts)
  render()
end

return M
