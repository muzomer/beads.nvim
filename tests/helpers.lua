local M = {}

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

function M.load_fixture(name)
  local lines = vim.fn.readfile(root .. "/tests/fixtures/" .. name .. ".json")
  return vim.json.decode(table.concat(lines, "\n"))
end

function M.has_bd()
  return vim.fn.executable("bd") == 1
end

function M.with_bd_repo(fn)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local ok, err = pcall(function()
    local res = vim.system({ "bd", "init", "--non-interactive" }, { cwd = dir, text = true }):wait()
    if res.code ~= 0 then
      error("bd init failed: " .. (res.stderr or ""), 0)
    end
    fn(dir)
  end)
  vim.fn.delete(dir, "rf")
  if not ok then
    error(err, 0)
  end
end

return M
