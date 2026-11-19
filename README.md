# beads.nvim

Neovim front end for the [beads](https://github.com/steveyegge/beads) issue tracker (`bd`).
Commands: `:Beads tree [left|right|bottom|top]|ready|list|search|needs|epics|questions|show <id>|create|cd <path>|poke [pick]|output|chat`.
`poke`, `output` and `chat` pass through to [agent-poke.nvim](https://github.com/momer/agent-poke.nvim)
(a hint is shown when it is not installed); `poke` resends the threads waiting on the agent, `poke pick` chooses a target.

## Keymaps

Configure with `require("beads").setup({ keymaps = { ... } })`. Every entry is a key, a list of keys
or `false` (disabled); `keymaps = false` creates no maps at all. Every map has a `desc` (which-key).
`<leader>bd` is never mapped by the plugin.

### Global

| key | config | action |
|---|---|---|
| `<leader>bt` | `tree` | toggle the tree |
| `<leader>br` | `ready` | ready picker |
| `<leader>bl` | `list` | list picker |
| `<leader>bs` | `search` | search picker (prompts for the query) |
| `<leader>bn` | `needs` | needs-me picker |
| `<leader>be` | `epics` | epics picker |
| `<leader>bq` | `questions` | questions waiting on you |
| `<leader>bc` | `create` | create a bead |
| `<leader>b?` | `help` | the keys that work where you are |
| `<leader>bp` | `poke` | poke the agent about threads waiting on it (`:Beads poke`) |
| `<leader>bP` | `output` | show the agent output (`:Beads output`) |

### Detail buffer (`beads://<id>`)

The buffer opens in VIEW mode (read-only, `vim.b.beads_mode == "view"`). `require("beads").mode()`
returns the mode for a statusline.

| key | config (`keymaps.detail.view.*`) | action |
|---|---|---|
| `e`, `i` | `edit` | switch to EDIT mode |
| `x` | `close_bead` | close the bead (asks for a reason) |
| `C` | `claim` | claim |
| `<CR>` | `open_thread` | open the question thread under the cursor (`## Questions`) |
| `]u`, `[u` | `next_waiting`, `prev_waiting` | jump to the next / previous thread waiting for you |
| `]b`, `[b` | `next_bead`, `prev_bead` | open the next / previous bead in tree order in this window (a count works; follows the open tree's sort, filter and `H`) |
| `gd` | `peek` | peek the bead id under the cursor in a floating read-only detail (see "Peek floats"); other words fall back to Vim's `gd` |
| `K` | `details` | bead details (peek float) for the bead id under the cursor; does nothing elsewhere |
| `n` | `note` | append a note (float) |
| `c` | `comment` | add a comment (float) |
| `a` | `ask` | ask a question about the section under the cursor (or the visual selection) |
| `yy` | `yank_id` | yank the bead id |
| `yr` | `yank_run` | yank the workflow run command |
| `q` | `close` | close the window |
| `?`, `g?` | `help` | help float |

EDIT mode (`keymaps.detail.edit.*`) is normal Vim editing; `:w` saves and returns to VIEW mode (a
failed or refused save stays in EDIT). `beads://new` opens in EDIT mode.

| key | config | action |
|---|---|---|
| `<C-s>` | `save` | save (normal and insert) |
| `<Esc><Esc>` | `view` | back to VIEW mode; asks before discarding edits |
| `g?` | `help` | help float |

### Thread float

`keymaps.thread.*`: `r` / `i` reply (`reply`), `x` resolve (`resolve`; the whole thread is saved once as one bead comment via `bd comments add`, retried on the next `x` if bd failed), `a` apply the proposal as an
unsaved edit of the detail buffer (`apply`), `n` / `p` next / previous thread (`next`, `prev`), `yr` yank
the run command of a human thread (`yank_run`), `K` peek the bead id under the cursor (`details`), `?` / `g?` help, `q` / `<Esc>` close (`close`).

### Peek floats (`gd`)

`gd` on a bead id (detail VIEW, tree, thread float) opens that bead in a floating, read-only detail view with the same rendering and highlighting; it follows live updates (the watcher is held while any peek float is open). Floats stack, offset down and right; `gd` on a bead already open focuses it. `keymaps.detail.view.peek`, `keymaps.tree_view.peek` and `keymaps.thread.peek` set the `gd` key (`false` disables). A float has the detail view's keys and they act on the float's bead: `e` / `i` open it in the main window in EDIT mode and close the floats (`edit`), `x` close (`close_bead`), `C` claim (`claim`), `n` note (`note`), `c` comment (`comment`), `a` ask (`ask`), `<CR>` on a question line opens its thread (`open_thread`), `]u` / `[u` jump between threads waiting for you (`next_waiting`, `prev_waiting`), `]b` / `[b` replace the float's bead in place with the next / previous bead in tree order (`next_bead`, `prev_bead`; a count works), `K` / `gd` peek the bead id under the cursor (`details`, `peek`), `yy` (`yank_id`), `yr` (`yank_run`), `?` / `g?` help (`help`). Keys come from `keymaps.detail.view.*`; `keymaps.peek.*` (same action names) overrides them for floats. Float-only keys: `q` / `<Esc>` close the top float (`close`), `Q` close all (`close_all`), `<CR>` elsewhere opens the bead in the main window and closes all (`open`). Actions that change the bead refresh the float.

### Tree

`tree.layout` picks the default view. `"full"` (the default): the tree fills the current window (like a file explorer); `<CR>` or a click on a bead opens its detail in a window above and the tree below (`tree.height`, default about 40% of the lines), and closing the detail (`q`) returns to the tree only; `K` shows the details float without changing the layout; closing the tree restores the window's previous buffer. `"split"`: the tree opens as a split at `tree.position` and `<CR>` opens the bead in the other window. `:Beads tree left|right|bottom|top` always opens a split.

`tree.width` (left/right) and `tree.height` (bottom/top) default to `"auto"`: the tree fits its longest visible line (at least 24 columns) or its visible row count (at least 6), refitting after every render and on `VimResized`. `tree.max_width` (default half the columns) and `tree.max_height` (default 40% of the lines) cap the auto size. A number keeps a fixed size. Resizing the tree window by hand stops auto-fit until the tree is reopened.

`keymaps.tree_view.*`: `<CR>` open, `a` add child, `x` close, `C` claim, `R` refresh, `H` toggle closed, `L` cycle the layout (left, bottom, right, top), `f` filter (free text plus `status:`, `label:`, `assignee:`, `type:` tokens; empty clears), `s` cycle the sort (priority, updated, id),
`gd` peek, `K` bead details for the cursor row in a peek float (`details`; `false` disables), `yy` yank id, `yr` yank run command, `q` close, `?` / `g?` help, `za`/`zo`/`zc` fold.
Selection: `m` toggles a mark and moves the cursor down to the next bead (`▍`, `BeadsMarked`; `3m` marks three beads, `mark`), `M` clears all marks (`clear_marks`), `A` opens the action menu (`actions`): close, claim, reopen, yank ids, yank run commands, set priority, set status, set assignee, set type, add label, remove label, move under epic, remove parent, blocked by, remove dependency. `x`, `C`, `yy` and `yr` act on the marked beads, else on the visual line range (`x`, `C`, `yy`, `yr`, `A`; yanks put one id or run command per line), else on the cursor bead. More than one bead asks `Close 3 beads? [y/N]`; closing runs one `bd batch`, reopening one `bd reopen`. Marks are kept by bead id across refresh, folds, filters and layout moves; failed beads stay marked and one `Beads: n of m failed: <ids>` note is shown.

### Input floats (ask, reply, note, comment)

`a` in detail VIEW mode (and `r` in a thread float) opens a multi-line ask box titled with the bead id
and the section or quote. `keymaps.input.*`: `<C-s>` save (normal and insert, `submit`), `<CR>` save
(normal, `submit_normal`), `<M-s>` save and send to the agent (`send`; without agent-poke the prompt is
copied), `q` and `<Esc>` cancel (normal, `cancel`). Empty text saves nothing.

`setup({ ask = { open_after_send = true } })` opens the new thread's float after every save (`false`
keeps the detail buffer focused).

Replies written by `beads-ask reply` appear live: while a beads view is open, `.beads-nvim/questions.json`
is watched and the Questions section, thread floats and badges refresh. Each agent reply notifies
`Beads: agent replied on <bead id>: <first line>` (grouped within `notify_group_ms`, silenced by `notify = false`).

### fzf-lua picker

`keymaps.picker.*`: `<CR>` open, `ctrl-y` (`yank_id`), `alt-r` (`yank_run`), `ctrl-x` (`close`).

Multi-select: `<Tab>` toggles a selection, `ctrl-a` opens the action menu for the selected beads. `ctrl-y` and `alt-r` yank every selected id / run command, one per line; `ctrl-x` closes all selected; `<CR>` opens the first selection and notes how many others were ignored.

## Statusline

`require("beads").status()` returns a short string such as `◐ 2  ○ 5 ready  💬 1`
(in progress, ready, waiting on you), read from the cached store (it never spawns `bd`).
`◐` counts every in-progress bead, including those waiting on you, which also count under `💬`.
For lualine:

```lua
lualine_x = { require("beads").lualine }
```

## Highlights and glyphs

All colours come from `Beads*` highlight groups (`BeadsId`, `BeadsTitle`, `BeadsDim`,
`BeadsStatus{Open,InProgress,Blocked,Closed,Deferred}`, `BeadsPriority0..4`, `BeadsType{Epic,Bug,Feature,Task,Chore}`,
`BeadsBadge{User,Agent}`, `BeadsBlocked`, `BeadsCurrent`, `BeadsFlash`, `BeadsFold`, `BeadsGuide`, `BeadsHeader`,
`BeadsWinbar*`, `BeadsMode{View,Edit}`). They are defined with `default = true` as links to standard groups,
re-applied on `ColorScheme`; override any with `:hi` or `:hi! link`.

`glyphs` sets the status glyphs (defaults `○ ◐ ● ✓ ❄` for open, in_progress, blocked, closed, deferred):
`setup({ glyphs = { open = "O" } })` overrides single ones; `setup({ glyphs = "ascii" })` uses plain ASCII
`o ~ x v z`. `type_icons = { epic = "E", bug = "B", ... }` enables optional type icons (off by default).

## Symbols

Each symbol has one meaning (the exception: `·` also separates fields in the tree header and the detail winbar). The help float (`?`, `g?`, `<leader>b?`) lists the ones of the current view
using your active glyphs; all of them are configurable (`glyphs`, `workflow.glyphs`).

| Symbol | Meaning |
| --- | --- |
| ○ | open |
| ◐ | in progress |
| ● | blocked |
| ✓ | closed |
| ❄ | deferred |
| · | unknown status |
| ✅ | review clean |
| ❌ / ❌r2 | review found issues (r<n> = review round) |
| 🟢 | gate pass |
| 🔴 | gate fail |
| 👤 | needs a human |
| 👀 | needs review |
| ⏸ | parked |
| 💬 | waiting on you |
| ▾ / ▸ | tree node expanded / folded |
| ⛔ | blocked by another bead |
| │ ├ └ | tree guides |
| ▍ | marked for a group action (`m` / `M`) |
| [+] | detail buffer modified (unsaved edits) |
| ⚠ | detail buffer changed on disk |

## Detail winbar, highlights and render-markdown.nvim

Detail windows get a winbar `<glyph> <id> · <type> · P<n> · <status> · VIEW|EDIT`, plus `[+]` (modified) while
there are unsaved edits and `⚠ changed on disk` after an external change. Frontmatter values are coloured with
the `Beads*` groups, and comment headings show a relative time (`2h ago`) as virtual text. For tests the clock
can be injected with `setup({ now = function() return unix_seconds end })`.

With [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) the detail buffer
(filetype `markdown`) is rendered as usual (headings, code fences). The frontmatter stays readable: the
`key: value` lines are not concealed or overlaid, the Beads value highlights are extmarks that stay on top,
and the buffer text is never changed, so parse/render round-trips. If your setup conceals frontmatter, disable
it for `beads://` buffers.
