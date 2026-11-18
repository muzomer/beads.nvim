-- Shared setup for the 💬 badge and :Beads questions specs (bead beads_nvim-4gx.6).
-- `bd` is replaced by a shell script on PATH (test double for the external binary). Every call is
-- logged to <dir>/calls.log. Dispatch, in order:
--   argv containing "--label human" -> <dir>/human.json (beads labelled human, with notes)
--   show <id>                       -> <dir>/show-<id>.json, else "[]"
--   list (any other)                -> <dir>/list.json
--   other                           -> "{}"
-- Stored question threads live in <dir>/.beads-nvim/questions.json (beads.questions.store).
--
-- Fixture (ids are chosen so no id is a substring of another):
--   qa-1  open    stored thread A (needs=user) "Stored ask alpha"
--                 stored thread B (needs=user) "Second ask alpha" (agent, user, agent: 3 messages)
--   ag-2  open    stored thread needs=agent  "Agent turn bravo"
--   rs-3  open    stored thread resolved     "Resolved charlie"
--   hu-4  open    label human, notes -> human thread "Human asks delta"
--   cl-5  closed  stored thread needs=user   "Closed ask echo"
--   hc-6  closed  label human, notes -> human thread "Closed human foxtrot"
--   pl-7  open    no threads
local cli = require("beads.cli")
local qstore = require("beads.questions.store")

local M = {}

M.repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local state = {}

function M.dir()
  return state.dir
end

function M.bead(id, title, extra)
  local b = {
    id = id,
    title = title,
    description = "desc " .. id,
    status = "open",
    priority = 2,
    issue_type = "task",
    created_at = "2026-11-17T10:00:00Z",
    updated_at = "2026-11-17T10:00:00Z",
  }
  for k, v in pairs(extra or {}) do
    b[k] = v
  end
  return b
end

function M.beads(opts)
  opts = opts or {}
  local hu = M.bead("hu-4", "Human delta", { notes = "older note\nHuman asks delta", labels = { "human" } })
  if opts.hu_answered then
    hu = M.bead("hu-4", "Human delta", { notes = "older note\nHuman asks delta\nyes do it" })
  end
  return {
    M.bead("qa-1", "Alpha"),
    M.bead("ag-2", "Bravo"),
    M.bead("rs-3", "Charlie"),
    hu,
    M.bead("cl-5", "Echo", { status = "closed" }),
    M.bead("hc-6", "Foxtrot", {
      status = "closed",
      notes = "Closed human foxtrot",
      labels = { "human" },
    }),
    M.bead("pl-7", "Golf"),
  }
end

local function write(name, data)
  vim.fn.writefile({ vim.json.encode(data) }, state.dir .. "/" .. name)
end

-- Writes list.json, show-<id>.json and human.json from the bead list.
function M.write_beads(beads)
  write("list.json", beads)
  local human = {}
  for _, b in ipairs(beads) do
    write("show-" .. b.id .. ".json", { b })
    if vim.tbl_contains(b.labels or {}, "human") then
      human[#human + 1] = b
    end
  end
  if #human == 0 then
    vim.fn.writefile({ "[]" }, state.dir .. "/human.json")
  else
    write("human.json", human)
  end
end

local function agent(body)
  return { author = "agent", body = body }
end

-- Adds the stored threads; returns { a = <thread A id>, b = <thread B id>, ... }.
function M.write_threads()
  local root = state.dir
  local ids = {}
  ids.a = qstore.add(root, { bead = "qa-1", messages = { agent("Stored ask alpha") } }).id
  ids.b = qstore.add(root, {
    bead = "qa-1",
    messages = {
      agent("Second ask alpha"),
      { author = "user", body = "User reply alpha" },
      agent("Follow-up alpha"),
    },
  }).id
  ids.ag = qstore.add(root, {
    bead = "ag-2",
    messages = { agent("Agent turn bravo"), { author = "user", body = "user answered bravo" } },
  }).id
  ids.rs = qstore.add(root, { bead = "rs-3", messages = { agent("Resolved charlie") } }).id
  qstore.resolve(root, ids.rs)
  ids.cl = qstore.add(root, { bead = "cl-5", messages = { agent("Closed ask echo") } }).id
  return ids
end

function M.log()
  local p = state.dir .. "/calls.log"
  return vim.fn.filereadable(p) == 1 and vim.fn.readfile(p) or {}
end

function M.wait_for(pred, what, timeout)
  assert(vim.wait(timeout or 3000, function()
    local ok, v = pcall(pred)
    return ok and v
  end, 10), "timed out waiting for " .. what)
end

function M.press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

-- opts.fzf: a fake fzf-lua module to install; otherwise fzf-lua is made unavailable.
function M.setup(opts)
  opts = opts or {}
  state.orig_path = vim.env.PATH
  state.orig_cwd = vim.fn.getcwd()
  state.orig_select = vim.ui.select
  state.orig_input = vim.ui.input
  state.orig_notify = vim.notify
  state.orig_fzf_loaded = package.loaded["fzf-lua"]
  state.orig_fzf_preload = package.preload["fzf-lua"]
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  state.dir = vim.fn.resolve(d)
  local q = vim.fn.shellescape
  local dir = state.dir
  vim.fn.writefile({
    "#!/bin/sh",
    'echo "$*" >> ' .. q(dir .. "/calls.log"),
    'case "$*" in',
    '  *"--label human"*) cat ' .. q(dir .. "/human.json") .. "; exit 0;;",
    "esac",
    'prev=""',
    'for a in "$@"; do',
    '  if [ "$prev" = "show" ]; then',
    "    f=" .. q(dir) .. '"/show-$a.json"',
    '    if [ -f "$f" ]; then cat "$f"; else echo "[]"; fi',
    "    exit 0",
    "  fi",
    '  prev="$a"',
    "done",
    'for a in "$@"; do',
    '  case "$a" in',
    "    list) cat " .. q(dir .. "/list.json") .. "; exit 0;;",
    "  esac",
    "done",
    "echo '{}'",
  }, dir .. "/bd")
  vim.fn.setfperm(dir .. "/bd", "rwxr-xr-x")
  M.write_beads(M.beads())
  vim.env.PATH = dir .. ":" .. state.orig_path
  vim.cmd.cd(vim.fn.fnameescape(dir))
  cli.set_root(dir)
  if opts.fzf then
    package.preload["fzf-lua"] = nil
    package.loaded["fzf-lua"] = opts.fzf
  else
    package.loaded["fzf-lua"] = nil
    package.preload["fzf-lua"] = function()
      error("fzf-lua is not installed (test)")
    end
  end
  if vim.fn.exists(":Beads") ~= 2 or vim.fn.exists("#BeadsDetail#BufReadCmd") == 0 then
    vim.cmd.source(M.repo .. "/plugin/beads.lua")
  end
  require("beads").setup({})
end

function M.teardown()
  pcall(vim.cmd, "stopinsert")
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.bo[b].filetype == "beads-tree" then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  pcall(vim.cmd, "silent! tabonly!")
  pcall(vim.cmd, "silent! only!")
  pcall(vim.cmd, "silent! %bwipeout!")
  vim.wait(50, function()
    return false
  end, 10)
  vim.ui.select = state.orig_select
  vim.ui.input = state.orig_input
  vim.notify = state.orig_notify
  package.loaded["fzf-lua"] = state.orig_fzf_loaded
  package.preload["fzf-lua"] = state.orig_fzf_preload
  vim.env.PATH = state.orig_path
  vim.cmd.cd(vim.fn.fnameescape(state.orig_cwd))
  cli.set_root(nil)
  require("beads").setup({})
  vim.fn.delete(state.dir, "rf")
end

-- Stubs vim.ui.select; returns a getter for the last call { items, opts, on_choice, lines }.
function M.capture_select()
  local captured
  vim.ui.select = function(items, opts, on_choice)
    opts = opts or {}
    local fmt = opts.format_item or tostring
    local lines = {}
    for i, it in ipairs(items) do
      lines[i] = tostring(fmt(it))
    end
    captured = { items = items, opts = opts, on_choice = on_choice, lines = lines }
  end
  return function(what)
    M.wait_for(function()
      return captured ~= nil
    end, what or "vim.ui.select")
    return captured
  end
end

-- Index of the first line containing s (plain), or nil.
function M.find(lines, s)
  for i, l in ipairs(lines) do
    if l:find(s, 1, true) then
      return i
    end
  end
end

-- 1-based line number of the first line after "## Questions" containing text, or nil.
function M.question_line(buf, text)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local start
  for i, l in ipairs(lines) do
    if l == "## Questions" then
      start = i
    elseif start and l:find(text, 1, true) then
      return i
    end
  end
end

return M
