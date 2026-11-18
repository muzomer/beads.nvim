-- Bead beads_nvim-4u9.8: detail buffers with render-markdown.nvim.
-- With render-markdown.nvim loaded (skipped when it is not installed), a detail buffer:
--   * keeps filetype markdown and gets rendered by render-markdown (it attaches);
--   * keeps its frontmatter readable: no render-markdown extmark conceals or overlays text on the
--     key: value lines between the '---' delimiters, and the buffer text is unchanged;
--   * still round-trips: parse(buffer lines) gives back the bead's fields;
--   * keeps the Beads* frontmatter value highlights.
-- The README documents the render-markdown interaction (mentions "render-markdown").
-- bd is a fake on PATH (tests/detail_winbar_fake.lua).

local fake = require("tests.detail_winbar_fake")
local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function find_render_markdown()
  local candidates = {
    vim.env.RENDER_MARKDOWN_DIR or "",
    repo .. "/.deps/render-markdown.nvim",
    vim.fn.stdpath("data") .. "/site/pack/core/opt/render-markdown.nvim",
    vim.fn.stdpath("data") .. "/lazy/render-markdown.nvim",
  }
  for _, p in ipairs(candidates) do
    if p and p ~= "" and vim.fn.isdirectory(p .. "/lua/render-markdown") == 1 then
      return p
    end
  end
end

local rm_dir = find_render_markdown()
local rm_ok = false
if rm_dir then
  vim.opt.runtimepath:append(rm_dir)
  vim.cmd("runtime! plugin/render-markdown.lua")
  local ok, rm = pcall(require, "render-markdown")
  rm_ok = ok and pcall(rm.setup, {})
  rm_ok = rm_ok and pcall(vim.treesitter.language.inspect, "markdown")
end

local function rm_ns()
  return vim.api.nvim_get_namespaces()["render-markdown.nvim"]
end

local function rm_marks(buf, row)
  local ns = rm_ns()
  if not ns then
    return {}
  end
  return vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, { details = true, overlap = true })
end

local function rendered(buf)
  local ns = rm_ns()
  return ns and #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) > 0
end

describe("detail buffer with render-markdown.nvim", function()
  before_each(function()
    fake.setup({ labels = { "ui" }, assignee = "me" })
    require("beads").setup({})
  end)

  after_each(function()
    fake.teardown()
  end)

  it("keeps the frontmatter readable and the buffer round-trippable", function()
    if not rm_ok then
      pending("render-markdown.nvim (or the markdown parser) not available; manual check documented in README")
      return
    end
    local buf = fake.open_detail()
    assert.equals("markdown", vim.bo[buf].filetype)
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
    fake.wait_for(function()
      return rendered(buf)
    end, "render-markdown to render the detail buffer", 3000)

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.equals("---", lines[1])
    local close
    for i = 2, #lines do
      if lines[i] == "---" then
        close = i
        break
      end
    end
    assert(close, "no closing frontmatter delimiter")
    for row = 1, close - 2 do
      for _, m in ipairs(rm_marks(buf, row)) do
        local d = m[4]
        assert.is_nil(d.conceal, ("render-markdown conceals frontmatter line %q"):format(lines[row + 1]))
        assert.is_false(
          d.virt_text ~= nil and (d.virt_text_pos == "overlay" or d.virt_text_pos == "inline"),
          ("render-markdown draws over frontmatter line %q: %s"):format(lines[row + 1], vim.inspect(d.virt_text))
        )
      end
    end

    -- buffer text unchanged by rendering, and it parses back to the bead
    local render = require("beads.buffer.render")
    local parse = require("beads.buffer.parse")
    local snap = require("beads.views.detail").snapshot(buf)
    local expected = render.render(snap)
    assert.same(expected, vim.api.nvim_buf_get_lines(buf, 0, #expected, false))
    local f = parse.parse(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.equals(fake.TITLE, f.title)
    assert.equals("open", f.status)
    assert.equals(2, f.priority)
    assert.equals("task", f.type)
    assert.equals("me", f.assignee)
    assert.same({ "ui" }, f.labels)
    assert.equals("desc", f.description)
  end)

  it("keeps the Beads* frontmatter value highlights", function()
    if not rm_ok then
      pending("render-markdown.nvim (or the markdown parser) not available")
      return
    end
    local buf = fake.open_detail()
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    fake.wait_for(function()
      return rendered(buf)
    end, "render-markdown to render the detail buffer", 3000)
    local row, line = fake.row_of(buf, "status: ")
    local col = line:find("open", 1, true) - 1
    fake.wait_for(function()
      return vim.tbl_contains(fake.groups_at(buf, row, col), "BeadsStatusOpen")
    end, "BeadsStatusOpen on the status value: " .. vim.inspect(fake.groups_at(buf, row, col)), 2000)
  end)
end)

describe("README", function()
  it("documents the render-markdown.nvim interaction", function()
    local text = table.concat(vim.fn.readfile(repo .. "/README.md"), "\n")
    assert.is_truthy(text:lower():find("render-markdown", 1, true), "README does not mention render-markdown.nvim")
  end)
end)
