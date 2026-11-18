-- Keymaps: defaults per group, setup({ keymaps = ... }) overrides (a key, a list of keys or false),
-- the global <leader>b maps and the help floats. keymaps = false disables every map.
local M = {}

-- Ordered: { action, default lhs (string|list), desc }
M.defaults = {
  tree_view = {
    { "open", "<CR>", "open bead in the previous window" },
    { "add_child", "a", "add child bead" },
    { "close_bead", "x", "close bead (prompts for a reason)" },
    { "claim", "C", "claim bead" },
    { "refresh", "R", "refresh" },
    { "toggle_closed", "H", "toggle closed beads" },
    { "fold", "<Tab>", "toggle fold" },
    { "filter", "f", "filter (text, status: label: assignee: type:)" },
    { "sort", "s", "cycle sort: priority, updated, id" },
    { "layout", "L", "cycle layout: left, bottom, right, top" },
    { "yank_id", "yy", "yank bead id" },
    { "yank_run", "yr", "yank workflow run command" },
    { "close", "q", "close tree" },
    { "help", { "g?", "?" }, "show this help" },
  },
  detail_view = {
    { "edit", { "e", "i" }, "edit this bead" },
    { "close_bead", "x", "close bead (prompts for a reason)" },
    { "claim", "C", "claim bead" },
    { "open_thread", "<CR>", "open the question thread under the cursor" },
    { "next_waiting", "]u", "next thread waiting for you" },
    { "prev_waiting", "[u", "previous thread waiting for you" },
    { "next_bead", "]b", "next bead in tree order (count ok)" },
    { "prev_bead", "[b", "previous bead in tree order (count ok)" },
    { "ask", "a", "ask a question about the section / selection" },
    { "note", "n", "append a note (float)" },
    { "comment", "c", "add a comment (float)" },
    { "yank_id", "yy", "yank bead id" },
    { "yank_run", "yr", "yank workflow run command" },
    { "close", "q", "close window" },
    { "help", { "?", "g?" }, "show this help" },
  },
  thread = {
    { "reply", { "r", "i" }, "reply" },
    { "resolve", "x", "resolve thread" },
    { "apply", "a", "apply the proposal to the bead (unsaved edit)" },
    { "yank_run", "yr", "yank workflow run command (human threads)" },
    { "next", "n", "next thread" },
    { "prev", "p", "previous thread" },
    { "help", { "?", "g?" }, "show this help" },
    { "close", { "q", "<Esc>" }, "close" },
  },
  detail_edit = {
    { "save", "<C-s>", "save (normal and insert)" },
    { "view", "<Esc><Esc>", "back to view mode (asks before discarding edits)" },
    { "help", "g?", "show this help" },
  },
  input = {
    { "submit", "<C-s>", "submit (normal and insert)" },
    { "submit_normal", "<CR>", "submit (normal)" },
    { "cancel", { "q", "<Esc>" }, "cancel (normal)" },
  },
  picker = {
    { "yank_id", "ctrl-y", "yank bead id" },
    { "yank_run", "alt-r", "yank workflow run command" },
    { "close", "ctrl-x", "close bead" },
  },
}

-- Global maps (top-level keymaps.<action>): { action, default lhs, desc }
M.globals = {
  { "tree", "<leader>bt", "toggle the tree" },
  { "ready", "<leader>br", "ready picker" },
  { "list", "<leader>bl", "list picker" },
  { "search", "<leader>bs", "search picker (prompts for the query)" },
  { "needs", "<leader>bn", "needs-me picker" },
  { "epics", "<leader>be", "epics picker" },
  { "questions", "<leader>bq", "questions waiting on you" },
  { "create", "<leader>bc", "create a bead" },
  { "help", "<leader>b?", "keys that work here" },
  { "poke", "<leader>bp", "poke the agent about threads waiting on it" },
  { "output", "<leader>bP", "show the agent output" },
}

-- Where each group lives in the config.
local function section(cfg, group)
  if type(cfg) ~= "table" then
    return nil
  end
  if group == "detail_view" or group == "detail_edit" then
    local d = cfg.detail
    return type(d) == "table" and d[group == "detail_view" and "view" or "edit"] or nil
  end
  if group == "global" then
    return cfg
  end
  return cfg[group]
end

-- The default config value: { tree = "<leader>bt", ..., detail = { view = {...}, edit = {...} }, ... }
function M.default_map()
  local out = { detail = {} }
  for _, d in ipairs(M.globals) do
    out[d[1]] = d[2]
  end
  local function fill(group)
    local t = {}
    for _, d in ipairs(M.defaults[group]) do
      t[d[1]] = vim.deepcopy(d[2])
    end
    return t
  end
  out.detail.view = fill("detail_view")
  out.detail.edit = fill("detail_edit")
  out.tree_view = fill("tree_view")
  out.input = fill("input")
  out.picker = fill("picker")
  out.thread = fill("thread")
  return out
end

-- Replaces lists and scalars, merges dictionaries.
function M.merge(base, over)
  if type(over) ~= "table" or type(base) ~= "table" or vim.islist(over) then
    return over
  end
  local out = vim.deepcopy(base)
  for k, v in pairs(over) do
    out[k] = M.merge(out[k], v)
  end
  return out
end

local function lhs_list(v)
  if type(v) == "string" and v ~= "" then
    return { v }
  end
  local out = {}
  if type(v) == "table" then
    for _, s in ipairs(v) do
      if type(s) == "string" and s ~= "" then
        out[#out + 1] = s
      end
    end
  end
  return out
end

-- Active { action, lhs list, desc } for a group (disabled actions dropped).
function M.resolve(group)
  local cfg = require("beads").config.keymaps
  local out = {}
  if cfg == false then
    return out
  end
  local sec = section(cfg, group) or {}
  for _, d in ipairs(group == "global" and M.globals or M.defaults[group]) do
    local v = d[2]
    if type(sec) == "table" and sec[d[1]] ~= nil then
      v = sec[d[1]]
    end
    local l = lhs_list(v)
    if #l > 0 then
      out[#out + 1] = { d[1], l, d[3] }
    end
  end
  return out
end

-- First key of a group action, or nil.
function M.first(group, action)
  for _, k in ipairs(M.resolve(group)) do
    if k[1] == action then
      return k[2][1]
    end
  end
end

local TITLES = {
  tree_view = "tree",
  detail_view = "detail view",
  detail_edit = "detail edit",
  thread = "thread",
  input = "input",
  global = "global",
}

-- Help section heading and title word per group.
local HEADINGS = {
  tree_view = "Tree",
  detail_view = "View mode",
  detail_edit = "Edit mode",
  thread = "Thread",
  input = "Input",
  global = "Global",
}
local MODES = { tree_view = "tree", detail_view = "view", detail_edit = "edit", thread = "thread", input = "input" }

local EXTRA = {
  tree_view = { "za/zo/zc  fold" },
}

local function lines_for(group)
  local lines = {}
  for _, k in ipairs(M.resolve(group)) do
    lines[#lines + 1] = string.format("%-12s %s", table.concat(k[2], " "), k[3])
  end
  vim.list_extend(lines, EXTRA[group] or {})
  return lines
end

-- Extra help sections appended after Global: { heading, function() -> lines }.
M.help_sections = {
  {
    "Symbols",
    function(group)
      return require("beads.legend").lines(group)
    end,
  },
}

-- Grouped help lines: the current place's section (if any), Global, then M.help_sections.
local function help_lines(group)
  local lines = {}
  local function add(heading, body)
    if #lines > 0 then
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = "── " .. heading .. " ──"
    vim.list_extend(lines, body)
  end
  if group and group ~= "global" then
    add(HEADINGS[group], lines_for(group))
  end
  add(HEADINGS.global, lines_for("global"))
  for _, s in ipairs(M.help_sections) do
    local body = s[2](group)
    if body and #body > 0 then
      add(s[1], body)
    end
  end
  return lines
end

local function float(title, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local width = 10
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 1, math.max(10, vim.o.columns - 4))
  local height = math.min(#lines, math.max(1, vim.o.lines - 4))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
  })
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, lhs in ipairs({ "q", "<Esc>", "g?", "?" }) do
    vim.keymap.set("n", lhs, close, { buffer = buf, nowait = true, silent = true, desc = "Beads: close help" })
  end
end

function M.help_float(group)
  float("Beads help (" .. (MODES[group] or "keys") .. ")", help_lines(group))
end

-- <leader>b?: the keys of the current buffer (if it is a beads view) plus the global keys.
function M.global_help()
  local group = vim.b.beads_group
  if vim.b.beads_mode == "view" then
    group = "detail_view"
  elseif vim.b.beads_mode == "edit" then
    group = "detail_edit"
  elseif vim.bo.filetype == "beads-tree" then
    group = "tree_view"
  end
  M.help_float(group)
end

-- Sets buffer-local normal maps for a group. actions: action -> function. Returns the list of
-- { mode, lhs } set (for unbinding). "help" is provided here.
function M.bind(buf, group, actions, modes)
  actions = vim.tbl_extend("keep", actions, {
    help = function()
      M.help_float(group)
    end,
  })
  local set = {}
  if group == "thread" then
    vim.b[buf].beads_group = group
  end
  for _, k in ipairs(M.resolve(group)) do
    local fn = actions[k[1]]
    if fn then
      for _, lhs in ipairs(k[2]) do
        for _, mode in ipairs((modes and modes[k[1]]) or { "n" }) do
          vim.keymap.set(mode, lhs, fn, {
            buffer = buf,
            nowait = true,
            silent = true,
            desc = "Beads " .. TITLES[group] .. ": " .. k[3],
          })
          set[#set + 1] = { mode, lhs }
        end
      end
    end
  end
  return set
end

function M.unbind(buf, set)
  for _, m in ipairs(set or {}) do
    pcall(vim.keymap.del, m[1], m[2], { buffer = buf })
  end
end

-- Input float maps: submit (n+i), submit_normal (n), cancel (n).
function M.bind_input(buf, submit, cancel)
  vim.b[buf].beads_group = "input"
  for _, k in ipairs(M.resolve("input")) do
    for _, lhs in ipairs(k[2]) do
      local o = { buffer = buf, nowait = true, silent = true, desc = "Beads input: " .. k[3] }
      if k[1] == "submit" then
        vim.keymap.set("n", lhs, submit, o)
        vim.keymap.set("i", lhs, function()
          vim.cmd("stopinsert")
          submit()
        end, o)
      elseif k[1] == "submit_normal" then
        vim.keymap.set("n", lhs, submit, o)
      elseif k[1] == "cancel" then
        vim.keymap.set("n", lhs, cancel, o)
      end
    end
  end
end

-- fzf-lua action table keys: { action -> first lhs }.
function M.picker_keys()
  local out = {}
  for _, k in ipairs(M.resolve("picker")) do
    out[k[1]] = k[2]
  end
  return out
end

local set_globals = {}

-- (Re)creates the global <leader>b maps from the config.
function M.setup_globals()
  for _, lhs in ipairs(set_globals) do
    pcall(vim.keymap.del, "n", lhs)
  end
  set_globals = {}
  local function picker(source)
    return function()
      require("beads.views.picker").open(source)
    end
  end
  local acts = {
    tree = function()
      require("beads.views.tree").toggle()
    end,
    ready = picker("ready"),
    list = picker("list"),
    needs = picker("needs"),
    epics = picker("epics"),
    search = function()
      vim.ui.input({ prompt = "Search beads: " }, function(q)
        if q and q ~= "" then
          require("beads.views.picker").open("search", q)
        end
      end)
    end,
    questions = function()
      require("beads.views.questions").open()
    end,
    create = function()
      require("beads.views.detail").open_new()
    end,
    help = M.global_help,
    poke = function()
      require("beads.command").run({ "poke" })
    end,
    output = function()
      require("beads.command").run({ "output" })
    end,
  }
  for _, k in ipairs(M.resolve("global")) do
    for _, lhs in ipairs(k[2]) do
      vim.keymap.set("n", lhs, acts[k[1]], { silent = true, desc = "Beads: " .. k[3] })
      set_globals[#set_globals + 1] = lhs
    end
  end
end

return M
