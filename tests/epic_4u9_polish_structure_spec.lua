-- Bead beads_nvim-69z: leftovers from the epic beads_nvim-4u9 review. Structural checks on the
-- source; behaviour is guarded by the existing specs (peek_watch_spec, format_line_spec, ...).
--   * id_width is used for padding by a caller, or removed from the code.
--   * Peek floats reuse the shared bead fetch instead of their own copy of bd show + parsing.
-- assumption: "used" means a line builder (tree or a picker) passes id_width to the formatter.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function src(rel)
  return table.concat(vim.fn.readfile(root .. "/lua/beads/" .. rel), "\n")
end

local function lua_files()
  return vim.fn.globpath(root .. "/lua/beads", "**/*.lua", false, true)
end

describe("epic 4u9 polish", function()
  it("id_width is passed by a caller or gone from the code", function()
    local mentions, callers = {}, {}
    for _, f in ipairs(lua_files()) do
      local s = table.concat(vim.fn.readfile(f), "\n")
      if s:find("id_width", 1, true) then
        mentions[#mentions + 1] = f
        if not f:find("/ui/format%.lua$") then
          callers[#callers + 1] = f
        end
      end
    end
    assert.is_true(
      #mentions == 0 or #callers > 0,
      "id_width is defined in ui/format.lua but no caller passes it: " .. table.concat(mentions, ", ")
    )
  end)

  it("peek.lua has no copy of the bead fetch", function()
    local s = src("views/peek.lua")
    assert.is_nil(s:find("cli.show(", 1, true), "peek.lua still calls cli.show itself")
    assert.is_nil(s:find("res.data[1] or res.data", 1, true), "peek.lua still parses bd show output itself")
  end)
end)
