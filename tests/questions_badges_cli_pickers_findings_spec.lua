-- Bead beads_nvim-4gx.6, review finding: :Beads ready and :Beads search load beads straight from
-- bd (not from the store), so a bead with a thread waiting on the user must still show 💬 there.
-- Black box: picker lines are read through vim.ui.select's format_item.
-- bd is the fake from tests/questions_waiting_fake.lua, wrapped by a second script on PATH that
-- answers `bd ... ready` and `bd ... search` from ready.json / search.json and delegates the rest.

local fake = require("tests.questions_waiting_fake")

local GLYPH = "💬"

local wrap_dir

local function install_wrapper()
  wrap_dir = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(wrap_dir, "p")
  local q = vim.fn.shellescape
  local d = fake.dir()
  vim.fn.writefile({
    "#!/bin/sh",
    'for a in "$@"; do',
    '  case "$a" in',
    "    ready) cat " .. q(d .. "/ready.json") .. "; exit 0;;",
    "    search) cat " .. q(d .. "/search.json") .. "; exit 0;;",
    "  esac",
    "done",
    "exec " .. q(d .. "/bd") .. ' "$@"',
  }, wrap_dir .. "/bd")
  vim.fn.setfperm(wrap_dir .. "/bd", "rwxr-xr-x")
  vim.env.PATH = wrap_dir .. ":" .. vim.env.PATH
end

local function write_json(name, ids)
  local out = {}
  for _, b in ipairs(fake.beads()) do
    if vim.tbl_contains(ids, b.id) then
      out[#out + 1] = b
    end
  end
  vim.fn.writefile({ vim.json.encode(out) }, fake.dir() .. "/" .. name)
end

local function line_of(c, id, what)
  local i = fake.find(c.lines, id)
  assert.is_not_nil(i, id .. " missing from " .. what .. ":\n" .. table.concat(c.lines, "\n"))
  return c.lines[i]
end

describe("beads 💬 badge in cli-sourced pickers", function()
  before_each(function()
    fake.setup()
    fake.write_threads()
    write_json("ready.json", { "qa-1", "ag-2", "rs-3", "hu-4", "pl-7" })
    write_json("search.json", { "qa-1", "ag-2", "hu-4", "cl-5", "pl-7" })
    install_wrapper()
  end)

  after_each(function()
    fake.teardown()
    if wrap_dir then
      vim.fn.delete(wrap_dir, "rf")
      wrap_dir = nil
    end
  end)

  it(":Beads ready shows 💬 on beads waiting on the user (stored and human threads)", function()
    local get = fake.capture_select()
    vim.cmd("Beads ready")
    local c = get(":Beads ready picker")
    local qa = line_of(c, "qa-1", "ready picker")
    assert.truthy(qa:find(GLYPH, 1, true), "no " .. GLYPH .. " in: " .. qa)
    local hu = line_of(c, "hu-4", "ready picker")
    assert.truthy(hu:find(GLYPH, 1, true), "no " .. GLYPH .. " in: " .. hu)
    for _, id in ipairs({ "ag-2", "rs-3", "pl-7" }) do
      local l = line_of(c, id, "ready picker")
      assert.is_nil(l:find(GLYPH, 1, true), id .. " shows " .. GLYPH .. ": " .. l)
    end
  end)

  it(":Beads search shows 💬 on beads waiting on the user, none on closed beads", function()
    local get = fake.capture_select()
    vim.cmd("Beads search alpha")
    local c = get(":Beads search picker")
    local qa = line_of(c, "qa-1", "search picker")
    assert.truthy(qa:find(GLYPH, 1, true), "no " .. GLYPH .. " in: " .. qa)
    local hu = line_of(c, "hu-4", "search picker")
    assert.truthy(hu:find(GLYPH, 1, true), "no " .. GLYPH .. " in: " .. hu)
    for _, id in ipairs({ "ag-2", "cl-5", "pl-7" }) do
      local l = line_of(c, id, "search picker")
      assert.is_nil(l:find(GLYPH, 1, true), id .. " shows " .. GLYPH .. ": " .. l)
    end
  end)
end)
