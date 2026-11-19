-- Findings for bead beads_nvim-0fq (blocker bin/nbd:30): nbd must not quit nvim when the tree is
-- replaced by a new tree (the layout key L, or :Beads tree <pos>, closes the full-layout tree and
-- opens a new one), and it must still quit when that replacement tree is really closed with q.
-- Harness: like tests/nbd_spec.lua. NBD_NVIM points at a wrapper that execs a headless, isolated
-- nvim with a test init; `bd` is a fake on PATH. The init waits for the tree, replaces it (mode
-- "cmd": :Beads tree left; mode "key": L in the tree), waits 1 s, records whether nvim is alive
-- with a tree, then presses q in the new tree.

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local bin = plugin_root .. "/bin/nbd"

local FAKE_BD = [[#!/bin/sh
prev=""
for a in "$@"; do
  if [ "$prev" = "show" ]; then
    printf '[{"id":"%s","title":"Shown %s","description":"body","status":"open","priority":2,"issue_type":"task","created_at":"2026-11-17T10:00:00Z","updated_at":"2026-11-17T10:00:00Z"}]\n' "$a" "$a"
    exit 0
  fi
  prev="$a"
done
cat "$NBD_TEST_DIR/list.json"
]]

local INIT = [==[
vim.opt.runtimepath:prepend(vim.env.NBD_TEST_PLUGIN)
vim.o.swapfile = false
vim.o.shada = ""

local out = vim.env.NBD_TEST_DIR .. "/out.jsonl"
local function emit(t)
  local f = io.open(out, "a")
  f:write(vim.json.encode(t) .. "\n")
  f:close()
end

local function now()
  local s, us = vim.uv.gettimeofday()
  return s + us / 1e6
end

local function fail(reason)
  emit({ ev = "fail", reason = reason })
  vim.cmd("cq 9")
end

local function wait_for(what, cond, ms, then_)
  local deadline = vim.uv.now() + ms
  local function tick()
    local ok, res = pcall(cond)
    if ok and res then
      return then_(res)
    end
    if vim.uv.now() > deadline then
      return fail("timeout waiting for " .. what)
    end
    vim.defer_fn(tick, 50)
  end
  vim.defer_fn(tick, 50)
end

local function tree_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative == "" and vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "beads-tree" then
      return w
    end
  end
end

local function has_bead(w)
  for _, l in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)) do
    if l:find("nb-1", 1, true) then
      return true
    end
  end
end

vim.defer_fn(function()
  fail("watchdog: still running after 15 s")
end, 15000)

local mode = vim.env.NBD_TEST_MODE

wait_for("the tree with bead nb-1", function()
  local w = tree_win()
  return w and has_bead(w) and w
end, 10000, function(tw)
  local old_buf = vim.api.nvim_win_get_buf(tw)
  emit({ ev = "tree" })
  vim.api.nvim_set_current_win(tw)
  emit({ ev = "replace", mode = mode })
  if mode == "key" then
    vim.api.nvim_feedkeys("L", "x", false)
  else
    vim.cmd("Beads tree left")
  end
  vim.defer_fn(function()
    local w = tree_win()
    emit({ ev = "replaced", tree = w ~= nil, new_buf = w ~= nil and vim.api.nvim_win_get_buf(w) ~= old_buf })
    if not w then
      return fail("no tree after the replacement")
    end
    wait_for("the new tree with bead nb-1", function()
      local w2 = tree_win()
      return w2 and has_bead(w2) and w2
    end, 5000, function(w2)
      vim.api.nvim_set_current_win(w2)
      emit({ ev = "q", t = now() })
      vim.api.nvim_feedkeys("q", "x", false)
    end)
  end, 1000)
end)
]==]

local function read_events(dir)
  local evs = {}
  local path = dir .. "/out.jsonl"
  if vim.fn.filereadable(path) == 1 then
    for _, l in ipairs(vim.fn.readfile(path)) do
      local ok, e = pcall(vim.json.decode, l)
      if ok then
        evs[#evs + 1] = e
      end
    end
  end
  return evs
end

local function find(evs, name)
  for _, e in ipairs(evs) do
    if e.ev == name then
      return e
    end
  end
end

describe("bin/nbd with a replaced tree (findings)", function()
  local dirs = {}
  local function tmpdir()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, "p")
    dirs[#dirs + 1] = d
    return d
  end

  after_each(function()
    for _, d in ipairs(dirs) do
      vim.fn.delete(d, "rf")
    end
    dirs = {}
  end)

  local function run(mode)
    local test, repo = tmpdir(), tmpdir()
    vim.fn.mkdir(repo .. "/.beads", "p")
    local bindir = test .. "/bin"
    vim.fn.mkdir(bindir, "p")
    vim.fn.writefile(vim.split(FAKE_BD, "\n"), bindir .. "/bd")
    vim.fn.setfperm(bindir .. "/bd", "rwxr-xr-x")
    vim.fn.writefile({
      vim.json.encode({
        {
          id = "nb-1",
          title = "Nbd bead",
          status = "open",
          priority = 2,
          issue_type = "task",
          created_at = "2026-11-17T10:00:00Z",
          updated_at = "2026-11-17T10:00:00Z",
        },
      }),
    }, test .. "/list.json")
    vim.fn.writefile(vim.split(INIT, "\n"), test .. "/init.lua")
    local wrapper = test .. "/fake-nvim"
    vim.fn.writefile({
      "#!/bin/sh",
      ("exec timeout -s KILL 30 '%s' --headless -n -i NONE -u '%s' \"$@\""):format(vim.v.progpath, test .. "/init.lua"),
    }, wrapper)
    vim.fn.setfperm(wrapper, "rwxr-xr-x")
    for _, x in ipairs({ "config", "data", "state", "cache" }) do
      vim.fn.mkdir(test .. "/xdg/" .. x, "p")
    end
    local env = {
      NBD_NVIM = wrapper,
      NBD_TEST_DIR = test,
      NBD_TEST_PLUGIN = plugin_root,
      NBD_TEST_MODE = mode,
      PATH = bindir .. ":" .. vim.env.PATH,
      XDG_CONFIG_HOME = test .. "/xdg/config",
      XDG_DATA_HOME = test .. "/xdg/data",
      XDG_STATE_HOME = test .. "/xdg/state",
      XDG_CACHE_HOME = test .. "/xdg/cache",
    }
    local r = vim.system({ bin }, { cwd = repo, env = env, text = true, stdin = false }):wait(40000)
      or { code = -1, signal = -1, stderr = "(vim.system wait timed out)" }
    local s, us = vim.uv.gettimeofday()
    local t_exit = s + us / 1e6
    local evs = read_events(test)
    local diag = ("code=%s signal=%s\nstderr:\n%s\nevents:\n%s"):format(
      tostring(r.code),
      tostring(r.signal),
      r.stderr or "",
      vim.inspect(evs)
    )
    return r, evs, diag, t_exit
  end

  local function check(mode)
    local r, evs, diag, t_exit = run(mode)
    assert(find(evs, "tree"), "the tree never showed the bead:\n" .. diag)
    assert(find(evs, "replace"), "the tree was never replaced:\n" .. diag)
    local replaced = find(evs, "replaced")
    assert(replaced, "nvim quit after the tree was replaced by a new tree:\n" .. diag)
    assert(replaced.tree, "no tree is open after the replacement:\n" .. diag)
    assert(find(evs, "fail") == nil, "the test init gave up:\n" .. diag)
    local q = find(evs, "q")
    assert(q, "q was never pressed in the new tree:\n" .. diag)
    assert(r.code == 0 and (r.signal or 0) == 0, "nvim did not exit with 0 after q in the new tree:\n" .. diag)
    assert(t_exit - q.t < 5, ("nvim took %.1f s to exit after q in the new tree:\n%s"):format(t_exit - q.t, diag))
  end

  it(":Beads tree <pos> in the tree keeps nvim open; q in the new tree then quits nvim", function()
    check("cmd")
  end)

  it("the layout key L in the tree keeps nvim open; q in the new tree then quits nvim", function()
    check("key")
  end)
end)
