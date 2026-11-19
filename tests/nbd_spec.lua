-- Bead beads_nvim-0fq: bin/nbd, a command-line launcher that opens the beads tree and quits
-- nvim when the tree closes.
-- Interface under test:
--   bin/nbd [dir]   runs `${NBD_NVIM:-nvim} -c "luafile <temp lua>"`; the Lua registers a
--                   FileType beads-tree autocmd that quits nvim (scheduled `qa`, pcall) when the
--                   tree buffer is wiped, then runs :Beads tree. With <dir>, nbd cd's there first.
--                   The temp file is removed on exit. Works when run through a symlink.
-- Harness: NBD_NVIM points at a wrapper script that execs a headless, isolated nvim (own XDG
-- dirs, plugin root prepended to the default rtp, no setup() call) with a test init. The init waits for
-- the tree to show the bead, then presses q in it (mode "quit"), or first opens the bead with
-- <CR>, edits the detail and then presses q (mode "dirty"). It writes what it sees to a JSON-lines
-- file. `bd` is a fake on PATH: `show <id>` prints one bead, anything else the list.
-- assumption: "shortly" = nvim exits within 5 s of the q press.
-- assumption: README documents nbd under a heading that contains "nbd"; that section names
--   `bin/nbd`, `ln -s`, PATH and quitting (case-insensitive "quit").

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local bin = plugin_root .. "/bin/nbd"

local FAKE_BD = [[#!/bin/sh
echo "$*" >> "$NBD_TEST_DIR/bd_calls"
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
local plugin_root = vim.env.NBD_TEST_PLUGIN
-- The default rtp (XDG dirs are isolated by the test) plus the plugin.
vim.opt.runtimepath:prepend(plugin_root)
vim.o.swapfile = false
vim.o.shada = ""

local out = vim.env.NBD_TEST_DIR .. "/out.jsonl"
local function emit(t)
  local f = io.open(out, "a")
  f:write(vim.json.encode(t) .. "\n")
  f:close()
end

-- The luafile path nbd passed, from the argv.
local luafile
for i, a in ipairs(vim.v.argv) do
  local p = a:match("^luafile%s+(.+)$")
  if p then
    luafile = vim.trim(p)
  end
  if a == "-c" and vim.v.argv[i + 1] then
    local q = vim.v.argv[i + 1]:match("^luafile%s+(.+)$")
    if q then
      luafile = vim.trim(q)
    end
  end
end
emit({ ev = "start", argv = vim.v.argv, luafile = luafile, cwd = vim.fn.getcwd() })

local function now()
  local s, us = vim.uv.gettimeofday()
  return s + us / 1e6
end

local function fail(reason)
  emit({ ev = "fail", reason = reason })
  vim.cmd("cq 9")
end

-- Polls cond every 50 ms; gives up after `ms` with cq 9.
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

local function row_of(buf, needle)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:find(needle, 1, true) then
      return i
    end
  end
end

local function detail_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == "beads://nb-1" then
      return b
    end
  end
end

local function press_q(tw)
  vim.api.nvim_set_current_win(tw)
  local row = row_of(vim.api.nvim_win_get_buf(tw), "nb-1")
  if row then
    vim.api.nvim_win_set_cursor(tw, { row, 0 })
  end
  emit({ ev = "q", t = now() })
  vim.api.nvim_feedkeys("q", "x", false)
end

local mode = vim.env.NBD_TEST_MODE

-- Watchdog: never outlive the test.
vim.defer_fn(function()
  fail("watchdog: still running after 15 s")
end, 15000)

-- Waits for the tree (opened by nbd's :Beads tree) to show the test bead.
wait_for("the tree with bead nb-1", function()
  local w = tree_win()
  return w and row_of(vim.api.nvim_win_get_buf(w), "nb-1") and w
end, 10000, function(tw)
  emit({ ev = "tree", cwd = vim.fn.getcwd() })
  if mode ~= "dirty" then
    return press_q(tw)
  end
  vim.api.nvim_set_current_win(tw)
  vim.api.nvim_win_set_cursor(tw, { row_of(vim.api.nvim_win_get_buf(tw), "nb-1"), 0 })
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  wait_for("the loaded detail of nb-1", function()
    local b = detail_buf()
    return b and vim.api.nvim_buf_is_loaded(b) and row_of(b, "Shown nb-1") and b
  end, 10000, function(db)
    -- Switch the detail to edit mode the way a user does (e in the detail window).
    local dw = vim.fn.bufwinid(db)
    if dw == -1 then
      return fail("the detail is not shown in a window")
    end
    vim.api.nvim_set_current_win(dw)
    vim.api.nvim_feedkeys("e", "x", false)
    wait_for("the detail in edit mode", function()
      return vim.bo[db].modifiable
    end, 5000, function()
      local n = vim.api.nvim_buf_line_count(db)
      vim.api.nvim_buf_set_lines(db, n, n, false, { "unsaved edit by the nbd test" })
      local tw2 = tree_win()
      if not tw2 then
        return fail("the tree window vanished after <CR>")
      end
      emit({ ev = "edited", modified = vim.bo[db].modified })
      press_q(tw2)
      vim.defer_fn(function()
        emit({
          ev = "after",
          alive = true,
          tree = tree_win() ~= nil,
          detail_valid = vim.api.nvim_buf_is_valid(db),
          detail_modified = vim.api.nvim_buf_is_valid(db) and vim.bo[db].modified,
          messages = vim.fn.execute("messages"),
          errmsg = vim.v.errmsg,
        })
        vim.cmd("qa!")
      end, 1000)
    end)
  end)
end)
]==]

local function read_events(dir)
  local path = dir .. "/out.jsonl"
  local evs = {}
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

local function real(p)
  return vim.uv.fs_realpath(p) or p
end

describe("bin/nbd", function()
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

  -- Sets up a repo dir, the fake bd, the nvim wrapper and isolated XDG dirs.
  local function harness()
    local h = { test = tmpdir(), repo = tmpdir() }
    vim.fn.mkdir(h.repo .. "/.beads", "p")
    local bindir = h.test .. "/bin"
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
    }, h.test .. "/list.json")
    vim.fn.writefile(vim.split(INIT, "\n"), h.test .. "/init.lua")
    local nvim = vim.v.progpath
    h.wrapper = h.test .. "/fake-nvim"
    vim.fn.writefile({
      "#!/bin/sh",
      ("exec timeout -s KILL 30 '%s' --headless -n -i NONE -u '%s' \"$@\""):format(nvim, h.test .. "/init.lua"),
    }, h.wrapper)
    vim.fn.setfperm(h.wrapper, "rwxr-xr-x")
    for _, x in ipairs({ "config", "data", "state", "cache" }) do
      vim.fn.mkdir(h.test .. "/xdg/" .. x, "p")
    end
    h.env = {
      NBD_NVIM = h.wrapper,
      NBD_TEST_DIR = h.test,
      NBD_TEST_PLUGIN = plugin_root,
      PATH = bindir .. ":" .. vim.env.PATH,
      XDG_CONFIG_HOME = h.test .. "/xdg/config",
      XDG_DATA_HOME = h.test .. "/xdg/data",
      XDG_STATE_HOME = h.test .. "/xdg/state",
      XDG_CACHE_HOME = h.test .. "/xdg/cache",
    }
    return h
  end

  -- Runs nbd (or `cmd`) with args from cwd; returns the result, events and a diagnostic string.
  local function run(h, opts)
    local env = vim.deepcopy(h.env)
    env.NBD_TEST_MODE = opts.mode or "quit"
    local cmd = { opts.cmd or bin }
    vim.list_extend(cmd, opts.args or {})
    local r = vim.system(cmd, { cwd = opts.cwd, env = env, text = true, stdin = false }):wait(40000)
      or { code = -1, signal = -1, stderr = "(vim.system wait timed out)" }
    local s, us = vim.uv.gettimeofday()
    local t_exit = s + us / 1e6
    local evs = read_events(h.test)
    local diag = ("code=%s signal=%s\nstderr:\n%s\nstdout:\n%s\nevents:\n%s"):format(
      tostring(r.code),
      tostring(r.signal),
      r.stderr or "",
      r.stdout or "",
      vim.inspect(evs)
    )
    return r, evs, diag, t_exit
  end

  local function assert_clean_quit(r, evs, diag, t_exit)
    assert(r.code == 0 and (r.signal or 0) == 0, "nvim did not exit with 0:\n" .. diag)
    assert(find(evs, "fail") == nil, "the test init gave up:\n" .. diag)
    local q = find(evs, "q")
    assert(q, "q was never pressed in the tree:\n" .. diag)
    assert(t_exit - q.t < 5, ("nvim took %.1f s to exit after q:\n%s"):format(t_exit - q.t, diag))
    local stderr = r.stderr or ""
    assert(not stderr:find("Error", 1, true) and not stderr:find("E%d+:"), "errors on stderr:\n" .. diag)
  end

  it("exists and is executable", function()
    assert.are.equal(1, vim.fn.filereadable(bin), "bin/nbd is missing")
    assert.are.equal(1, vim.fn.executable(bin), "bin/nbd is not executable")
  end)

  it("opens the tree through NBD_NVIM and nvim exits 0 shortly after q closes the tree", function()
    local h = harness()
    local r, evs, diag, t_exit = run(h, { cwd = h.repo })
    assert(find(evs, "start"), "NBD_NVIM was not used (the wrapper never started):\n" .. diag)
    assert(find(evs, "tree"), "the tree never showed the bead:\n" .. diag)
    assert_clean_quit(r, evs, diag, t_exit)
    assert.are.equal(real(h.repo), real(find(evs, "tree").cwd), diag)
  end)

  it("passes the snippet as -c 'luafile <temp lua>' and removes the temp file on exit", function()
    local h = harness()
    local r, evs, diag, t_exit = run(h, { cwd = h.repo })
    assert_clean_quit(r, evs, diag, t_exit)
    local start = find(evs, "start")
    assert(start and start.luafile, "nvim was not given -c 'luafile <file>':\n" .. diag)
    assert(start.luafile:match("%.lua$"), "the luafile is not a .lua file: " .. start.luafile)
    assert.are.equal(0, vim.fn.filereadable(start.luafile), "temp lua file left behind: " .. start.luafile)
  end)

  it("nbd <dir> changes to <dir> before opening the tree", function()
    local h = harness()
    local elsewhere = tmpdir()
    local r, evs, diag, t_exit = run(h, { cwd = elsewhere, args = { h.repo } })
    assert_clean_quit(r, evs, diag, t_exit)
    assert.are.equal(real(h.repo), real(find(evs, "start").cwd), diag)
    assert.are.equal(real(h.repo), real(find(evs, "tree").cwd), diag)
  end)

  it("works when run through a symlink", function()
    local h = harness()
    local linkdir = tmpdir()
    local link = linkdir .. "/nbd"
    assert(vim.uv.fs_symlink(bin, link), "could not create the symlink")
    local elsewhere = tmpdir()
    local r, evs, diag, t_exit = run(h, { cmd = link, cwd = elsewhere, args = { h.repo } })
    assert_clean_quit(r, evs, diag, t_exit)
    assert.are.equal(real(h.repo), real(find(evs, "tree").cwd), diag)
  end)

  it("keeps nvim open without errors when a detail with unsaved edits is left open", function()
    local h = harness()
    local r, evs, diag = run(h, { cwd = h.repo, mode = "dirty" })
    assert(find(evs, "fail") == nil, "the test init gave up:\n" .. diag)
    local edited = find(evs, "edited")
    assert(edited and edited.modified, "the detail was not modified before q:\n" .. diag)
    local after = find(evs, "after")
    assert(after, "nvim quit although the detail had unsaved edits:\n" .. diag)
    assert.is_false(after.tree, "the tree did not close:\n" .. diag)
    assert.is_true(after.detail_valid and after.detail_modified, "the unsaved detail was lost:\n" .. diag)
    assert(not after.messages:find("E%d+:"), "an error escaped into :messages:\n" .. diag)
    assert(not after.messages:find("Error", 1, true), "an error escaped into :messages:\n" .. diag)
    local stderr = r.stderr or ""
    assert(not stderr:find("Error", 1, true) and not stderr:find("E%d+:"), "errors on stderr:\n" .. diag)
    assert(r.code == 0 and (r.signal or 0) == 0, "nvim did not exit cleanly after qa!:\n" .. diag)
  end)
end)

describe("README", function()
  it("documents nbd: usage, putting it on PATH and the quit behaviour", function()
    local lines = vim.fn.readfile(plugin_root .. "/README.md")
    local out, inside, level = {}, false, 0
    for _, l in ipairs(lines) do
      local hashes = l:match("^(#+)%s")
      if hashes and inside and #hashes <= level then
        break
      elseif hashes and not inside then
        inside = l:find("nbd", 1, true) ~= nil
        level = #hashes
      elseif inside then
        out[#out + 1] = l
      end
    end
    assert(inside, "README.md has no heading mentioning nbd")
    local text = table.concat(out, "\n")
    assert(text:find("bin/nbd", 1, true), "the nbd section does not name bin/nbd")
    assert(text:find("ln -s", 1, true), "the nbd section does not show ln -s")
    assert(text:find("PATH", 1, true), "the nbd section does not mention PATH")
    assert(text:lower():find("quit", 1, true), "the nbd section does not describe quitting")
  end)
end)
