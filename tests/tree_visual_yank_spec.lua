-- Bead beads_nvim-qvs.1: visual yy / yr in the tree yank every bead in the range, one per line.
-- Interface under test: :Beads tree, default keys V (builtin), yy (yank_id), yr (yank_run).
--
-- `bd` is replaced by a shell script on PATH (test double for the external binary): `list` prints
-- $FAKE_DIR/list.json, `context` reports an embedded backend (so the watcher behaves as in the
-- other tree specs), anything else prints {}.
--
-- assumption: the ids / run commands are in tree (row) order, one per line, in the " register
--   (one trailing newline allowed).

local cli = require("beads.cli")
local H = require("tests.group_actions_harness")

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local FAKE_BD = [[#!/bin/sh
d="$FAKE_DIR"
printf '%s\n' "$*" >> "$d/calls.log"
case " $* " in
  *" context "*)
    printf '{"backend":"dolt","beads_dir":"%s/.beads","database":"db","dolt_mode":"embedded","repo_root":"%s","is_redirected":false,"is_worktree":false,"schema_version":1}\n' "$d" "$d"
    ;;
  *" list "*)
    cat "$d/list.json"
    ;;
  *" ready "*)
    printf '[]\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
]]

local function bead(id, title, extra)
  local b = {
    id = id,
    title = title,
    status = "open",
    priority = 2,
    issue_type = "task",
    created_at = "2026-11-17T10:00:00Z",
    updated_at = "2026-11-17T10:00:00Z",
  }
  for k, v in pairs(extra or {}) do
    b[k] = v
  end
  return b
end

local function child_of(id, parent, title)
  return bead(id, title, {
    parent = parent,
    dependencies = { { issue_id = id, depends_on_id = parent, type = "parent-child" } },
  })
end

local function items()
  return {
    bead("ep-1", "Epic one", { issue_type = "epic", priority = 1 }),
    child_of("t-1", "ep-1", "Task one"),
    child_of("t-2", "ep-1", "Task two"),
    bead("t-3", "Task three", { priority = 3 }),
    bead("t-4", "Task four", { priority = 3 }),
  }
end

local function reg_lines()
  local s = vim.fn.getreg('"'):gsub("\n$", "")
  return vim.split(s, "\n", { plain = true })
end

-- Ids of the beads whose rows lie between the rows of a and b (inclusive), in row order.
local function ids_between(a, b)
  local ra, rb = H.row_of(a), H.row_of(b)
  local out = {}
  for _, id in ipairs({ "ep-1", "t-1", "t-2", "t-3", "t-4" }) do
    local r = H.row_of(id)
    if r and r >= math.min(ra, rb) and r <= math.max(ra, rb) then
      out[#out + 1] = { r = r, id = id }
    end
  end
  table.sort(out, function(x, y)
    return x.r < y.r
  end)
  return vim.tbl_map(function(x)
    return x.id
  end, out)
end

-- Starts linewise visual on bead `from`, extends it down to bead `to` and presses `keys`, all in
-- one feed.
local function visual(from, to, keys)
  local d = H.row_of(to) - H.row_of(from)
  assert(d > 0, to .. " is not below " .. from .. ":\n" .. H.dump())
  H.on(from)
  H.press("V" .. d .. "j" .. keys)
end

local function run_cmd(id)
  return (id:match("^ep%-") and "/beads-workflow:run-epic " or "/beads-workflow:run-bead ") .. id
end

describe("tree: visual yy / yr", function()
  local dir, orig_path

  before_each(function()
    orig_path = vim.env.PATH
    H.install()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d .. "/.beads/embeddeddolt/db/.dolt/noms", "p")
    dir = vim.fn.resolve(d)
    vim.fn.writefile({ "x" }, dir .. "/.beads/last-touched")
    vim.fn.writefile({ "manifest-v1" }, dir .. "/.beads/embeddeddolt/db/.dolt/noms/manifest")
    vim.fn.writefile({ "" }, dir .. "/.beads/issues.jsonl")
    vim.fn.writefile(vim.split(FAKE_BD, "\n"), dir .. "/bd")
    vim.fn.setfperm(dir .. "/bd", "rwxr-xr-x")
    vim.fn.writefile({ vim.json.encode(items()) }, dir .. "/list.json")
    vim.env.FAKE_DIR = dir
    vim.env.PATH = dir .. ":" .. orig_path
    vim.cmd.cd(vim.fn.fnameescape(dir))
    cli.set_root(dir)
    if vim.fn.exists(":Beads") == 0 then
      vim.cmd.source(plugin_root .. "/plugin/beads.lua")
    end
    require("beads").setup({ fzf = false })
    H.open_tree("t-4")
  end)

  after_each(function()
    pcall(vim.cmd, "normal! \27")
    H.close_all()
    H.sleep(300)
    H.restore()
    vim.env.PATH = orig_path
    cli.set_root(nil)
    vim.cmd.cd(vim.fn.fnameescape(plugin_root))
    vim.fn.delete(dir, "rf")
  end)

  it("V over t-1..t-3 then yy yanks the 3 ids, one per line", function()
    local want = ids_between("t-1", "t-3")
    assert.are.equal(3, #want, "fixture: expected 3 beads between t-1 and t-3:\n" .. H.dump())
    vim.fn.setreg('"', "before")
    visual("t-1", "t-3", "yy")
    assert.are.same(want, reg_lines(), "register:\n" .. vim.fn.getreg('"'))
  end)

  it("V over ep-1..t-1 then yr yanks both run commands (run-epic for the epic), one per line", function()
    local ids = ids_between("ep-1", "t-1")
    assert.are.same({ "ep-1", "t-1" }, ids, "fixture: rows between ep-1 and t-1:\n" .. H.dump())
    vim.fn.setreg('"', "before")
    visual("ep-1", "t-1", "yr")
    assert.are.same(vim.tbl_map(run_cmd, ids), reg_lines(), "register:\n" .. vim.fn.getreg('"'))
  end)

  it("visual yy leaves visual mode and does not mark the beads", function()
    vim.fn.setreg('"', "before")
    visual("t-1", "t-2", "yy")
    assert.are.same({ "t-1", "t-2" }, reg_lines(), "register:\n" .. vim.fn.getreg('"'))
    assert.is_nil(vim.fn.mode():match("^[vV\22]"), "still in visual mode: " .. vim.fn.mode())
    -- the next normal-mode yy acts on the cursor bead only (no marks were left behind)
    H.on("t-4")
    H.press("yy")
    assert.are.same({ "t-4" }, reg_lines(), "register after normal yy:\n" .. vim.fn.getreg('"'))
  end)
end)
