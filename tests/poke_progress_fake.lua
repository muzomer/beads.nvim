-- Fake agent-poke (bead beads_nvim-r6s), installed through package.preload. It follows the real
-- agent-poke progress API (branch feat-poke-progress):
--   * poke(root, prompt, opts) -> status, id   (scripted; `false, nil` when a picker opened first)
--     and, for a non-nil id, fires the initial stage as a scheduled User autocmd AgentPokeProgress
--     with data { id, root, stage, target } (the real progress.new emits through vim.schedule too).
--   * progress(id) -> stage, err   (scripted per id; counts calls; on a stage change it fires the
--     autocmd, as the real progress() -> progress.set does).
-- Shared helpers to read what a window shows (buffer text plus extmark virtual text).
local M = {}

local state

local function emit(data)
  vim.schedule(function()
    vim.api.nvim_exec_autocmds("User", { pattern = "AgentPokeProgress", data = data, modeline = false })
  end)
end

-- Installs the fake. script = { status = <poke status>, id = <id or nil>, stage = <initial stage>,
-- target = <target title or nil>, err = <error for failed> }.
function M.install(script)
  state = {
    orig_preload = package.preload["agent-poke"],
    orig_loaded = package.loaded["agent-poke"],
    script = script or { status = "started", id = "p1", stage = "working", target = "background" },
    pokes = {},
    calls = {}, -- id -> number of progress(id) calls
    stages = {}, -- id -> { stage, err, target, root }
  }
  package.loaded["agent-poke"] = nil
  package.preload["agent-poke"] = function()
    return {
      poke = function(root, prompt, opts)
        state.pokes[#state.pokes + 1] = { root = root, prompt = prompt, opts = opts }
        local s = state.script
        if s.id ~= nil then
          state.stages[s.id] = { stage = s.stage, err = s.err, target = s.target, root = root, emitted = s.stage }
          emit({ id = s.id, root = root, stage = s.stage, target = s.target })
        end
        return s.status, s.id
      end,
      progress = function(id)
        state.calls[id] = (state.calls[id] or 0) + 1
        local h = state.stages[id]
        if not h then
          return nil
        end
        if h.stage ~= h.emitted then -- the real progress() fires the autocmd on a change
          h.emitted = h.stage
          emit({ id = id, root = h.root, stage = h.stage, target = h.target })
        end
        return h.stage, h.err
      end,
      status = function()
        return nil
      end,
    }
  end
end

-- Makes agent-poke unavailable (require fails).
function M.install_missing()
  state = {
    orig_preload = package.preload["agent-poke"],
    orig_loaded = package.loaded["agent-poke"],
    pokes = {},
    calls = {},
    stages = {},
  }
  package.loaded["agent-poke"] = nil
  package.preload["agent-poke"] = function()
    error("agent-poke is not installed (test)")
  end
end

function M.uninstall()
  if state then
    package.preload["agent-poke"] = state.orig_preload
    package.loaded["agent-poke"] = state.orig_loaded
  end
  state = nil
end

function M.pokes()
  return state.pokes
end

function M.calls(id)
  return state.calls[id] or 0
end

-- What the next progress(id) returns (no autocmd: the poke learns it only through progress(id)).
function M.set_polled(id, stage, err, root, target)
  local h = state.stages[id] or {}
  h.stage, h.err = stage, err
  h.root = root or h.root
  h.target = target or h.target
  state.stages[id] = h
end

-- A stage change reported through the User autocmd (and what progress(id) returns from then on).
function M.fire(id, root, stage, target, err)
  M.set_polled(id, stage, err, root, target)
  state.stages[id].emitted = stage
  vim.api.nvim_exec_autocmds("User", {
    pattern = "AgentPokeProgress",
    data = { id = id, root = root, stage = stage, target = target },
    modeline = false,
  })
end

-- Text of a virt_text chunk list.
local function chunks_text(chunks)
  local out = {}
  for _, c in ipairs(chunks or {}) do
    out[#out + 1] = type(c) == "table" and tostring(c[1] or "") or tostring(c)
  end
  return table.concat(out)
end

-- Lines a buffer shows: each row's text followed by the virtual text of its extmarks, with
-- virt_lines inserted below (or above) their row.
function M.display_lines(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local extra, above, below = {}, {}, {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    local row, d = m[2], m[4] or {}
    if d.virt_text then
      extra[row] = (extra[row] or "") .. " " .. chunks_text(d.virt_text)
    end
    if d.virt_lines then
      local t = d.virt_lines_above and above or below
      t[row] = t[row] or {}
      for _, vl in ipairs(d.virt_lines) do
        table.insert(t[row], chunks_text(vl))
      end
    end
  end
  local out = {}
  for i, l in ipairs(lines) do
    local row = i - 1
    vim.list_extend(out, above[row] or {})
    out[#out + 1] = l .. (extra[row] or "")
    vim.list_extend(out, below[row] or {})
  end
  return out
end

-- Displayed text of buffer row (1-based) with its virtual text.
function M.row_text(buf, n)
  local l = vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1] or ""
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, { n - 1, 0 }, { n - 1, -1 }, { details = true })) do
    local d = m[4] or {}
    if d.virt_text then
      l = l .. " " .. chunks_text(d.virt_text)
    end
  end
  return l
end

-- Number of active uv timers (vim.uv timers, vim.defer_fn and vim.fn.timer_start all use them).
function M.active_timers()
  local n = 0
  vim.uv.walk(function(h)
    if h:get_type() == "timer" and h:is_active() and not h:is_closing() then
      n = n + 1
    end
  end)
  return n
end

-- active_timers() measured inside a vim.wait callback (vim.wait runs a timer of its own), so it
-- compares with counts taken in other vim.wait callbacks.
function M.timers_now()
  local n
  vim.wait(100, function()
    n = M.active_timers()
    return true
  end, 10)
  return n
end

-- Waits ms milliseconds while processing events.
function M.sleep(ms)
  vim.wait(ms, function()
    return false
  end, 10)
end

-- The thread float: a floating window whose buffer starts with "Thread ".
function M.thread_float()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      local first = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, 1, false)[1] or ""
      if first:find("^Thread ") then
        return w
      end
    end
  end
end

return M
