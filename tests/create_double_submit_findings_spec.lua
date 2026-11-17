-- Bead beads_nvim-ge7.10, finding: lua/beads/buffer/write.lua:17 (double submit).
-- A second :w on beads://new while the first 'bd create' is still running must not spawn
-- another 'bd create': exactly one bd create, exactly one bead.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local helpers = require("tests.helpers")
local cli = require("beads.cli")

local TIMEOUT = 15000

local function wait_for(fn, msg, timeout)
  local ok = vim.wait(timeout or TIMEOUT, function()
    local pok, v = pcall(fn)
    return pok and v
  end, 20)
  assert.is_true(ok, "timed out waiting for: " .. msg)
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

local function count_titled(dir, title)
  local r = vim.system({ "bd", "-C", dir, "list", "--all", "-n", "0", "--json" }, { text = true }):wait()
  assert.are.equal(0, r.code, "bd list failed: " .. tostring(r.stderr))
  local n = 0
  for _, it in ipairs(vim.json.decode(r.stdout) or {}) do
    if it.title == title then
      n = n + 1
    end
  end
  return n
end

describe("beads create flow: double submit", function()
  if not helpers.has_bd() then
    pending("bd executable not found")
    return
  end

  if vim.fn.exists(":Beads") ~= 2 then
    vim.cmd.source(root .. "/plugin/beads.lua")
  end

  it("a second :w while 'bd create' is in flight spawns no second 'bd create'", function()
    helpers.with_bd_repo(function(dir)
      local saved = cli.get_root_override()
      cli.set_root(dir)
      local calls = {}
      local orig_system = vim.system
      vim.system = function(cmd, opts, on_exit)
        if type(cmd) == "table" then
          calls[#calls + 1] = vim.deepcopy(cmd)
        end
        return orig_system(cmd, opts, on_exit)
      end
      local ok, err = pcall(function()
        vim.cmd("Beads create")
        local buf = vim.api.nvim_get_current_buf()
        wait_for(function()
          return vim.api.nvim_buf_get_name(buf) == "beads://new"
            and vim.tbl_contains(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "## Description")
        end, "beads://new template", 3000)

        local title = "Double submit " .. tostring(vim.uv.hrtime())
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        for i, l in ipairs(lines) do
          if l == "#" or vim.startswith(l, "# ") then
            vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { "# " .. title })
            break
          end
        end

        -- Two writes in the same tick: the first create's callback cannot have run yet.
        vim.api.nvim_set_current_buf(buf)
        vim.cmd.write()
        pcall(vim.cmd.write)

        wait_for(function()
          local m = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):match("^beads://(.+)$")
          return m and m ~= "new"
        end, "buffer renamed to beads://<new-id>")
        -- let any second create finish too
        vim.wait(1500)

        local creates = 0
        for _, argv in ipairs(calls) do
          if subcommand(argv) == "create" then
            creates = creates + 1
          end
        end
        assert.are.equal(1, creates, "expected exactly one 'bd create' for a double :w")
        assert.are.equal(1, count_titled(dir, title), "expected exactly one bead with the title")
      end)
      vim.system = orig_system
      vim.cmd("silent! enew!")
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(b) and vim.startswith(vim.api.nvim_buf_get_name(b), "beads://") then
          pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
      end
      cli.set_root(saved)
      if not ok then
        error(err, 0)
      end
    end)
  end)
end)
