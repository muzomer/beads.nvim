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
| `n` | `note` | append a note (float) |
| `c` | `comment` | add a comment (float) |
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

`keymaps.thread.*`: `r` / `i` reply (`reply`), `x` resolve (`resolve`), `a` apply the proposal as an
unsaved edit of the detail buffer (`apply`), `n` / `p` next / previous thread (`next`, `prev`), `yr` yank
the run command of a human thread (`yank_run`), `?` / `g?` help, `q` / `<Esc>` close (`close`).

### Tree

`keymaps.tree_view.*`: `<CR>` open, `a` add child, `x` close, `C` claim, `R` refresh, `H` toggle closed, `L` cycle the layout (left, bottom, right, top), `f` filter (free text plus `status:`, `label:`, `assignee:`, `type:` tokens; empty clears), `s` cycle the sort (priority, updated, id),
`yy` yank id, `yr` yank run command, `q` close, `?` / `g?` help, `za`/`zo`/`zc` fold.

### Input floats (note, comment)

`keymaps.input.*`: `<C-s>` submit (normal and insert, `submit`), `<CR>` submit (normal,
`submit_normal`), `q` and `<Esc>` cancel (normal, `cancel`).

### fzf-lua picker

`keymaps.picker.*`: `<CR>` open, `ctrl-y` (`yank_id`), `alt-r` (`yank_run`), `ctrl-x` (`close`).

## Highlights and glyphs

All colours come from `Beads*` highlight groups (`BeadsId`, `BeadsTitle`, `BeadsDim`,
`BeadsStatus{Open,InProgress,Blocked,Closed,Deferred}`, `BeadsPriority0..4`, `BeadsType{Epic,Bug,Feature,Task,Chore}`,
`BeadsBadge{User,Agent}`, `BeadsBlocked`, `BeadsCurrent`, `BeadsFlash`, `BeadsFold`, `BeadsGuide`, `BeadsHeader`,
`BeadsWinbar*`, `BeadsMode{View,Edit}`). They are defined with `default = true` as links to standard groups,
re-applied on `ColorScheme`; override any with `:hi` or `:hi! link`.

`glyphs` sets the status glyphs (defaults `○ ◐ ● ✓ ❄` for open, in_progress, blocked, closed, deferred):
`setup({ glyphs = { open = "O" } })` overrides single ones; `setup({ glyphs = "ascii" })` uses plain ASCII
`o ~ x v z`. `type_icons = { epic = "E", bug = "B", ... }` enables optional type icons (off by default).
