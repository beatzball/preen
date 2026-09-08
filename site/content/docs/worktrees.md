---
title: Worktrees
description: Pick a git worktree, then browse exactly what it changed.
sidebar:
  order: 5
---

## What did the agent change?

```sh
preen worktrees       # or: preen wt
```

Agents work in git worktrees. When one says it is finished, the question is
always the same: *what did it actually change?* This mode answers it in two
levels.

## Level one: pick a worktree

You get one line per worktree, with the file count first:

```
   1 file   worktree-cutoff           .claude/worktrees/cutoff
   5 files  worktree-read-render      .claude/worktrees/read-render
   6 files  worktree-rewire           .claude/worktrees/rewire
```

The count leads because the list pane is narrow, and the path is the one column
that can afford to run off the end.

The preview on the right shows, for the worktree under the cursor:

- the worktree path
- its branch
- the base it is measured against, and which branch that base came from
- every commit made on it since that base
- the whole diff, in your chosen layout

**The main checkout is not in the list.** `git` always reports it first, so
preen takes that first record as the repository root and drops it. This mode is
about the other worktrees.

A repository with no worktrees besides the main checkout says so and exits.

## Level two: browse its files

Pick a worktree with `enter` and the normal file picker opens on it: file list
on the left, delta diff on the right, `ctrl-s` to flip layout, `enter` for the
full file in a pager, `ctrl-e` to open it in `$EDITOR`.

- `esc` goes **back** to the worktree list
- `ctrl-c` quits altogether

That is the one place `esc` does not mean quit. Going back is what you want
when you are working through three worktrees in a row.

A worktree that has changed nothing against its base says so instead of showing
an empty list, and `esc` takes you back.

## Measured against the merge-base

The count and the diff are both against the **merge-base** with the default
branch, not against its tip.

That is the difference between *what this worktree did* and *everything that
has happened since it branched*. Compare against the tip and every commit
someone else landed on `main` in the meantime shows up as though the agent had
touched it.

The default branch is read from `origin/HEAD`. If that is not set, preen falls
back to `main` and then `master`, preferring a local branch of that name over
the remote-tracking one.

Uncommitted and untracked files in the worktree are counted and browsable too,
so work an agent has not committed yet is not invisible.

## It is read-only

Like [`preen pr`](/docs/pull-requests), this mode only reads. The complete list
of git commands it runs is:

- `git worktree list`
- `git merge-base`
- `git symbolic-ref`, `git rev-parse`
- `git log`
- `git diff`
- `git ls-files`

**No checkout, no fetch, no stash and no commit, in any worktree.** Whatever an
agent has half-done in there stays exactly as it left it.

## Keys

| key | action |
|---|---|
| `enter` | open the worktree (level one) or the file (level two) |
| `ctrl-s` | toggle side-by-side / inline |
| `ctrl-e` | open in `$EDITOR` — level two only |
| `ctrl-d` / `ctrl-u` | scroll the preview 8 lines |
| `pgdn` / `pgup` | scroll the preview half a page |
| `esc` | go back one level, or quit from level one |
| `ctrl-c` | quit |

The full key table is in [Browsing](/docs/browsing).
