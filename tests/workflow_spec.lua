-- Interface under test (bead beads_nvim-ge7.4): lua/beads/workflow.lua
--   local workflow = require("beads.workflow")
--   workflow.badges(bead)     -> list of strings, in order: verdict, gate, human, needs-review, parked.
--                                Empty table when the bead has no workflow metadata/labels.
--   workflow.fields(bead)     -> ordered list of { name = <metadata key>, value = <raw value> },
--                                only keys that are set. Order: verdict, review_round, findings,
--                                gate, tdd, bookmark, change, rounds, parked; epics additionally
--                                full_suite, full_suite_culprit (tasks never).
--   workflow.run_command(bead) -> "/beads-workflow:run-epic <id>" for type epic, else run-bead.
--   workflow.is_needs_me(bead) -> true iff labels contain "human" or "needs-review".
--   Glyphs come from require("beads").config.workflow.glyphs, read at call time; keys:
--     clean, issues, gate_pass, gate_fail, human, needs_review, parked.
--   Beads are the normalized model (require("beads.model").normalize).

local function fresh()
  for name in pairs(package.loaded) do
    if name == "beads" or name:match("^beads%.") then
      package.loaded[name] = nil
    end
  end
  return require("beads"), require("beads.workflow"), require("beads.model")
end

local function bead(raw)
  local model = require("beads.model")
  raw.id = raw.id or "x-1"
  raw.title = raw.title or "T"
  raw.issue_type = raw.issue_type or "task"
  return model.normalize(raw)
end

local function names(fields)
  local out = {}
  for i, f in ipairs(fields) do
    out[i] = f.name
  end
  return out
end

local ALL_TASK_META = {
  verdict = "ISSUES",
  review_round = 2,
  findings = "blocker a.lua:1 - x",
  gate = "fail",
  tdd = "t: failed",
  bookmark = "feat-x",
  change = "abc123",
  rounds = 3,
  parked = "waiting on y",
  full_suite = "fail",
  full_suite_culprit = "x-2",
}

describe("beads.workflow.badges", function()
  it("renders verdict ISSUES with review_round 2 as '✗r2'", function()
    local _, workflow = fresh()
    local b = bead({ metadata = { verdict = "ISSUES", review_round = 2 } })
    assert.are.same({ "✗r2" }, workflow.badges(b))
  end)

  it("renders verdict ISSUES without review_round as '✗'", function()
    local _, workflow = fresh()
    local b = bead({ metadata = { verdict = "ISSUES" } })
    assert.are.same({ "✗" }, workflow.badges(b))
  end)

  it("renders verdict CLEAN as '✓' (no round suffix even when review_round is set)", function()
    local _, workflow = fresh()
    assert.are.same({ "✓" }, workflow.badges(bead({ metadata = { verdict = "CLEAN" } })))
    assert.are.same({ "✓" }, workflow.badges(bead({ metadata = { verdict = "CLEAN", review_round = 1 } })))
  end)

  it("renders distinct non-empty gate pass and gate fail badges", function()
    local _, workflow = fresh()
    local pass = workflow.badges(bead({ metadata = { gate = "pass" } }))
    local fail = workflow.badges(bead({ metadata = { gate = "fail" } }))
    assert.are.equal(1, #pass)
    assert.are.equal(1, #fail)
    assert.is_true(#pass[1] > 0 and #fail[1] > 0)
    assert.are_not.equal(pass[1], fail[1])
  end)

  it("renders '👤' for label human and '👀' for label needs-review", function()
    local _, workflow = fresh()
    assert.are.same({ "👤" }, workflow.badges(bead({ labels = { "human" } })))
    assert.are.same({ "👀" }, workflow.badges(bead({ labels = { "needs-review" } })))
  end)

  it("renders '⏸' when metadata parked is present", function()
    local _, workflow = fresh()
    assert.are.same({ "⏸" }, workflow.badges(bead({ metadata = { parked = "waiting" } })))
  end)

  it("combines badges in order verdict, gate, human, needs-review, parked", function()
    local _, workflow = fresh()
    local gate_only = workflow.badges(bead({ metadata = { gate = "pass" } }))[1]
    local b = bead({
      labels = { "needs-review", "human", "other" },
      metadata = { verdict = "ISSUES", review_round = 3, gate = "pass", parked = "p" },
    })
    assert.are.same({ "✗r3", gate_only, "👤", "👀", "⏸" }, workflow.badges(b))
  end)

  it("returns an empty list for a bead with no workflow metadata or labels", function()
    local _, workflow = fresh()
    local b = bead({ labels = { "frontend" }, metadata = { unrelated = "x" } })
    local badges = workflow.badges(b)
    assert.are.equal("table", type(badges))
    assert.are.equal(0, #badges)
    assert.are.same({}, workflow.badges(bead({})))
  end)
end)

describe("beads.workflow glyph overrides", function()
  it("uses glyphs overridden via setup()", function()
    local beads, workflow = fresh()
    beads.setup({
      workflow = {
        glyphs = { clean = "OK", issues = "BAD", human = "H", needs_review = "NR", parked = "P" },
      },
    })
    local b = bead
    assert.are.same({ "OK" }, workflow.badges(b({ metadata = { verdict = "CLEAN" } })))
    assert.are.same({ "BADr2" }, workflow.badges(b({ metadata = { verdict = "ISSUES", review_round = 2 } })))
    assert.are.same({ "H", "NR", "P" }, workflow.badges(b({ labels = { "human", "needs-review" }, metadata = { parked = "p" } })))
  end)

  it("overriding gate glyphs changes the gate badges", function()
    local beads, workflow = fresh()
    beads.setup({ workflow = { glyphs = { gate_pass = "GP", gate_fail = "GF" } } })
    local b = bead
    assert.are.same({ "GP" }, workflow.badges(b({ metadata = { gate = "pass" } })))
    assert.are.same({ "GF" }, workflow.badges(b({ metadata = { gate = "fail" } })))
  end)

  it("partial override keeps the other default glyphs", function()
    local beads, workflow = fresh()
    beads.setup({ workflow = { glyphs = { clean = "OK" } } })
    local b = bead({ labels = { "human" }, metadata = { verdict = "ISSUES" } })
    assert.are.same({ "✗", "👤" }, workflow.badges(b))
  end)
end)

describe("beads.workflow.fields", function()
  it("returns an empty list for a bead with no workflow metadata", function()
    local _, workflow = fresh()
    local f = workflow.fields(bead({ labels = { "human" }, metadata = { unrelated = "x" } }))
    assert.are.equal("table", type(f))
    assert.are.equal(0, #f)
    assert.are.same({}, workflow.fields(bead({})))
  end)

  it("lists task fields in the documented order, without full_suite fields", function()
    local _, workflow = fresh()
    local f = workflow.fields(bead({ issue_type = "task", metadata = vim.deepcopy(ALL_TASK_META) }))
    assert.are.same(
      { "verdict", "review_round", "findings", "gate", "tdd", "bookmark", "change", "rounds", "parked" },
      names(f)
    )
  end)

  it("carries the raw metadata values", function()
    local _, workflow = fresh()
    local f = workflow.fields(bead({ metadata = { verdict = "CLEAN", review_round = 1, gate = "pass" } }))
    assert.are.same({
      { name = "verdict", value = "CLEAN" },
      { name = "review_round", value = 1 },
      { name = "gate", value = "pass" },
    }, f)
  end)

  it("includes only fields that are set", function()
    local _, workflow = fresh()
    local f = workflow.fields(bead({ metadata = { tdd = "t", parked = "p", other = "o" } }))
    assert.are.same({ "tdd", "parked" }, names(f))
  end)

  it("appends full_suite and full_suite_culprit for epics when set", function()
    local _, workflow = fresh()
    local f = workflow.fields(bead({ issue_type = "epic", metadata = vim.deepcopy(ALL_TASK_META) }))
    assert.are.same({
      "verdict", "review_round", "findings", "gate", "tdd", "bookmark", "change", "rounds", "parked",
      "full_suite", "full_suite_culprit",
    }, names(f))
    assert.are.same({ name = "full_suite_culprit", value = "x-2" }, f[#f])
  end)

  it("epic with only full_suite set lists just that field", function()
    local _, workflow = fresh()
    local f = workflow.fields(bead({ issue_type = "epic", metadata = { full_suite = "pass" } }))
    assert.are.same({ { name = "full_suite", value = "pass" } }, f)
  end)

  it("tasks never include full_suite fields even when set", function()
    local _, workflow = fresh()
    for _, t in ipairs({ "task", "feature", "bug" }) do
      local f = workflow.fields(bead({ issue_type = t, metadata = { full_suite = "pass", full_suite_culprit = "x-2" } }))
      assert.are.same({}, f, "type " .. t)
    end
  end)
end)

describe("beads.workflow.run_command", function()
  it("returns run-epic for epics", function()
    local _, workflow = fresh()
    assert.are.equal("/beads-workflow:run-epic x-9", workflow.run_command(bead({ id = "x-9", issue_type = "epic" })))
  end)

  it("returns run-bead for any other type", function()
    local _, workflow = fresh()
    for _, t in ipairs({ "task", "bug", "feature", "chore" }) do
      assert.are.equal("/beads-workflow:run-bead x-1.2", workflow.run_command(bead({ id = "x-1.2", issue_type = t })))
    end
  end)
end)

describe("beads.workflow.is_needs_me", function()
  it("is true for label human", function()
    local _, workflow = fresh()
    assert.is_true(workflow.is_needs_me(bead({ labels = { "frontend", "human" } })))
  end)

  it("is true for label needs-review", function()
    local _, workflow = fresh()
    assert.is_true(workflow.is_needs_me(bead({ labels = { "needs-review" } })))
  end)

  it("is false otherwise", function()
    local _, workflow = fresh()
    assert.is_false(workflow.is_needs_me(bead({})))
    assert.is_false(workflow.is_needs_me(bead({ labels = { "humane", "review" } })))
    assert.is_false(workflow.is_needs_me(bead({ metadata = { verdict = "ISSUES" } })))
  end)
end)
