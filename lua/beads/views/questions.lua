-- :Beads questions: every open thread waiting on the user (needs == "user") on non-closed beads,
-- stored threads plus human threads. <CR> opens the bead's detail buffer at the thread.
local cli = require("beads.cli")
local store = require("beads.store")

local M = {}

local function first_line(t)
  local m = t.messages and t.messages[1]
  return vim.split((m and m.body) or "", "\n", { plain = true })[1] or ""
end

function M.format(t)
  return t.bead .. "  " .. first_line(t)
end

-- cb(threads, err); threads sorted by bead id then thread order.
function M.load(root, cb)
  store.refresh(root, function(state, err)
    if err then
      return cb(nil, err)
    end
    local function open(t)
      local b = state.by_id[t.bead]
      return b and b.status ~= "closed" and t.status ~= "resolved" and t.needs == "user"
    end
    local ok, stored = pcall(require("beads.questions.store").list, root, { needs = "user" })
    local out = {}
    for _, t in ipairs(ok and stored or {}) do
      if open(t) then
        out[#out + 1] = t
      end
    end
    require("beads.questions.human").list(root, function(res)
      for _, t in ipairs(res.data or {}) do
        local b = state.by_id[t.bead]
        if open(t) and b and vim.tbl_contains(b.labels or {}, "human") then
          out[#out + 1] = t
        end
      end
      local order = {}
      for i, t in ipairs(out) do
        order[t] = i
      end
      table.sort(out, function(a, b)
        if a.bead ~= b.bead then
          return a.bead < b.bead
        end
        return order[a] < order[b]
      end)
      cb(out)
    end)
  end)
end

-- Opens beads://<bead> and puts the cursor on the thread's line once the buffer has it.
function M.open_thread(t)
  vim.cmd.edit(vim.fn.fnameescape("beads://" .. t.bead))
  local buf = vim.api.nvim_get_current_buf()
  local detail = require("beads.views.detail")
  local tries = 0
  local function place()
    tries = tries + 1
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local snap = detail.snapshot(buf)
    local h = detail.questions_heading(buf)
    if snap and snap.threads and h then
      for k, th in ipairs(snap.threads) do
        if th.id == t.id then
          for _, w in ipairs(vim.fn.win_findbuf(buf)) do
            pcall(vim.api.nvim_win_set_cursor, w, { h + k, 0 })
          end
          return
        end
      end
    end
    if tries < 100 then
      vim.defer_fn(place, 30)
    end
  end
  place()
end

function M.open()
  local root = cli.get_root()
  M.load(root, function(threads, err)
    if err then
      return vim.notify("Beads questions: " .. err, vim.log.levels.ERROR)
    end
    if #threads == 0 then
      return vim.notify("Beads questions: nothing waiting on you", vim.log.levels.INFO)
    end
    if require("beads").config.fzf then
      return M.pick_fzf(threads)
    end
    vim.ui.select(threads, { prompt = "Beads questions", format_item = M.format }, function(t)
      if t then
        M.open_thread(t)
      end
    end)
  end)
end

function M.pick_fzf(threads)
  local by_line, lines = {}, {}
  for _, t in ipairs(threads) do
    local line = M.format(t)
    by_line[line] = t
    lines[#lines + 1] = line
  end
  local function thread_of(selected)
    return selected and selected[1] and by_line[selected[1]]
  end
  require("fzf-lua").fzf_exec(lines, {
    prompt = "Beads questions> ",
    preview = function(selected)
      local t = thread_of(selected)
      if not t then
        return ""
      end
      local out = {}
      for _, m in ipairs(t.messages or {}) do
        out[#out + 1] = "[" .. tostring(m.author) .. "]"
        vim.list_extend(out, vim.split(m.body or "", "\n", { plain = true }))
        out[#out + 1] = ""
      end
      return table.concat(out, "\n")
    end,
    actions = {
      default = function(selected)
        local t = thread_of(selected)
        if t then
          M.open_thread(t)
        end
      end,
    },
  })
end

return M
