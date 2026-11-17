-- Argument handling for bin/beads-ask. Pure Lua over beads.questions.store;
-- runs in bare `nvim --clean -l` processes.
local M = {}

local store = require("beads.questions.store")

local FIELDS = { title = true, description = true, design = true, acceptance = true }

local USAGE = [==[
usage:
  beads-ask list [--needs agent|user] [--json]
  beads-ask show <tid> [--json]
  beads-ask reply <tid> <body|-> [--author NAME]
  beads-ask resolve <tid> [note] [--author NAME]
  beads-ask propose <tid> --field <title|description|design|acceptance> <value|-> [--author NAME]]==]

local function die(msg)
  io.stderr:write("beads-ask: " .. msg .. "\n")
  return 1
end

local function find_root()
  local env = vim.env.BEADS_NVIM_ROOT
  if env and env ~= "" then
    return env
  end
  local found = vim.fs.find(".beads", { upward = true, path = vim.uv.cwd(), limit = 1 })[1]
  if found then
    return vim.fs.dirname(found)
  end
  return nil
end

-- Splits argv into positionals and flags (--json boolean; others take a value).
local function parse(args)
  local pos, opts = {}, {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--json" then
      opts.json = true
    elseif a == "--needs" or a == "--author" or a == "--field" then
      i = i + 1
      if args[i] == nil then
        return nil, a .. " needs a value"
      end
      opts[a:sub(3)] = args[i]
    elseif a:sub(1, 2) == "--" and #a > 2 then
      return nil, "unknown option " .. a
    else
      pos[#pos + 1] = a
    end
    i = i + 1
  end
  return pos, opts
end

local function body_arg(v)
  if v == "-" then
    return ((io.read("*a") or ""):gsub("\n+$", ""))
  end
  return v
end

local function format_thread(t, full)
  local lines = {
    ("%s  bead=%s  section=%s  status=%s  needs=%s"):format(
      t.id,
      tostring(t.bead),
      tostring(t.section or "-"),
      tostring(t.status),
      tostring(t.needs)
    ),
  }
  if full then
    if t.quote and t.quote ~= "" then
      lines[#lines + 1] = "> " .. t.quote:gsub("\n", "\n> ")
    end
    for _, m in ipairs(t.messages or {}) do
      lines[#lines + 1] = ("[%s] %s %s"):format(m.id or "?", m.author or "?", m.ts or "")
      if m.proposal then
        lines[#lines + 1] = ("  proposal: field=%s"):format(tostring(m.proposal.field))
        lines[#lines + 1] = "  " .. tostring(m.proposal.value):gsub("\n", "\n  ")
      end
      if m.body and m.body ~= "" then
        lines[#lines + 1] = "  " .. m.body:gsub("\n", "\n  ")
      end
    end
  end
  return table.concat(lines, "\n")
end

local function emit_json(v)
  if type(v) == "table" and next(v) == nil then
    io.stdout:write("[]\n")
  else
    io.stdout:write(vim.json.encode(v), "\n")
  end
end

function M.run(argv)
  local cmd = argv[1]
  if cmd == nil or cmd == "help" or cmd == "-h" or cmd == "--help" then
    io.stdout:write(USAGE, "\n")
    return cmd == nil and 1 or 0
  end
  if cmd == "reopen" or cmd == "delete" then
    return die(cmd .. " is not available to agents; only the user can do that")
  end
  if not (cmd == "list" or cmd == "show" or cmd == "reply" or cmd == "resolve" or cmd == "propose") then
    return die("unknown subcommand '" .. cmd .. "'\n" .. USAGE)
  end

  local pos, opts = parse(vim.list_slice(argv, 2))
  if not pos then
    return die(opts)
  end
  local author = opts.author or "agent"
  if (cmd == "reply" or cmd == "resolve" or cmd == "propose") and author == "user" then
    return die("author 'user' is reserved for the human; agents cannot post as user")
  end
  local root = find_root()
  if not root then
    return die("no .beads directory found above cwd and BEADS_NVIM_ROOT is not set")
  end

  if cmd == "list" then
    if opts.needs and opts.needs ~= "agent" and opts.needs ~= "user" then
      return die("--needs must be agent or user")
    end
    local threads = store.list(root, { needs = opts.needs })
    if opts.json then
      emit_json(threads)
    else
      for _, t in ipairs(threads) do
        io.stdout:write(format_thread(t, false), "\n")
      end
    end
    return 0
  end

  local tid = pos[1]
  if not tid then
    return die(cmd .. " needs a thread id")
  end
  local t = store.get(root, tid)
  if not t then
    return die("no such thread: " .. tid)
  end

  if cmd == "show" then
    if opts.json then
      emit_json(t)
    else
      io.stdout:write(format_thread(t, true), "\n")
    end
  elseif cmd == "reply" then
    if not pos[2] then
      return die("reply needs a body (or - for stdin)")
    end
    if not store.reply(root, tid, author, body_arg(pos[2])) then
      return die("thread not found: " .. tid)
    end
  elseif cmd == "resolve" then
    if pos[2] then
      if not store.reply(root, tid, author, body_arg(pos[2])) then
        return die("thread not found: " .. tid)
      end
    end
    if not store.resolve(root, tid) then
      return die("thread not found: " .. tid)
    end
  elseif cmd == "propose" then
    if not opts.field or not FIELDS[opts.field] then
      return die("--field must be one of title, description, design, acceptance")
    end
    if not pos[2] then
      return die("propose needs a value (or - for stdin)")
    end
    store.reply(root, tid, author, "", { field = opts.field, value = body_arg(pos[2]) })
  end
  return 0
end

return M
