local M = {}

local MIN_VERSION = { 1, 2, 2 }

local function parse_version(s)
  local a, b, c = (s or ""):match("(%d+)%.(%d+)%.(%d+)")
  if not a then
    return nil
  end
  return { tonumber(a), tonumber(b), tonumber(c) }, a .. "." .. b .. "." .. c
end

local function older(v, min)
  for i = 1, 3 do
    if v[i] ~= min[i] then
      return v[i] < min[i]
    end
  end
  return false
end

local function bd(args, root)
  local argv = { "bd" }
  if root then
    vim.list_extend(argv, { "-C", root })
  end
  vim.list_extend(argv, args)
  local ok, obj = pcall(vim.system, argv, { text = true })
  if not ok then
    return nil
  end
  local ok2, res = pcall(function()
    return obj:wait(10000)
  end)
  return ok2 and res or nil
end

function M.check()
  local health = vim.health
  health.start("beads")

  if vim.fn.executable("bd") == 0 then
    health.error("bd not found on PATH", { "Install beads (bd) and make sure it is on PATH" })
    return
  end
  health.ok("bd found on PATH")

  local v = bd({ "version" })
  local min = table.concat(MIN_VERSION, ".")
  local parsed, vstr = parse_version(v and v.stdout)
  if not parsed then
    health.warn("could not determine bd version", { "Expected bd >= " .. min })
  elseif older(parsed, MIN_VERSION) then
    health.warn("bd version " .. vstr .. " is older than " .. min, { "Upgrade bd to >= " .. min })
  else
    health.ok("bd version " .. vstr)
  end

  local root = require("beads.cli").get_root()
  local w = bd({ "where" }, root)
  local where = w and w.code == 0 and (w.stdout or ""):match("[^\n]+")
  if where then
    health.ok(".beads found: " .. where)
  else
    health.error("no .beads found for " .. root, { "Run `bd init` in the project root" })
    return
  end

  local c = bd({ "context", "--json" }, root)
  local ok, ctx = pcall(vim.json.decode, c and c.code == 0 and c.stdout or "")
  if ok and type(ctx) == "table" then
    local mode = ctx.dolt_mode
    if mode == "embedded" then
      health.ok("backend mode: embedded")
    else
      health.warn("backend mode: " .. tostring(mode or ctx.backend) .. "; file watching is disabled", {
        "Only the embedded backend is watched; beads.nvim refreshes on focus instead",
      })
    end
  else
    health.warn("could not read bd context")
  end

  if pcall(require, "fzf-lua") then
    health.info("fzf-lua found")
  else
    health.info("fzf-lua not found (optional)")
  end
end

return M
