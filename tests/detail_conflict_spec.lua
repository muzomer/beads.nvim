-- Bead beads_nvim-ge7.9: detail buffer conflict detection and external-change warning.
-- Interface under test (public entry points only):
--   * :w on beads://<id> re-fetches the bead; if its updated_at differs from the one seen at load,
--     no 'bd update' runs and a choice is offered through vim.ui.select with items labelled
--     reload / force / diff (matched case-insensitively; opts.format_item honoured if given).
--       reload -> edits discarded, server version shown, 'modified' off.
--       force  -> the edits are applied to bd.
--       diff   -> a split opens with the current server rendering; 'diff' set on both windows.
--   * The detail buffer listens to beads.store for its root: when a store refresh delivers the bead
--     with a different updated_at, an unmodified buffer reloads; a modified buffer keeps its edits
--     and gets a virtual-text (virt_text or virt_lines extmark) warning.
-- The bd root is taken from beads.cli (cli.set_root).

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local helpers = require("tests.helpers")
local cli = require("beads.cli")
local model = require("beads.model")
local store = require("beads.store")

local TIMEOUT = 8000

local function bd(dir, args)
  local argv = { "bd", "-C", dir }
  vim.list_extend(argv, args)
  local r = vim.system(argv, { text = true }):wait()
  assert.are.equal(0, r.code, "bd " .. table.concat(args, " ") .. " failed: " .. tostring(r.stderr))
  return r.stdout
end

local function show(dir, id)
  return model.normalize(vim.json.decode(bd(dir, { "show", id, "--json" }))[1])
end

local function create(dir, title, extra)
  local args = { "create", title, "--silent" }
  vim.list_extend(args, extra or {})
  return vim.trim(bd(dir, args))
end

local function buf_lines(buf)
  return vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)
end

local function has_line(buf, line)
  return vim.tbl_contains(buf_lines(buf), line)
end

-- beads_nvim-4gx.8: detail buffers open read-only (VIEW mode); `e` switches to EDIT mode.
local function ensure_edit(buf)
  if not vim.bo[buf].modifiable then
    vim.api.nvim_buf_call(buf, function()
      vim.cmd.normal("e")
    end)
  end
end

local function set_line(buf, pred, new)
  ensure_edit(buf)
  local lines = buf_lines(buf)
  for i, l in ipairs(lines) do
    if pred(l) then
      vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { new })
      return
    end
  end
  error("no matching line to edit")
end

local function wait_for(fn, msg, timeout)
  local ok = vim.wait(timeout or TIMEOUT, function()
    local pok, v = pcall(fn)
    return pok and v
  end, 20)
  assert.is_true(ok, "timed out waiting for: " .. msg)
end

-- Pass-through spy on vim.system; stub on vim.ui.select that records and defers the choice.
local calls
local orig_system, orig_select
local select_req -- { items, opts, on_choice }

local function start_spies()
  calls, select_req = {}, nil
  orig_system, orig_select = vim.system, vim.ui.select
  vim.system = function(cmd, opts, on_exit)
    if type(cmd) == "table" then
      calls[#calls + 1] = vim.deepcopy(cmd)
    end
    return orig_system(cmd, opts, on_exit)
  end
  vim.ui.select = function(items, opts, on_choice)
    select_req = { items = items, opts = opts or {}, on_choice = on_choice }
  end
end

local function stop_spies()
  if orig_system then
    vim.system = orig_system
  end
  if orig_select then
    vim.ui.select = orig_select
  end
  orig_system, orig_select = nil, nil
end

local function subcommand(argv)
  if argv[1] ~= "bd" then
    return nil
  end
  local i = 2
  while i <= #argv do
    local a = argv[i]
    if a == "-C" or a == "--db" then
      i = i + 2
    elseif vim.startswith(a, "-") then
      i = i + 1
    else
      return a
    end
  end
end

local function calls_of(sub)
  local out = {}
  for _, argv in ipairs(calls) do
    if subcommand(argv) == sub then
      out[#out + 1] = argv
    end
  end
  return out
end

local function choose(word)
  assert(select_req, "no vim.ui.select prompt")
  local fmt = select_req.opts.format_item or tostring
  local labels = {}
  for i, item in ipairs(select_req.items) do
    local label = fmt(item)
    labels[#labels + 1] = label
    if tostring(label):lower():find(word, 1, true) then
      select_req.on_choice(item, i)
      return
    end
  end
  error("no '" .. word .. "' choice among " .. vim.inspect(labels))
end

local function wipe_beads_buffers()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.startswith(vim.api.nvim_buf_get_name(b), "beads://") then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
end

local shared_dir

local function repo()
  if not shared_dir then
    shared_dir = vim.fn.tempname()
    vim.fn.mkdir(shared_dir, "p")
    local res = vim.system({ "bd", "init", "--non-interactive" }, { cwd = shared_dir, text = true }):wait()
    assert(res.code == 0, "bd init failed: " .. tostring(res.stderr))
  end
  return shared_dir
end

local function in_repo(fn)
  local dir = repo()
  local saved = cli.get_root_override()
  cli.set_root(dir)
  start_spies()
  local ok, err = pcall(fn, dir)
  stop_spies()
  pcall(vim.cmd, "silent! diffoff!")
  pcall(vim.cmd, "silent! only!")
  vim.cmd("silent! enew!")
  wipe_beads_buffers()
  cli.set_root(saved)
  if not ok then
    error(err, 0)
  end
end

local function open(id, title)
  assert(#vim.api.nvim_get_autocmds({ event = "BufReadCmd", pattern = "beads://*" }) > 0, "no beads:// BufReadCmd")
  vim.cmd.edit(vim.fn.fnameescape("beads://" .. id))
  local buf = vim.api.nvim_get_current_buf()
  wait_for(function()
    return has_line(buf, "# " .. title) and not vim.bo[buf].modified
  end, "beads://" .. id .. " to load")
  return buf
end

-- updated_at has one-second resolution: make sure the external change gets a new timestamp.
local function external_update(dir, id, args)
  vim.wait(1100)
  local argv = { "update", id }
  vim.list_extend(argv, args)
  bd(dir, argv)
  calls = {}
end

-- Opens a bead, edits its title in the buffer, changes its priority externally, then :w.
-- Waits until either the prompt appears or a bd update is issued, and asserts the prompt won.
local function conflicting_write(dir, title)
  local id = create(dir, title, { "-p", "2" })
  local buf = open(id, title)
  set_line(buf, function(l)
    return l == "# " .. title
  end, "# " .. title .. " edited")
  external_update(dir, id, { "-p", "3" })
  vim.api.nvim_set_current_buf(buf)
  vim.cmd.write()
  wait_for(function()
    return select_req ~= nil or #calls_of("update") > 0
  end, "conflict prompt or bd update after :w")
  assert.is_not_nil(select_req, "write was not refused: bd update ran: " .. vim.inspect(calls_of("update")))
  return id, buf
end

local function virt_text_marks(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    local d = m[4] or {}
    if d.virt_text or d.virt_lines then
      out[#out + 1] = m
    end
  end
  return out
end

local function refresh_store(dir)
  local done = false
  store.refresh(dir, function()
    done = true
  end)
  wait_for(function()
    return done
  end, "store refresh")
end

describe("beads detail buffer conflicts", function()
  if not helpers.has_bd() then
    pending("bd executable not found")
    return
  end

  if vim.fn.exists(":Beads") ~= 2 then
    vim.cmd.source(root .. "/plugin/beads.lua")
  end

  it(":w after an external change refuses the write and prompts reload/force/diff", function()
    in_repo(function(dir)
      local title = "Conflict refused"
      local id, buf = conflicting_write(dir, title)
      for _, word in ipairs({ "reload", "force", "diff" }) do
        local fmt = select_req.opts.format_item or tostring
        local found = false
        for _, item in ipairs(select_req.items) do
          if tostring(fmt(item)):lower():find(word, 1, true) then
            found = true
          end
        end
        assert.is_true(found, "prompt has no '" .. word .. "' choice")
      end
      vim.wait(300)
      assert.equals(0, #calls_of("update"), "bd update ran: " .. vim.inspect(calls_of("update")))
      assert.equals(title, show(dir, id).title)
      assert.is_true(has_line(buf, "# " .. title .. " edited"), "edits lost")
      assert.is_true(vim.bo[buf].modified, "buffer no longer modified")
    end)
  end)

  it("choosing reload discards edits and shows the server version", function()
    in_repo(function(dir)
      local title = "Conflict reload"
      local id, buf = conflicting_write(dir, title)
      choose("reload")
      wait_for(function()
        return has_line(buf, "# " .. title) and has_line(buf, "priority: 3") and not vim.bo[buf].modified
      end, "server version in buffer, modified off")
      assert.is_false(has_line(buf, "# " .. title .. " edited"))
      local after = show(dir, id)
      assert.equals(title, after.title)
      assert.equals(3, after.priority)
    end)
  end)

  it("choosing force applies the edits", function()
    in_repo(function(dir)
      local title = "Conflict force"
      local id = conflicting_write(dir, title)
      choose("force")
      wait_for(function()
        return show(dir, id).title == title .. " edited"
      end, "edited title in bd")
    end)
  end)

  it("choosing diff opens a split with the server version, diff on both windows", function()
    in_repo(function(dir)
      local title = "Conflict diff"
      local _, buf = conflicting_write(dir, title)
      local orig_win = vim.fn.bufwinid(buf)
      local before = #vim.api.nvim_tabpage_list_wins(0)
      choose("diff")

      local server_win
      wait_for(function()
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          local b = vim.api.nvim_win_get_buf(w)
          if b ~= buf and has_line(b, "priority: 3") and has_line(b, "# " .. title) then
            server_win = w
            return true
          end
        end
      end, "split showing the server rendering")
      assert.equals(before + 1, #vim.api.nvim_tabpage_list_wins(0))
      orig_win = vim.fn.bufwinid(buf)
      assert.is_true(orig_win ~= -1, "detail buffer no longer in a window")
      assert.is_true(vim.wo[server_win].diff, "'diff' not set on server window")
      assert.is_true(vim.wo[orig_win].diff, "'diff' not set on detail window")
      assert.is_true(has_line(buf, "# " .. title .. " edited"), "edits lost")
      assert.is_true(vim.bo[buf].modified)
    end)
  end)

  it("unmodified buffer reloads when the store reports the bead changed", function()
    in_repo(function(dir)
      local title = "Store reload"
      local id = create(dir, title)
      local buf = open(id, title)
      external_update(dir, id, { "--title", title .. " external" })
      refresh_store(dir)
      wait_for(function()
        return has_line(buf, "# " .. title .. " external") and not vim.bo[buf].modified
      end, "automatic reload after store change", 3000)
    end)
  end)

  it("modified buffer gets a virtual-text warning on store change and keeps its edits", function()
    in_repo(function(dir)
      local title = "Store warn"
      local id = create(dir, title)
      local buf = open(id, title)
      set_line(buf, function(l)
        return l == "# " .. title
      end, "# " .. title .. " local")
      assert.equals(0, #virt_text_marks(buf), "virtual text present before any change")
      external_update(dir, id, { "--title", title .. " external" })
      refresh_store(dir)
      wait_for(function()
        return #virt_text_marks(buf) > 0
      end, "virtual-text warning on modified buffer", 3000)
      vim.wait(500)
      assert.is_true(has_line(buf, "# " .. title .. " local"), "edits lost")
      assert.is_false(has_line(buf, "# " .. title .. " external"), "buffer was reloaded")
      assert.is_true(vim.bo[buf].modified)
    end)
  end)

  it("cleanup: removes the shared temp repo", function()
    if shared_dir then
      vim.fn.delete(shared_dir, "rf")
      shared_dir = nil
    end
  end)
end)
