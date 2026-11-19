local M = {}

M.default_glyphs = {
  clean = "✅",
  issues = "❌",
  gate_pass = "🟢",
  gate_fail = "🔴",
  human = "👤",
  needs_review = "👀",
  parked = "⏸",
  waiting = "💬",
}

local TASK_FIELDS = { "verdict", "review_round", "findings", "gate", "tdd", "bookmark", "change", "rounds", "parked" }
local EPIC_FIELDS = { "full_suite", "full_suite_culprit" }

local function glyphs()
  local ok, beads = pcall(require, "beads")
  local user = ok and beads.config and beads.config.workflow and beads.config.workflow.glyphs or {}
  return vim.tbl_extend("force", M.default_glyphs, user)
end

local function has_label(bead, label)
  for _, l in ipairs(bead.labels or {}) do
    if l == label then
      return true
    end
  end
  return false
end

function M.badges(bead)
  local g, meta, out = glyphs(), bead.metadata or {}, {}
  if meta.verdict == "CLEAN" then
    out[#out + 1] = g.clean
  elseif meta.verdict == "ISSUES" then
    local round = meta.review_round
    out[#out + 1] = g.issues .. (round ~= nil and ("r" .. tostring(round)) or "")
  end
  if meta.gate == "pass" then
    out[#out + 1] = g.gate_pass
  elseif meta.gate == "fail" then
    out[#out + 1] = g.gate_fail
  end
  if has_label(bead, "human") then
    out[#out + 1] = g.human
  end
  if has_label(bead, "needs-review") then
    out[#out + 1] = g.needs_review
  end
  if meta.parked ~= nil then
    out[#out + 1] = g.parked
  end
  if bead.waiting_user then
    out[#out + 1] = g.waiting
  end
  return out
end

function M.fields(bead)
  local meta, out = bead.metadata or {}, {}
  local keys = vim.list_extend({}, TASK_FIELDS)
  if bead.type == "epic" then
    vim.list_extend(keys, EPIC_FIELDS)
  end
  for _, k in ipairs(keys) do
    if meta[k] ~= nil then
      out[#out + 1] = { name = k, value = meta[k] }
    end
  end
  return out
end

function M.run_command(bead)
  local cmd = bead.type == "epic" and "run-epic" or "run-bead"
  return "/beads-workflow:" .. cmd .. " " .. bead.id
end

function M.is_needs_me(bead)
  return has_label(bead, "human") or has_label(bead, "needs-review")
end

-- Yanks text to the " register and says so (one consistent message for tree, detail, pickers).
function M.yank(text)
  vim.fn.setreg('"', text)
  vim.notify("Beads: yanked " .. text, vim.log.levels.INFO)
end

-- The plugin's bin/ directory (holds beads-ask).
function M.plugin_bin()
  return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h") .. "/bin"
end

-- Hands a prompt to agent-poke.nvim; without it (or when it fails) the prompt goes to the " register.
-- note: optional lead-in for the fallback message.
-- ctx: optional { bead, thread, base_n } to follow the poke's progress (see beads.progress).
-- ctx.on_settled: optional; called once when delivery no longer has an agent picker open: right away
-- normally, or after the pick was answered or cancelled. It is not called while the picker stays open.
local PICKER_APPEAR_MS = 3000

function M.deliver(root, prompt, note, ctx)
  local ok, poke = pcall(require, "agent-poke")
  if ok and type(poke) == "table" and poke.poke then
    local settled = false
    local function settle()
      if settled then
        return
      end
      settled = true
      if ctx and ctx.on_settled then
        vim.schedule(ctx.on_settled)
      end
    end
    -- agent-poke has no completion callback: watch for its picker (vim.ui.select) while poke runs.
    -- Known limit: within the PICKER_APPEAR_MS window the first vim.ui.select of any caller (another
    -- plugin, or a second quick submit) is taken as agent-poke's picker.
    local orig = vim.ui.select
    local seen, expired = false, false
    local wrapper
    wrapper = function(items, opts, on_choice)
      if seen or expired then
        return orig(items, opts, on_choice)
      end
      seen = true
      if vim.ui.select == wrapper then
        vim.ui.select = orig
      end
      return orig(items, opts, function(...)
        local ok_c, e = pcall(on_choice, ...)
        settle()
        if not ok_c then
          error(e, 0)
        end
      end)
    end
    vim.ui.select = wrapper
    local pok, err, id = pcall(poke.poke, root, prompt, {
      env = { PATH = M.plugin_bin() .. ":" .. (vim.env.PATH or "") },
      tools = { "Bash(beads-ask:*)", "Bash(bd show:*)" },
    })
    local function unwrap()
      if vim.ui.select == wrapper then
        vim.ui.select = orig
      end
    end
    if not pok or seen or not (err == false and id == nil) then
      unwrap()
      if not seen then
        settle()
      end
    else
      -- poke is pending without a picker yet (it opens one from insert mode on the next tick)
      vim.defer_fn(function()
        expired = true
        unwrap()
        if not seen then
          settle()
        end
      end, PICKER_APPEAR_MS)
    end
    if pok then
      if ctx and ctx.bead and ctx.thread and (id ~= nil or err == false) then
        require("beads.progress").add({
          root = root,
          bead = ctx.bead,
          thread = ctx.thread,
          base_n = ctx.base_n,
          prompt = prompt,
          id = id,
        })
      end
      return
    end
    vim.notify("Beads: agent-poke failed: " .. (tostring(err):match("[^\n%s][^\n]*") or ""), vim.log.levels.WARN)
  end
  if not (ok and type(poke) == "table" and poke.poke) and ctx and ctx.on_settled then
    vim.schedule(ctx.on_settled)
  end
  vim.fn.setreg('"', prompt)
  vim.notify(
    "Beads: "
      .. (note and note .. " " or "")
      .. "agent-poke is not available; the prompt is in the \" register.",
    vim.log.levels.WARN
  )
end

return M
