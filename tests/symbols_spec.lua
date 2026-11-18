-- Bead beads_nvim-4u9.12: distinct symbols and a symbol legend.
-- Interface under test:
--   * require("beads.workflow").badges(bead) with default config: review clean ✅, review issues ❌
--     (❌r<n> with review_round), gate pass 🟢, gate fail 🔴.
--   * Default status glyphs (beads.glyphs.defaults + "·" unknown), badge glyphs
--     (beads.workflow.default_glyphs), tree markers (▾ ▸ ⛔ │ ├ └) and winbar markers ([+], ⚠)
--     are pairwise disjoint.
--   * The detail winbar shows "[+]" (not "●") while the buffer is modified.
--   * The help float (? / g? / <leader>b?) has a "Symbols" section (heading line whose letters are
--     exactly "Symbols", e.g. "── Symbols ──") listing the symbols of the current view, one per line
--     with its meaning, built from the active (possibly overridden) glyphs.
--   * README.md has a "Symbols" section (markdown heading) listing every default symbol.
-- bd is a fake on PATH (tests/questions_fake.lua, tests/detail_winbar_fake.lua).

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local STATUSES = { "open", "in_progress", "blocked", "closed", "deferred" }
local STATUS_WORD = {
  open = "open",
  in_progress = "progress",
  blocked = "blocked",
  closed = "closed",
  deferred = "deferred",
}
local BADGE_WORD = {
  clean = "clean",
  issues = "issue",
  gate_pass = "pass",
  gate_fail = "fail",
  human = "human",
  needs_review = "review",
  parked = "park",
  waiting = "wait",
}
local TREE_MARKERS = { "▾", "▸", "⛔", "│", "├", "└" }
local WINBAR_MARKERS = { "[+]", "⚠" }

local function fresh_beads()
  for name in pairs(package.loaded) do
    if name == "beads" or name:match("^beads%.") then
      package.loaded[name] = nil
    end
  end
  return require("beads")
end

local function bead(fields)
  local b = { id = "sy-1", title = "t", status = "open", priority = 2, issue_type = "task", labels = {}, metadata = {} }
  for k, v in pairs(fields or {}) do
    b[k] = v
  end
  return b
end

-- ── help float helpers ────────────────────────────────────────────────────────────────────────
local function norm(l)
  return vim.trim((l:gsub("[^%w ]", ""))):lower()
end

local HEADINGS = { "global", "view mode", "edit mode", "tree", "thread", "input", "symbols" }

-- A heading line: decorated with ── or #, or whose letters are exactly a known heading.
local function heading_name(l)
  local n = norm(l)
  for _, h in ipairs(HEADINGS) do
    if n == h then
      return h
    end
  end
  if l:find("──", 1, true) or l:match("^%s*#") then
    return n
  end
end

local function symbols_section(lines)
  local out, inside = nil, false
  for _, l in ipairs(lines) do
    local h = heading_name(l)
    if h then
      if inside then
        break
      end
      if h == "symbols" then
        inside, out = true, {}
      end
    elseif inside then
      out[#out + 1] = l
    end
  end
  return out
end

-- A line of sec containing glyph and (if given) word (case-insensitive), with a meaning (letters
-- besides the glyph).
local function find_line(sec, glyph, word)
  for _, l in ipairs(sec) do
    local s, e = l:find(glyph, 1, true)
    if s then
      local rest = l:sub(1, s - 1) .. l:sub(e + 1)
      if rest:find("%a") and (not word or rest:lower():find(word, 1, true)) then
        return l
      end
    end
  end
end

local function assert_symbol(sec, glyph, word, dump)
  assert(
    find_line(sec, glyph, word),
    ("Symbols section has no line with %q and meaning %q:\n%s"):format(glyph, tostring(word or "<any>"), dump)
  )
end

local function lines_of(w)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
end

local function legend(f)
  assert.is_not_nil(f, "no help float opened")
  local lines = lines_of(f)
  local dump = table.concat(lines, "\n")
  local sec = symbols_section(lines)
  assert(sec, "help float has no 'Symbols' section:\n" .. dump)
  return sec, dump
end

local function close_all_floats()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
end

-- ── default badges and disjointness ───────────────────────────────────────────────────────────
describe("default badge glyphs", function()
  local workflow
  before_each(function()
    fresh_beads().setup({})
    workflow = require("beads.workflow")
  end)

  it("review clean is ✅ (no round suffix)", function()
    assert.are.same({ "✅" }, workflow.badges(bead({ metadata = { verdict = "CLEAN" } })))
    assert.are.same({ "✅" }, workflow.badges(bead({ metadata = { verdict = "CLEAN", review_round = 2 } })))
  end)

  it("review issues is ❌, with r<n> when review_round is set", function()
    assert.are.same({ "❌" }, workflow.badges(bead({ metadata = { verdict = "ISSUES" } })))
    assert.are.same({ "❌r2" }, workflow.badges(bead({ metadata = { verdict = "ISSUES", review_round = 2 } })))
  end)

  it("gate pass is 🟢 and gate fail is 🔴", function()
    assert.are.same({ "🟢" }, workflow.badges(bead({ metadata = { gate = "pass" } })))
    assert.are.same({ "🔴" }, workflow.badges(bead({ metadata = { gate = "fail" } })))
  end)

  it("👤 human, 👀 needs-review, ⏸ parked, 💬 waiting stay unchanged", function()
    assert.are.same({ "👤", "👀", "⏸" }, workflow.badges(bead({ labels = { "human", "needs-review" }, metadata = { parked = "p" } })))
    assert.are.same({ "💬" }, workflow.badges(bead({ waiting_user = true })))
  end)

  it("no default badge glyph equals a default status glyph", function()
    local g = require("beads.glyphs")
    for _, s in ipairs(STATUSES) do
      for name, badge in pairs(workflow.default_glyphs) do
        assert.are_not.equal(g.status(s), badge, ("badge %s equals status glyph of %s"):format(name, s))
      end
    end
  end)

  it("status glyphs, badge glyphs, tree markers and winbar markers are pairwise disjoint", function()
    local g = require("beads.glyphs")
    local sets = { status = { "·" }, badge = {}, tree = TREE_MARKERS, winbar = WINBAR_MARKERS }
    for _, s in ipairs(STATUSES) do
      table.insert(sets.status, g.status(s))
    end
    for _, v in pairs(workflow.default_glyphs) do
      table.insert(sets.badge, v)
    end
    local owner = {}
    for kind, set in pairs(sets) do
      for _, glyph in ipairs(set) do
        assert.is_true(glyph ~= "", kind .. " set has an empty glyph")
        local prev = owner[glyph]
        assert(prev == nil or prev == kind, ("glyph %q is both a %s and a %s symbol"):format(glyph, tostring(prev), kind))
        owner[glyph] = kind
      end
    end
  end)
end)

-- ── winbar ────────────────────────────────────────────────────────────────────────────────────
describe("detail winbar modified marker", function()
  local wfake = require("tests.detail_winbar_fake")

  before_each(function()
    wfake.setup()
    require("beads").setup({})
  end)
  after_each(function()
    wfake.teardown()
  end)

  local function wb()
    return wfake.winbar(vim.api.nvim_get_current_win())
  end

  it("shows [+] and no ● while modified (open bead), and drops [+] after discard", function()
    local buf = wfake.open_detail()
    wfake.wait_for(function()
      return wb().str:find("VIEW", 1, true)
    end, "view winbar", 2000)
    assert.is_nil(wb().str:find("[+]", 1, true), "[+] shown while unmodified: " .. wb().str)
    vim.api.nvim_set_current_buf(buf)
    wfake.press("e")
    pcall(vim.cmd, "stopinsert")
    local row = wfake.row_of(buf, "# ")
    vim.api.nvim_buf_set_lines(buf, row, row + 1, false, { "# Changed" })
    assert.is_true(vim.bo[buf].modified)
    wfake.wait_for(function()
      return wb().str:find("[+]", 1, true)
    end, "[+] in winbar (winbar: " .. vim.inspect(wb().str) .. ")", 2000)
    assert.is_nil(wb().str:find("●", 1, true), "winbar still shows ●: " .. wb().str)
    vim.ui.select = function(items, _, on_choice)
      for _, it in ipairs(items) do
        if tostring(it):lower():find("discard", 1, true) then
          return on_choice(it)
        end
      end
      on_choice(nil)
    end
    wfake.press("<Esc><Esc>")
    wfake.wait_for(function()
      return not vim.bo[buf].modified and not wb().str:find("[+]", 1, true)
    end, "[+] gone after discard (winbar: " .. vim.inspect(wb().str) .. ")", 2000)
  end)
end)

-- ── legend in the help float ──────────────────────────────────────────────────────────────────
describe("Symbols legend in the help float", function()
  local fake = require("tests.questions_fake")

  before_each(function()
    fake.setup()
    require("beads").setup({})
  end)
  after_each(function()
    close_all_floats()
    fake.teardown()
    require("beads").setup({})
  end)

  local function open_tree()
    vim.cmd("Beads tree")
    assert.equals("beads-tree", vim.bo.filetype, ":Beads tree did not focus the tree")
  end

  local function assert_statuses(sec, dump)
    local g = require("beads.glyphs")
    for _, s in ipairs(STATUSES) do
      assert_symbol(sec, g.status(s), STATUS_WORD[s], dump)
    end
  end

  it("tree ?: status glyphs, badges, ▾ ▸ ⛔ with their meanings", function()
    open_tree()
    local sec, dump = legend(fake.press_for_float("?"))
    assert_statuses(sec, dump)
    for name, glyph in pairs(require("beads.workflow").default_glyphs) do
      assert_symbol(sec, glyph, BADGE_WORD[name], dump)
    end
    assert_symbol(sec, "▾", nil, dump)
    assert_symbol(sec, "▸", nil, dump)
    assert_symbol(sec, "⛔", "blocked", dump)
  end)

  it("detail VIEW ?: status glyphs, [+] modified, ⚠ changed on disk", function()
    fake.open_detail()
    local sec, dump = legend(fake.press_for_float("?"))
    assert_statuses(sec, dump)
    assert_symbol(sec, "[+]", "modified", dump)
    assert_symbol(sec, "⚠", "changed", dump)
  end)

  it("detail EDIT g?: status glyphs, [+] modified, ⚠ changed on disk", function()
    local buf = fake.open_detail()
    fake.press("e")
    pcall(vim.cmd, "stopinsert")
    assert.equals("edit", vim.b[buf].beads_mode, "e did not enter edit mode")
    local sec, dump = legend(fake.press_for_float("g?"))
    assert_statuses(sec, dump)
    assert_symbol(sec, "[+]", "modified", dump)
    assert_symbol(sec, "⚠", "changed", dump)
  end)

  it("plain buffer <leader>b?: a Symbols section with the status glyphs", function()
    vim.cmd("enew")
    local sec, dump = legend(fake.press_for_float("<leader>b?"))
    assert_statuses(sec, dump)
  end)

  it("overriding glyphs via setup() changes them in the legend", function()
    require("beads").setup({ glyphs = { open = "OPN" }, workflow = { glyphs = { clean = "CLN", gate_fail = "GFL" } } })
    open_tree()
    local sec, dump = legend(fake.press_for_float("?"))
    assert_symbol(sec, "OPN", "open", dump)
    assert_symbol(sec, "CLN", "clean", dump)
    assert_symbol(sec, "GFL", "fail", dump)
    for _, l in ipairs(sec) do
      assert.is_nil(l:find("○", 1, true), "default open glyph still in the legend:\n" .. dump)
      assert.is_nil(l:find("✅", 1, true), "default clean glyph still in the legend:\n" .. dump)
      assert.is_nil(l:find("🔴", 1, true), "default gate fail glyph still in the legend:\n" .. dump)
    end
  end)
end)

-- ── README ────────────────────────────────────────────────────────────────────────────────────
describe("README Symbols section", function()
  it("lists every default symbol with its meaning", function()
    fresh_beads().setup({})
    local lines = vim.fn.readfile(root .. "/README.md")
    local sec, level
    for _, l in ipairs(lines) do
      local hashes, title = l:match("^(#+)%s+(.-)%s*$")
      if sec and hashes and #hashes <= level then
        break
      end
      if hashes and title:lower() == "symbols" then
        sec, level = {}, #hashes
      elseif sec then
        sec[#sec + 1] = l
      end
    end
    assert(sec, "README has no '## Symbols' section")
    local dump = table.concat(sec, "\n")
    local g = require("beads.glyphs")
    for _, s in ipairs(STATUSES) do
      assert_symbol(sec, g.status(s), STATUS_WORD[s], dump)
    end
    assert_symbol(sec, "·", nil, dump)
    for name, glyph in pairs(require("beads.workflow").default_glyphs) do
      assert_symbol(sec, glyph, BADGE_WORD[name], dump)
    end
    assert_symbol(sec, "❌r", nil, dump)
    for _, m in ipairs(TREE_MARKERS) do
      assert_symbol(sec, m, nil, dump)
    end
    assert_symbol(sec, "[+]", "modified", dump)
    assert_symbol(sec, "⚠", "changed", dump)
  end)
end)
