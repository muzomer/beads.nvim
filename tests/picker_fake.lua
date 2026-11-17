-- Shared setup for picker specs (bead beads_nvim-ge7.13): a fake `bd` on PATH plus fixtures.
-- The fake bd (test double for the external binary) appends its argv to $FAKE_DIR/args.log and
-- dispatches on the subcommand:
--   ready      -> $FAKE_DIR/ready.json
--   search     -> $FAKE_DIR/search.json
--   show <id>  -> $FAKE_DIR/show-<id>.json
--   close      -> {}
--   anything else (list) -> $FAKE_DIR/list.json
-- ready.json and search.json deliberately hold beads that are NOT in list.json, so a source that
-- filters the store instead of calling bd cannot pass.

local cli = require("beads.cli")
local store = require("beads.store")

local M = {}

M.plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local FAKE_BD = [[#!/bin/sh
echo "$*" >> "$FAKE_DIR/args.log"
prev=""
for a in "$@"; do
  case "$a" in
    ready) cat "$FAKE_DIR/ready.json"; exit 0 ;;
    search) cat "$FAKE_DIR/search.json"; exit 0 ;;
    close) echo '{}'; exit 0 ;;
  esac
  if [ "$prev" = "show" ]; then
    if [ -f "$FAKE_DIR/show-$a.json" ]; then
      cat "$FAKE_DIR/show-$a.json"
    else
      echo '[]'
    fi
    exit 0
  fi
  prev="$a"
done
cat "$FAKE_DIR/list.json"
]]

function M.bead(id, title, extra)
  local b = {
    id = id,
    title = title,
    status = "open",
    priority = 2,
    issue_type = "task",
    updated_at = "2026-11-17T10:00:00Z",
    created_at = "2026-11-17T10:00:00Z",
  }
  for k, v in pairs(extra or {}) do
    b[k] = v
  end
  return b
end

local bead = M.bead

-- Store contents (bd list --all).
M.LIST = {
  bead("op-a", "Open alpha", {
    priority = 1,
    labels = { "human" },
    metadata = { verdict = "CLEAN" },
    description = "Alpha description text",
  }),
  bead("ip-b", "In progress bravo", { status = "in_progress", labels = { "needs-review" } }),
  bead("cl-c", "Closed charlie", { status = "closed" }),
  bead("bk-d", "Blocked delta", { status = "blocked" }),
  bead("df-e", "Deferred echo", { status = "deferred" }),
  bead("ep-f", "Epic foxtrot", { issue_type = "epic", priority = 0, labels = { "other" } }),
  bead("ot-g", "Other golf", { labels = { "misc" } }),
}

M.READY = {
  bead("rd-h", "Ready hotel"),
  bead("rd-i", "Ready india", { priority = 3 }),
}

M.SEARCH = {
  bead("sr-j", "Search juliet"),
}

M.EXPECTED = {
  list = { "op-a", "ip-b", "ep-f", "ot-g" },
  ready = { "rd-h", "rd-i" },
  search = { "sr-j" },
  needs = { "op-a", "ip-b" },
  epics = { "ep-f" },
}

function M.by_id(id)
  for _, set in ipairs({ M.LIST, M.READY, M.SEARCH }) do
    for _, b in ipairs(set) do
      if b.id == id then
        return b
      end
    end
  end
end

local state = {}

function M.setup()
  if vim.fn.exists(":Beads") ~= 2 then
    vim.cmd.source(M.plugin_root .. "/plugin/beads.lua")
  end
  state.orig_path = vim.env.PATH
  state.bin_dir = vim.fn.tempname()
  vim.fn.mkdir(state.bin_dir, "p")
  vim.fn.writefile(vim.split(FAKE_BD, "\n"), state.bin_dir .. "/bd")
  vim.fn.setfperm(state.bin_dir .. "/bd", "rwxr-xr-x")
  state.fake_dir = vim.fn.tempname()
  vim.fn.mkdir(state.fake_dir, "p")
  local function write(name, data)
    vim.fn.writefile({ vim.json.encode(data) }, state.fake_dir .. "/" .. name)
  end
  write("list.json", M.LIST)
  write("ready.json", M.READY)
  write("search.json", M.SEARCH)
  for _, set in ipairs({ M.LIST, M.READY, M.SEARCH }) do
    for _, b in ipairs(set) do
      write("show-" .. b.id .. ".json", { b })
    end
  end
  vim.env.FAKE_DIR = state.fake_dir
  vim.env.PATH = state.bin_dir .. ":" .. state.orig_path
  state.root = vim.fn.tempname()
  vim.fn.mkdir(state.root, "p")
  cli.set_root(state.root)
  state.orig_select = vim.ui.select
  state.orig_input = vim.ui.input
  state.orig_fzf_loaded = package.loaded["fzf-lua"]
  state.orig_fzf_preload = package.preload["fzf-lua"]
  -- prefill the store so sources may read it either way (cached or refreshed)
  local done = false
  store.refresh(state.root, function()
    done = true
  end)
  assert(vim.wait(2000, function()
    return done
  end, 10), "store prefill never completed")
end

function M.teardown()
  pcall(vim.cmd, "silent! tabonly!")
  pcall(vim.cmd, "silent! only!")
  pcall(vim.cmd, "enew!")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= vim.api.nvim_get_current_buf() then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  vim.wait(100, function()
    return false
  end, 10)
  vim.ui.select = state.orig_select
  vim.ui.input = state.orig_input
  package.loaded["fzf-lua"] = state.orig_fzf_loaded
  package.preload["fzf-lua"] = state.orig_fzf_preload
  require("beads").setup({})
  pcall(vim.fn.delete, state.root, "rf")
  cli.set_root(nil)
  vim.env.PATH = state.orig_path
  vim.fn.delete(state.bin_dir, "rf")
  vim.fn.delete(state.fake_dir, "rf")
end

function M.args_log()
  local path = state.fake_dir .. "/args.log"
  if vim.fn.filereadable(path) == 0 then
    return {}
  end
  return vim.fn.readfile(path)
end

function M.strip(s)
  return (tostring(s):gsub("\27%[[%d;]*m", ""))
end

-- Id at the start of a picker line (after stripping ANSI codes and leading blanks).
function M.line_id(line)
  return M.strip(line):match("^%s*([%w%-%._]+)")
end

function M.ids_of(lines)
  local out = {}
  for _, l in ipairs(lines) do
    out[#out + 1] = M.line_id(l)
  end
  table.sort(out)
  return out
end

function M.sorted(list)
  local c = vim.list_extend({}, list)
  table.sort(c)
  return c
end

function M.wait_buf(name)
  return vim.wait(2000, function()
    return vim.api.nvim_buf_get_name(0) == name
  end, 10)
end

return M
