-- Read-only threads synthesized from beads labelled 'human' (beads-workflow writes its question
-- as the bead's latest note). Not stored in questions.json. Every bd call is scoped to `root`
-- with -C and never touches the beads.cli root override.
local M = {}

local function tail(s, n)
  local lines = vim.split(vim.trim(s or ""), "\n", { plain = true })
  return table.concat(vim.list_slice(lines, math.max(1, #lines - n + 1)), "\n")
end

local function run(root, args, decode, cb)
  local argv = { "bd", "-C", root }
  vim.list_extend(argv, args)
  local ok, obj = pcall(vim.system, argv, { text = true }, function(r)
    vim.schedule(function()
      if r.code ~= 0 then
        return cb({ err = "bd exited with code " .. r.code .. ": " .. tail(r.stderr, 10) })
      end
      if not decode then
        return cb({ data = r.stdout })
      end
      local dok, data = pcall(vim.json.decode, r.stdout or "")
      if not dok then
        return cb({ err = "failed to decode bd JSON output: " .. tostring(data) })
      end
      cb({ data = data })
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb({ err = vim.fn.executable("bd") == 0 and "bd not found on PATH" or tostring(obj) })
    end)
  end
end

local function latest_note(notes)
  local last
  for _, l in ipairs(vim.split(vim.trim(notes or ""), "\n", { plain = true })) do
    if vim.trim(l) ~= "" then
      last = vim.trim(l)
    end
  end
  return last
end

function M.list(root, cb)
  run(root, { "list", "--label", "human", "-n", "0", "--json" }, true, function(res)
    if res.err then
      return cb(res)
    end
    local threads = {}
    for _, b in ipairs(res.data or {}) do
      local body = latest_note(b.notes)
      if body then
        threads[#threads + 1] = {
          id = "human:" .. b.id,
          bead = b.id,
          status = "open",
          needs = "user",
          readonly = true,
          human = true,
          messages = { { author = "agent", body = body } },
        }
      end
    end
    cb({ data = threads })
  end)
end

function M.answer(root, id, text, cb)
  run(root, { "update", id, "--append-notes", text, "--json" }, true, function(res)
    if res.err then
      return cb({ err = "appending note failed: " .. res.err })
    end
    run(root, { "label", "remove", id, "human", "--json" }, true, function(r2)
      if r2.err then
        return cb({ err = "note appended but removing label 'human' failed: " .. r2.err })
      end
      cb({ data = r2.data })
    end)
  end)
end

return M
