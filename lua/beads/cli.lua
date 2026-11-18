local M = {}

local root = nil

function M.get_root()
  return root or vim.fn.getcwd()
end

-- Raw override (nil when unset), for save/restore.
function M.get_root_override()
  return root
end

function M.set_root(path)
  root = path
end

local function tail(s, n)
  local lines = vim.split(vim.trim(s or ""), "\n", { plain = true })
  return table.concat(vim.list_slice(lines, math.max(1, #lines - n + 1)), "\n")
end

-- Runs bd with args; cleanup (optional) runs on the main loop before cb.
local function run(args, decode, cb, cleanup)
  local argv = { "bd", "-C", M.get_root() }
  vim.list_extend(argv, args)
  local function finish(res)
    if cleanup then
      cleanup()
    end
    cb(res)
  end
  local ok, obj = pcall(vim.system, argv, { text = true }, function(r)
    vim.schedule(function()
      if r.code ~= 0 then
        local stderr = tail(r.stderr, 10)
        return finish({ err = "bd exited with code " .. r.code .. ": " .. stderr, stderr = stderr })
      end
      if not decode then
        return finish({ data = r.stdout })
      end
      local dok, data = pcall(vim.json.decode, r.stdout or "")
      if not dok then
        return finish({ err = "failed to decode bd JSON output: " .. tostring(data) })
      end
      finish({ data = data })
    end)
  end)
  if not ok then
    vim.schedule(function()
      local msg = tostring(obj)
      if vim.fn.executable("bd") == 0 then
        msg = "bd not found on PATH"
      end
      finish({ err = msg, stderr = "" })
    end)
  end
end

function M.list(opts, cb)
  opts = opts or {}
  local args = { "list", "-n", "0", "--json" }
  if opts.all then
    table.insert(args, "--all")
  end
  run(args, true, cb)
end

-- opts.include_comments adds --include-comments.
function M.show(id, cb, opts)
  local args = { "show", id, "--json" }
  if opts and opts.include_comments then
    args[#args + 1] = "--include-comments"
  end
  run(args, true, cb)
end

function M.claim(id, cb)
  run({ "update", id, "--claim", "--json" }, true, cb)
end

function M.close(id, reason, cb)
  local args = { "close", id }
  if reason and reason ~= "" then
    vim.list_extend(args, { "--reason", reason })
  end
  args[#args + 1] = "--json"
  run(args, true, cb)
end

function M.append_note(id, text, cb)
  run({ "update", id, "--append-notes", text, "--json" }, true, cb)
end

function M.comment(id, text, cb)
  M.run_with_files({ "comment", id }, { ["--file"] = text }, cb)
end

-- lines: bd batch grammar lines, passed via a temp file.
function M.batch(lines, cb)
  local path = vim.fn.tempname()
  vim.fn.writefile(lines, path)
  run({ "batch", "-f", path }, false, cb, function()
    vim.fn.delete(path)
  end)
end

-- Reopens several beads with one call.
function M.reopen(ids, cb)
  local args = { "reopen" }
  vim.list_extend(args, ids)
  args[#args + 1] = "--json"
  run(args, true, cb)
end

function M.ready(cb)
  run({ "ready", "--json" }, true, cb)
end

function M.search(q, cb)
  run({ "search", q, "--json" }, true, cb)
end

function M.context(cb)
  run({ "context", "--json" }, true, cb)
end

-- files: map flag -> text; each text is written to a temp file passed as '<flag> <path>'.
function M.run_with_files(args, files, cb)
  local full = vim.list_extend({}, args)
  local paths = {}
  for flag, text in pairs(files or {}) do
    local path = vim.fn.tempname()
    vim.fn.writefile(vim.split(text, "\n", { plain = true }), path)
    table.insert(paths, path)
    table.insert(full, flag)
    table.insert(full, path)
  end
  table.insert(full, "--json")
  run(full, true, cb, function()
    for _, p in ipairs(paths) do
      vim.fn.delete(p)
    end
  end)
end

return M
