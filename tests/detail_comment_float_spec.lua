-- Bead beads_nvim-ge7.11: detail buffer note and comment floats.
-- Interface under test (public entry points only):
--   * In a loaded beads://<id> buffer, buffer-local normal-mode 'n' opens a floating window
--     (it becomes the current window, nvim_win_get_config().relative ~= "") on a scratch buffer.
--     The user types the text into that buffer; confirm with <C-s> (normal mode) or :w in the float.
--     On confirm with non-empty text: 'bd update <id> --append-notes <text>', float closes,
--     the detail buffer reloads and shows the text in its Notes section.
--   * 'c' does the same with 'bd comment' (or 'bd comments add'); the text shows in Comments.
--   * Empty text on confirm: no bd call.
--   * Detail buffer modified (EDIT mode, beads_nvim-4gx.8): n/c open no float and make no bd call.
--   * q or <Esc> in normal mode in the float closes it without a bd call.
-- The bd root is taken from beads.cli (cli.set_root).

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local helpers = require("tests.helpers")
local cli = require("beads.cli")

-- detail_note_float_spec.lua (KEY "n") and detail_comment_float_spec.lua (KEY "c") are twins, split to fit plenary's per-file timeout.
local KEY = "c"
local TIMEOUT = 15000

local function bd(dir, args)
  local argv = { "bd", "-C", dir }
  vim.list_extend(argv, args)
  local r = vim.system(argv, { text = true }):wait()
  assert.are.equal(0, r.code, "bd " .. table.concat(args, " ") .. " failed: " .. tostring(r.stderr))
  return r.stdout
end

local function raw_show(dir, id)
  return vim.json.decode(bd(dir, { "show", id, "--json" }))[1]
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

-- Index of the first line equal to `line` strictly between headings `from` and the next "## " heading.
local function line_in_section(buf, heading, line)
  local inside = false
  for _, l in ipairs(buf_lines(buf)) do
    if l == heading then
      inside = true
    elseif inside and vim.startswith(l, "## ") then
      return false
    elseif inside and l == line then
      return true
    end
  end
  return false
end

local function wait_for(fn, msg)
  local ok = vim.wait(TIMEOUT, function()
    local pok, v = pcall(fn)
    return pok and v
  end, 20)
  assert.is_true(ok, "timed out waiting for: " .. msg)
end

local function is_float(win)
  return vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative ~= ""
end

local function floats()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if is_float(w) then
      out[#out + 1] = w
    end
  end
  return out
end

local function close_floats()
  for _, w in ipairs(floats()) do
    pcall(vim.api.nvim_win_close, w, true)
  end
end

-- Spies (pass-through) on vim.system and vim.notify.
local calls, notes
local orig_system, orig_notify

local function start_spies()
  calls, notes = {}, {}
  orig_system, orig_notify = vim.system, vim.notify
  vim.system = function(cmd, opts, on_exit)
    if type(cmd) == "table" then
      calls[#calls + 1] = vim.deepcopy(cmd)
    end
    return orig_system(cmd, opts, on_exit)
  end
  vim.notify = function(msg, level, opts)
    notes[#notes + 1] = { msg = tostring(msg), level = level }
    return orig_notify(msg, level, opts)
  end
end

local function stop_spies()
  if orig_system then
    vim.system = orig_system
  end
  if orig_notify then
    vim.notify = orig_notify
  end
  orig_system, orig_notify = nil, nil
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
      return a, i
    end
  end
end

-- bd calls that mutate a bead (anything other than read-only show/list/ready/search/context).
local READ_ONLY = { show = true, list = true, ready = true, search = true, context = true }
local function mutating_calls()
  local out = {}
  for _, argv in ipairs(calls) do
    local sub = subcommand(argv)
    if sub and not READ_ONLY[sub] then
      out[#out + 1] = argv
    end
  end
  return out
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
  pcall(vim.cmd, "stopinsert")
  close_floats()
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

-- Presses key in the detail window and returns the float window/buffer that opened.
local function open_float(key)
  vim.cmd.normal(key)
  vim.cmd("stopinsert")
  local win = vim.api.nvim_get_current_win()
  assert.is_true(is_float(win), "pressing '" .. key .. "' did not open a float as the current window")
  return win, vim.api.nvim_win_get_buf(win)
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

describe("beads detail " .. KEY .. " float", function()
  if not helpers.has_bd() then
    pending("bd executable not found")
    return
  end

  if vim.fn.exists(":Beads") ~= 2 then
    vim.cmd.source(root .. "/plugin/beads.lua")
  end

  if KEY == "n" then
  it("n + text + :w appends the note via bd update --append-notes and Notes shows it", function()
    in_repo(function(dir)
      local id = create(dir, "Note me")
      local buf = open(id, "Note me")
      local win, fbuf = open_float("n")
      vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { "first appended note" })
      vim.api.nvim_set_current_win(win)
      vim.cmd.write()

      wait_for(function()
        return line_in_section(buf, "## Notes", "first appended note") and not vim.bo[buf].modified
      end, "note in the Notes section after reload")
      assert.equals("first appended note", vim.trim(raw_show(dir, id).notes or ""))

      local found = false
      for _, argv in ipairs(calls_of("update")) do
        if vim.tbl_contains(argv, id) and vim.tbl_contains(argv, "--append-notes") then
          found = true
        end
      end
      assert.is_true(found, "no 'bd update " .. id .. " --append-notes' call: " .. vim.inspect(calls))
      assert.is_false(vim.api.nvim_win_is_valid(win), "float still open after confirm")
    end)
  end)

  it("n + text + <C-s> appends to existing notes", function()
    in_repo(function(dir)
      local id = create(dir, "Note twice")
      bd(dir, { "update", id, "--notes", "existing note" })
      local buf = open(id, "Note twice")
      local win, fbuf = open_float("n")
      vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { "added by ctrl-s" })
      vim.api.nvim_set_current_win(win)
      press("<C-s>")

      wait_for(function()
        return line_in_section(buf, "## Notes", "added by ctrl-s") and not vim.bo[buf].modified
      end, "appended note in the Notes section after reload")
      assert.is_true(line_in_section(buf, "## Notes", "existing note"), "existing note lost")
    end)
  end)

  end

  if KEY == "c" then
  it("c + text + :w adds a comment shown in Comments", function()
    in_repo(function(dir)
      local id = create(dir, "Comment me")
      local buf = open(id, "Comment me")
      local win, fbuf = open_float("c")
      vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { "a float comment body" })
      vim.api.nvim_set_current_win(win)
      vim.cmd.write()

      wait_for(function()
        return line_in_section(buf, "## Comments", "a float comment body") and not vim.bo[buf].modified
      end, "comment in the Comments section after reload")
      assert.equals(0, #calls_of("update"), "comment must not run bd update: " .. vim.inspect(calls))
      assert.is_true(#calls_of("comment") + #calls_of("comments") > 0, "no bd comment call: " .. vim.inspect(calls))
      assert.is_false(vim.api.nvim_win_is_valid(win), "float still open after confirm")
    end)
  end)

  it("c + text + <C-s> adds a comment", function()
    in_repo(function(dir)
      local id = create(dir, "Comment ctrl-s")
      local buf = open(id, "Comment ctrl-s")
      local win, fbuf = open_float("c")
      vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { "ctrl-s comment" })
      vim.api.nvim_set_current_win(win)
      press("<C-s>")

      wait_for(function()
        return line_in_section(buf, "## Comments", "ctrl-s comment")
      end, "comment in the Comments section after reload")
    end)
  end)

  end

  for _, key in ipairs({ KEY }) do
    it(key .. " with empty text on confirm makes no bd call", function()
      in_repo(function(dir)
        local id = create(dir, "Empty " .. key)
        open(id, "Empty " .. key)
        local win, fbuf = open_float(key)
        vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { "" })
        calls = {}
        vim.api.nvim_set_current_win(win)
        vim.cmd.write()
        vim.wait(300)
        assert.same({}, mutating_calls(), "bd called for empty text")
      end)
    end)

    -- beads_nvim-4gx.8 (owner-approved change): a detail buffer can only be modified in EDIT mode,
    -- where n / c are plain Vim keys. They must open no float, make no bd call and keep the edits.
    it(key .. " in edit mode with unsaved edits opens no float and makes no bd call", function()
      in_repo(function(dir)
        local id = create(dir, "Dirty " .. key)
        local buf = open(id, "Dirty " .. key)
        if not vim.bo[buf].modifiable then
          vim.cmd.normal("e")
        end
        vim.cmd("stopinsert")
        vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "unsaved edit" })
        assert.is_true(vim.bo[buf].modified)
        calls, notes = {}, {}
        vim.fn.setreg("/", "unsaved edit")
        pcall(vim.cmd.normal, key)
        vim.cmd("stopinsert")
        vim.wait(300)

        assert.same({}, floats(), "a float opened on a modified buffer")
        assert.equals(buf, vim.api.nvim_get_current_buf())
        assert.same({}, mutating_calls(), "bd called on a modified buffer")
        assert.is_true(has_line(buf, "unsaved edit"), "unsaved edit lost")
      end)
    end)

    for _, cancel in ipairs({ "q", "<Esc>" }) do
      it(key .. " then " .. cancel .. " in normal mode closes the float without a bd call", function()
        in_repo(function(dir)
          local id = create(dir, "Cancel " .. key .. cancel)
          local buf = open(id, "Cancel " .. key .. cancel)
          local win, fbuf = open_float(key)
          vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { "text that must not be sent" })
          calls = {}
          vim.api.nvim_set_current_win(win)
          vim.cmd("stopinsert")
          press(cancel)
          vim.wait(300)

          assert.is_false(vim.api.nvim_win_is_valid(win), "float still open after " .. cancel)
          assert.same({}, mutating_calls(), "bd called after cancel")
          assert.is_true(vim.api.nvim_buf_is_valid(buf))
          local b = raw_show(dir, id)
          assert.is_true(b.notes == nil or b.notes == "", "note was written on cancel")
        end)
      end)
    end
  end

  it("cleanup: removes the shared temp repo", function()
    if shared_dir then
      vim.fn.delete(shared_dir, "rf")
      shared_dir = nil
    end
  end)
end)
