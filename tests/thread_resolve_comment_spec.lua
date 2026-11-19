-- Bead beads_nvim-c24: resolving a question thread saves the Q&A as ONE comment on the bead.
-- Interface under test (through key presses in the thread float, not module internals):
--   * x in the thread float resolves the thread and runs `bd ... comments add <bead> ...` once,
--     with one comment: a header with the thread id and its section/quote, then every message in
--     order, each labelled by author, full text (no cap, no truncation).
--   * The comment text may be passed as the positional text argument or with -f/--file <path>
--     (the fake bd below captures the file content at call time); the spec accepts either.
--   * Saved once: x again, x after reopening the float, x after a new reply, x from a freshly
--     opened detail buffer all add no second comment (the saved state lives in the thread record).
--   * A failing bd (comments add exits 1): the thread is still resolved locally, exactly one
--     "Beads: " warning mentions the comment, and the next x retries the save.
--   * Unresolved threads write nothing; stored threads on a bead labelled human follow the same rule.
--   * The thread float help (?) and README's "Thread float" section mention the comment.
-- assumption: author labels are any of A: / [agent] / agent (agent) and Q: / [you] / [user] / you /
--   user (user), found just before each message body; message lines may be indented.
-- assumption: the failure warning is level WARN.
-- assumption: "human threads" = stored threads on a bead labelled human; the synthesized
--   human:<id> thread (answered with r, x warns) keeps its current resolve path.
-- bd is a fake on PATH (tests/questions_fake.lua for setup; the script is replaced here so that
-- multi-line / 20 KB arguments and -f files are recorded intact, one directory per call).

local fake = require("tests.questions_fake")
local store = require("beads.questions.store")

local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function install_bd()
  local dir = fake.dir()
  local q = vim.fn.shellescape
  vim.fn.mkdir(dir .. "/calls", "p")
  vim.fn.writefile({
    "#!/bin/sh",
    "D=" .. q(dir),
    'echo "$*" | head -c 200 | tr "\\n" " " >> "$D/calls.log"; echo >> "$D/calls.log"',
    "n=1",
    'while ! mkdir "$D/calls/$n" 2>/dev/null; do n=$((n+1)); done',
    'C="$D/calls/$n"',
    'i=0; prev=""; has_comments=0; has_add=0',
    'for a in "$@"; do',
    "  i=$((i+1))",
    '  printf "%s" "$a" > "$C/arg$i"',
    '  if [ "$prev" = "-f" ] || [ "$prev" = "--file" ]; then cat -- "$a" > "$C/file" 2>/dev/null; fi',
    '  case "$a" in --file=*) cat -- "${a#--file=}" > "$C/file" 2>/dev/null;; esac',
    '  [ "$a" = "comments" ] && has_comments=1',
    '  [ "$a" = "add" ] && has_add=1',
    '  prev="$a"',
    "done",
    'printf "%s" "$i" > "$C/argc"',
    'if [ $has_comments = 1 ] && [ $has_add = 1 ]; then',
    '  if [ -f "$D/fail_comments" ]; then echo "Error: database is locked" >&2; exit 1; fi',
    "  echo '{}'; exit 0",
    "fi",
    'case "$*" in',
    '  *"--label human"*) if [ -f "$D/human.json" ]; then cat "$D/human.json"; else echo \'[]\'; fi; exit 0;;',
    "esac",
    'for a in "$@"; do',
    '  case "$a" in',
    '    show) cat "$D/bead.json"; exit 0;;',
    "    list) echo '[]'; exit 0;;",
    "  esac",
    "done",
    "echo '{}'",
  }, dir .. "/bd")
  vim.fn.setfperm(dir .. "/bd", "rwxr-xr-x")
end

local function slurp(p)
  local f = io.open(p, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local VALUE_FLAGS = { ["-f"] = true, ["--file"] = true, ["-a"] = true, ["--author"] = true, ["-C"] = true,
  ["--directory"] = true, ["--actor"] = true, ["--db"] = true, ["--dolt-auto-commit"] = true }

-- Every finished `comments add` call: { bead = <id>, content = <file content or text arg> }.
local function comments()
  local out = {}
  local base = fake.dir() .. "/calls"
  local n = 1
  while vim.fn.isdirectory(base .. "/" .. n) == 1 do
    local c = base .. "/" .. n
    local argc = tonumber(slurp(c .. "/argc") or "")
    if argc then
      local args = {}
      for i = 1, argc do
        args[i] = slurp(c .. "/arg" .. i) or ""
      end
      local ai
      for i = 1, argc - 1 do
        if args[i] == "comments" and args[i + 1] == "add" then
          ai = i + 1
          break
        end
      end
      if ai then
        local pos = {}
        local i = ai + 1
        while i <= argc do
          local a = args[i]
          if VALUE_FLAGS[a] then
            i = i + 2
          elseif a:sub(1, 1) == "-" and #a > 1 and #pos < 2 and not a:find("\n") then
            i = i + 1
          else
            pos[#pos + 1] = a
            i = i + 1
          end
        end
        out[#out + 1] = { bead = pos[1], content = slurp(c .. "/file") or pos[2] or "", args = args }
      end
    end
    n = n + 1
  end
  return out
end

local function wait_comments(n, what)
  fake.wait_for(function()
    return #comments() >= n
  end, what or ("%d bd comments add call(s)"):format(n), 5000)
end

-- Lines left-trimmed, so indented message lines still match the raw bodies.
local function norm(s)
  local out = {}
  for _, l in ipairs(vim.split(s, "\n", { plain = true })) do
    out[#out + 1] = vim.trim(l)
  end
  return table.concat(out, "\n")
end

local function big_body()
  local parts = { "BIGSTART first line of a long answer" }
  local i = 0
  while #table.concat(parts, "\n") < 20 * 1024 do
    i = i + 1
    parts[#parts + 1] = ("line %04d: the quick brown fox jumps over the lazy dog, keep every byte"):format(i)
  end
  parts[#parts + 1] = "BIGEND last line of the long answer"
  return table.concat(parts, "\n")
end

local function add(body, extra)
  local t = { bead = "fx-1", messages = { { author = "agent", body = body } } }
  for k, v in pairs(extra or {}) do
    t[k] = v
  end
  return store.add(fake.dir(), t)
end

local function close_floats()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
end

local function resolve_in_float(buf, text)
  fake.open_thread(buf, text)
  fake.press("x")
end

describe("resolving a thread saves it as one bead comment", function()
  before_each(function()
    fake.setup()
    install_bd()
    require("beads").setup({})
  end)

  after_each(function()
    fake.teardown()
  end)

  it("x runs bd comments add once on the bead with header, every message in order, labelled, full text", function()
    local big = big_body()
    local t = add("QQ1: Which cache layer should we use?\nIt matters for the design.", {
      section = "design",
      quote = "the cache layer must be shared",
    })
    store.reply(fake.dir(), t.id, "user", "QQ2: Use redis\nwith a second line")
    store.reply(fake.dir(), t.id, "agent", big)
    store.reply(fake.dir(), t.id, "user", "QQ4: thanks, done")
    local buf = fake.open_detail()
    resolve_in_float(buf, "QQ1:")
    wait_comments(1)
    vim.wait(300)
    local cs = comments()
    assert.equals(1, #cs, "expected one comments add call: " .. vim.inspect(fake.log()))
    assert.equals("fx-1", cs[1].bead)
    local c = norm(cs[1].content)
    assert.is_truthy(c:find(t.id, 1, true), "thread id missing from comment")
    assert.is_truthy(c:lower():find("design", 1, true), "section missing from comment")
    assert.is_truthy(c:find("the cache layer must be shared", 1, true), "quote missing from comment")
    local bodies = {
      { "agent", "QQ1: Which cache layer should we use?\nIt matters for the design." },
      { "user", "QQ2: Use redis\nwith a second line" },
      { "agent", big },
      { "user", "QQ4: thanks, done" },
    }
    local last = 0
    local idpos = c:find(t.id, 1, true)
    for i, b in ipairs(bodies) do
      local p = c:find(norm(b[2]), last + 1, true)
      assert.is_truthy(p, ("message %d missing, out of order or truncated (comment is %d bytes)"):format(i, #c))
      assert.is_true(idpos < p, "header (thread id) does not come before message " .. i)
      local before = c:sub(math.max(last + 1, p - 40), p - 1):lower()
      local labels = b[1] == "agent" and { "a:", "agent" } or { "q:", "you", "user" }
      local labelled = false
      for _, l in ipairs(labels) do
        if before:find(l, 1, true) then
          labelled = true
        end
      end
      assert.is_true(labelled, ("message %d not labelled %s: %q"):format(i, b[1], before))
      last = p + #norm(b[2]) - 1
    end
    assert.is_truthy(c:find("BIGEND last line of the long answer", 1, true), "20 KB message truncated")
    assert.equals("resolved", store.get(fake.dir(), t.id).status)
  end)

  it("is saved once: x again, x after reopening, x after a new reply, x from a new detail buffer", function()
    local t = add("ONCE: Should we ship?")
    local before = vim.deepcopy(store.get(fake.dir(), t.id))
    local buf = fake.open_detail()
    resolve_in_float(buf, "ONCE:")
    wait_comments(1)
    fake.wait_for(function()
      return store.get(fake.dir(), t.id).status == "resolved"
    end, "thread resolved")
    local rec = store.get(fake.dir(), t.id)
    local marker = false
    for k, v in pairs(rec) do
      if before[k] == nil and v ~= nil and v ~= false and k ~= "status" and k ~= "needs" then
        marker = true
      end
    end
    assert.is_true(marker, "no saved-comment state recorded in the thread record: " .. vim.inspect(rec))

    fake.press("x")
    vim.wait(300)
    assert.equals(1, #comments(), "second x added a comment")

    close_floats()
    resolve_in_float(buf, "ONCE:")
    vim.wait(300)
    assert.equals(1, #comments(), "x after reopening the float added a comment")

    close_floats()
    store.reply(fake.dir(), t.id, "agent", "ONCE: one more thing")
    resolve_in_float(buf, "ONCE:")
    vim.wait(300)
    assert.equals(1, #comments(), "x after a new message added a comment")

    close_floats()
    vim.cmd("silent! %bwipeout!")
    local buf2 = fake.open_detail()
    resolve_in_float(buf2, "ONCE:")
    vim.wait(300)
    assert.equals(1, #comments(), "x from a fresh detail buffer added a comment")
  end)

  it("a failing bd still resolves, warns once with Beads:, and the next x retries the save", function()
    local t = add("FAIL: Which port?")
    vim.fn.writefile({ "1" }, fake.dir() .. "/fail_comments")
    local got = fake.capture_notify()
    local buf = fake.open_detail()
    resolve_in_float(buf, "FAIL:")
    wait_comments(1, "attempted bd comments add")
    fake.wait_for(function()
      return store.get(fake.dir(), t.id).status == "resolved"
    end, "thread resolved locally despite the bd failure")
    fake.wait_for(function()
      for _, g in ipairs(got) do
        if g.msg:lower():find("comment", 1, true) then
          return true
        end
      end
    end, "warning about the comment")
    vim.wait(300)
    local warns = {}
    for _, g in ipairs(got) do
      assert.equals("Beads: ", g.msg:sub(1, 7), "notify without the Beads: prefix: " .. g.msg)
      if g.msg:lower():find("comment", 1, true) then
        warns[#warns + 1] = g
      end
    end
    assert.equals(1, #warns, "expected exactly one comment warning: " .. vim.inspect(got))
    assert.equals(vim.log.levels.WARN, warns[1].level)
    assert.is_nil(warns[1].msg:find("\n", 1, true), "warning is not one line: " .. warns[1].msg)

    vim.fn.delete(fake.dir() .. "/fail_comments")
    close_floats()
    resolve_in_float(buf, "FAIL:")
    wait_comments(2, "retried bd comments add")
    vim.wait(300)
    assert.equals(2, #comments())
    assert.is_truthy(comments()[2].content:find("FAIL: Which port?", 1, true))

    close_floats()
    resolve_in_float(buf, "FAIL:")
    vim.wait(300)
    assert.equals(2, #comments(), "a successful retry was saved again")
  end)

  it("unresolved threads write nothing (passes already: guards no comment without resolve)", function()
    local t = add("OPEN: Still thinking?")
    local buf = fake.open_detail()
    fake.open_thread(buf, "OPEN:")
    assert.is_true(fake.reply("not yet"), "r asked for no reply text")
    fake.wait_for(function()
      local cur = store.get(fake.dir(), t.id)
      return cur.messages[#cur.messages].body == "not yet"
    end, "reply stored")
    close_floats()
    vim.wait(300)
    assert.equals(0, #comments())
    assert.equals("open", store.get(fake.dir(), t.id).status)
  end)

  it("a stored thread on a bead labelled human is saved the same way; the human thread alone writes nothing", function()
    local hb = fake.bead({ notes = "earlier\nHUMANQ: should we use sqlite?", labels = { "human" } })
    vim.fn.writefile({ vim.json.encode({ hb }) }, fake.dir() .. "/bead.json")
    fake.write_human({ hb })
    local t = add("STORED: Which ORM?")
    local buf = fake.open_detail()
    fake.open_thread(buf, "HUMANQ:")
    close_floats()
    vim.wait(300)
    assert.equals(0, #comments(), "opening the human thread wrote a comment")
    resolve_in_float(buf, "STORED:")
    wait_comments(1)
    vim.wait(300)
    local cs = comments()
    assert.equals(1, #cs)
    assert.equals("fx-1", cs[1].bead)
    assert.is_truthy(cs[1].content:find(t.id, 1, true))
    assert.is_truthy(cs[1].content:find("STORED: Which ORM?", 1, true))
  end)

  it("the thread float help (?) says resolving saves a comment", function()
    add("HELP: anything?")
    local buf = fake.open_detail()
    fake.open_thread(buf, "HELP:")
    local h = fake.press_for_float("?")
    assert(h, "? opened no help float")
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(h), 0, -1, false)
    local found
    for _, l in ipairs(lines) do
      if l:lower():find("resolve", 1, true) then
        found = found or l
        if l:lower():find("comment", 1, true) then
          return
        end
      end
    end
    error("help line for resolve does not mention the comment: " .. tostring(found))
  end)

  it("README's Thread float section says resolving saves the thread as a bead comment", function()
    local lines = vim.fn.readfile(repo .. "/README.md")
    local sec, inside = {}, false
    for _, l in ipairs(lines) do
      if l:match("^#+ ") then
        inside = l:match("^#+ Thread float") ~= nil
      elseif inside then
        sec[#sec + 1] = l
      end
    end
    local text = table.concat(sec, "\n"):lower()
    assert.is_true(#sec > 0, "README has no Thread float section")
    assert.is_truthy(text:find("comment", 1, true), "README Thread float section does not mention the comment")
    assert.is_truthy(text:find("resolv", 1, true))
  end)
end)
