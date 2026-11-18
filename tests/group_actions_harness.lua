-- Shared harness for bead beads_nvim-2qo.2 specs (group actions on the tree's A menu):
-- vim.ui.select / vim.ui.input / vim.notify stubs driven by a per-action script, and tree helpers.
--
-- Script for one action (H.act):
--   name     : entry name used in failure messages ("priority", "add label", ...)
--   menu     : list of matchers (fn(text_lower) -> bool) tried in order against the A menu items
--   value    : nil (cancel the value prompt) or { input = "<answer>", pick = fn(text_lower) -> bool }
--   confirm  : answer to a "[y/N]" prompt (default "y"; nil string "" or "n" cancels)
-- The first vim.ui.select after A is the menu; every later select or non-[y/N] input is a value
-- prompt (value picked by select: first item whose formatted text matches `pick`; by input: `input`).
local M = {}

M.state = {}
M.notes = {}

local orig = {}

local function lower_text(opts, it)
  local fmt = (opts or {}).format_item or tostring
  local ok, s = pcall(fmt, it)
  return tostring(ok and s or it):lower()
end

function M.reset_state(script)
  M.state = {
    script = script,
    menu = nil, -- texts of the A menu
    menu_pick = nil, -- chosen menu text
    value_prompts = 0,
    value_lists = {}, -- texts of each value select list
    input_prompts = {},
    confirms = {},
  }
end

function M.install()
  orig.input, orig.select, orig.notify = vim.ui.input, vim.ui.select, vim.notify
  M.notes = {}
  M.reset_state(nil)
  vim.notify = function(msg, level)
    M.notes[#M.notes + 1] = { msg = tostring(msg), level = level }
  end
  vim.ui.select = function(list, opts, cb)
    local st = M.state
    local sc = st.script or {}
    local texts = {}
    for i, it in ipairs(list) do
      texts[i] = lower_text(opts, it)
    end
    if not st.menu then
      st.menu = texts
      for _, m in ipairs(sc.menu or {}) do
        for i, t in ipairs(texts) do
          if m(t) then
            st.menu_pick = t
            return cb(list[i], i)
          end
        end
      end
      return cb(nil, nil)
    end
    st.value_prompts = st.value_prompts + 1
    st.value_lists[#st.value_lists + 1] = texts
    local v = sc.value
    if v and v.pick then
      for i, t in ipairs(texts) do
        if v.pick(t) then
          return cb(list[i], i)
        end
      end
    end
    cb(nil, nil)
  end
  vim.ui.input = function(opts, cb)
    local st = M.state
    local sc = st.script or {}
    local p = tostring((opts or {}).prompt or "")
    if p:find("[y/N]", 1, true) then
      st.confirms[#st.confirms + 1] = p
      local a = sc.confirm
      if a == nil then
        a = "y"
      end
      return cb(a ~= "" and a or nil)
    end
    st.input_prompts[#st.input_prompts + 1] = p
    st.value_prompts = st.value_prompts + 1
    cb(sc.value and sc.value.input or nil)
  end
end

function M.restore()
  vim.ui.input, vim.ui.select, vim.notify = orig.input, orig.select, orig.notify
end

-- ── tree helpers ───────────────────────────────────────────────────────────────────────────────
M.tree_win = nil

function M.sleep(ms)
  vim.wait(ms, function()
    return false
  end, 10)
end

function M.wait_for(pred, what, timeout)
  assert(vim.wait(timeout or 5000, function()
    local ok, v = pcall(pred)
    return ok and v
  end, 10), "timed out waiting for " .. what)
end

function M.press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

function M.lines()
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(M.tree_win), 0, -1, false)
end

function M.dump()
  return table.concat(M.lines(), "\n")
end

function M.has_id(text, id)
  return text:find("%f[%w%-%.]" .. vim.pesc(id:lower()) .. "%f[^%w%-%.]") ~= nil
end

-- Row whose bead id is `id`: the first token after the tree guides, the fold marker and the status
-- glyph. Ids elsewhere on the line (e.g. "⛔ blocked by t-4") do not count.
local GUIDE_TOKENS = { ["│"] = true, ["├"] = true, ["└"] = true, ["▾"] = true, ["▸"] = true }

function M.row_of(id)
  for i, l in ipairs(M.lines()) do
    local toks = {}
    for tok in l:gmatch("%S+") do
      if not (#toks == 0 and GUIDE_TOKENS[tok]) then
        toks[#toks + 1] = tok
      end
    end
    if toks[2] == id then
      return i
    end
  end
end

function M.on(id)
  local r = M.row_of(id)
  assert(r, id .. " not rendered:\n" .. M.dump())
  vim.api.nvim_set_current_win(M.tree_win)
  vim.api.nvim_win_set_cursor(M.tree_win, { r, 0 })
end

function M.mark(ids)
  for _, id in ipairs(ids) do
    M.on(id)
    M.press("m")
  end
end

function M.open_tree(wait_id)
  local before = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    before[w] = true
  end
  M.tree_win = nil
  vim.cmd("Beads tree")
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if not before[w] then
      M.tree_win = w
    end
  end
  assert(M.tree_win, ":Beads tree opened no window")
  M.wait_for(function()
    return M.row_of(wait_id) ~= nil
  end, "tree to list the beads", 15000)
end

function M.close_all()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  pcall(vim.cmd, "silent! only!")
  pcall(vim.cmd, "silent! %bwipeout!")
end

-- Presses A on the tree (with the marks already set) and runs the script. Fails if the A menu
-- has no entry matching script.menu.
function M.act(script)
  M.reset_state(script)
  vim.api.nvim_set_current_win(M.tree_win)
  M.press("A")
  local st = M.state
  assert(st.menu, "A opened no vim.ui.select menu")
  assert(
    st.menu_pick,
    "A menu has no " .. script.name .. " entry; items:\n  " .. table.concat(st.menu, "\n  ")
  )
  return st
end

-- ── menu matchers ──────────────────────────────────────────────────────────────────────────────
local function has(t, ...)
  for _, w in ipairs({ ... }) do
    if not t:find(w, 1, true) then
      return false
    end
  end
  return true
end

local function removes(t)
  return t:find("remove", 1, true) or t:find("clear", 1, true) or t:find("unset", 1, true)
    or t:find("unblock", 1, true) or t:find("no parent", 1, true) or t:find("delete", 1, true)
end

M.menu = {
  priority = { function(t) return has(t, "priority") end },
  status = { function(t) return has(t, "status") end },
  assignee = { function(t) return has(t, "assignee") end },
  type = { function(t) return has(t, "type") end },
  add_label = { function(t) return has(t, "label") and not removes(t) end },
  remove_label = { function(t) return has(t, "label") and removes(t) end },
  epic = {
    function(t)
      return (has(t, "epic") or has(t, "parent")) and not removes(t)
    end,
  },
  -- a dedicated "remove parent" entry, else the epic entry (whose picker then offers removal)
  remove_parent = {
    function(t)
      return has(t, "parent") and removes(t)
    end,
    function(t)
      return (has(t, "epic") or has(t, "parent")) and not removes(t)
    end,
  },
  blocked_by = {
    function(t)
      return has(t, "block") and not removes(t)
    end,
  },
  remove_dep = {
    function(t)
      return (has(t, "block") or has(t, "dep")) and removes(t) and not has(t, "parent") and not has(t, "label")
    end,
  },
}

-- pick matcher for a bead id in a value list
function M.pick_id(id)
  return function(t)
    return M.has_id(t, id)
  end
end

-- pick matcher for the "remove parent" item of the epic picker
function M.pick_remove_parent(t)
  return (removes(t) or t:find("none", 1, true)) and true or false
end

return M
