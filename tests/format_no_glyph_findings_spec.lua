-- Bead beads_nvim-4u9.2, review finding: a bead whose status has no glyph (status nil, or a status
-- outside the 5 known ones, so glyphs.status returns "") must still map back to its own id from a
-- picker line. Before the fix the line was " <id> P1 ...", so picker.id_of_line returned "P1" and
-- fzf <CR> / yank / close acted on "P1" instead of the bead.
-- fzf-lua is replaced by a fake module (test double for the external plugin) recording fzf_exec.

local picker = require("beads.views.picker")

local function bead(id, status)
  return {
    id = id,
    title = "Strange status bead",
    status = status,
    priority = 1,
    type = "task",
    labels = {},
  }
end

local CASES = {
  { name = "nil status", bead = bead("ns-1", nil) },
  { name = "unknown status 'pinned'", bead = bead("pn-2", "pinned") },
  { name = "unknown status 'tombstone'", bead = bead("tb-3", "tombstone") },
}

describe("picker lines for beads without a status glyph", function()
  local saved_fzf

  before_each(function()
    require("beads").setup({})
    saved_fzf = package.loaded["fzf-lua"]
  end)

  after_each(function()
    package.loaded["fzf-lua"] = saved_fzf
  end)

  for _, c in ipairs(CASES) do
    it("id_of_line returns the bead id from the plain line (" .. c.name .. ")", function()
      local line = picker.format(c.bead)
      assert.are.equal(c.bead.id, picker.id_of_line(line), "line was: '" .. line .. "'")
    end)

    it("id_of_line returns the bead id from the ANSI line (" .. c.name .. ")", function()
      local line = picker.format_ansi(c.bead)
      assert.are.equal(c.bead.id, picker.id_of_line(line), "line was: " .. vim.inspect(line))
    end)
  end

  it("still parses ids of beads that do have a glyph", function()
    for _, st in ipairs({ "open", "in_progress", "blocked", "closed", "deferred" }) do
      local b = bead("gl-" .. st, st)
      assert.are.equal(b.id, picker.id_of_line(picker.format(b)))
      assert.are.equal(b.id, picker.id_of_line(picker.format_ansi(b)))
    end
  end)

  it("fzf <CR>, yank and close act on the glyph-less bead's id", function()
    local calls = {}
    package.loaded["fzf-lua"] = {
      fzf_exec = function(contents, opts)
        calls[#calls + 1] = { contents = contents, opts = opts or {} }
      end,
    }
    local opened, yanked, closed = {}, {}, {}
    local p = setmetatable({
      open_bead = function(id)
        opened[#opened + 1] = id
      end,
      yank = function(text)
        yanked[#yanked + 1] = text
      end,
      close_bead = function(id)
        closed[#closed + 1] = id
      end,
    }, { __index = picker })

    local beads = { CASES[1].bead, CASES[2].bead, bead("op-9", "open") }
    require("beads.pickers.fzf").pick("list", beads, p)
    assert.are.equal(1, #calls)
    local lines, actions = calls[1].contents, calls[1].opts.actions
    local function act(key, line)
      local a = actions[key]
      local fn = type(a) == "table" and a.fn or a
      fn({ line }, {})
    end

    for i, b in ipairs(beads) do
      act("default", lines[i])
      act("ctrl-y", lines[i])
      act("ctrl-x", lines[i])
      assert.are.equal(b.id, opened[i], "open for line " .. vim.inspect(lines[i]))
      assert.are.equal(b.id, yanked[i], "yank for line " .. vim.inspect(lines[i]))
      assert.are.equal(b.id, closed[i], "close for line " .. vim.inspect(lines[i]))
    end
  end)
end)
