---
name: beads-ask
description: Read and answer questions the user left on beads (issues) in Neovim (beads.nvim). Use when the user says "check my questions", "answer my bead questions", or mentions beads-ask threads.
---

# beads-ask

The user asks questions on a bead's title, description, design or acceptance
criteria in Neovim. Each question is a **thread** with a stable id like `t3`.
Read the threads, reply, and propose edits with the `beads-ask` CLI. Run it from
inside the project (the root is the nearest `.beads` above cwd, or
`$BEADS_NVIM_ROOT`).

## Workflow

1. List the threads waiting on you:
   `beads-ask list --needs agent`
   `--needs user` lists threads waiting on the user; omit it for all. Add
   `--json` for a JSON array.
2. Read one thread: `beads-ask show t3` (`--json` for the thread object).
3. Answer: `beads-ask reply t3 "Because the cache is rebuilt on startup."`
   For long or multi-line text, pass the body on stdin with `-`:
   `printf '%s' "$BODY" | beads-ask reply t3 -`
4. To suggest a change to the bead, propose it; the user decides whether to apply it:
   `beads-ask propose t3 --field design "New design text"`
   `--field` is one of `title`, `description`, `design`, `acceptance`. The value
   may also be `-` to read stdin.
5. Resolve only when the question is fully dealt with:
   `beads-ask resolve t3 "Done: clarified in the design."`
   The optional note is posted as a message, then the thread is resolved.

All of reply, resolve and propose accept `--author NAME` (default `agent`).

## Rules

- You cannot post as `user`: `--author user` is refused. There is no reopen or
  delete; those are the user's.
- Never resolve a thread that is only a question; reply and let the user resolve.
- Keep replies short, answer first, GitHub-flavoured markdown.
- Never edit the bead yourself on the strength of a thread; use `propose`.
