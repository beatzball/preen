---
title: Pull Requests
description: Review a GitHub pull request without checking it out, in one network call.
sidebar:
  order: 4
---

![preen browsing the files in a GitHub pull request](/preen-pr.webp)

## Review a PR

```sh
preen pr 42           # review PR 42
preen pr              # the PR opened from the current branch
```

With no number, `gh` resolves the pull request opened from the branch you are
standing on. That is the common case: you are on the branch, you want to look
at it.

It is the same picker as [`preen diff`](/docs/browsing): file list on the left,
delta diff on the right, `ctrl-s` to flip between side-by-side and inline,
`enter` for the full file in a pager. The border label carries the PR number
and title so you can tell one review from another.

## What it needs

- the [`gh`](https://cli.github.com) CLI
- a logged-in account — `gh auth login`

`preen` checks both before doing anything, and says which one is missing rather
than failing halfway through.

## It never touches your working tree

**`preen pr` is read-only.** The diff comes over the GitHub API, so there is:

- no checkout
- no fetch
- no branch switch
- no stash

Your working tree, your index and your current branch are left exactly as they
were. You can review a PR in the middle of your own half-finished work and
nothing you have gets moved or hidden.

This is the difference from `gh pr checkout`, which is the usual way to read a
PR locally and which does move you.

## One network call, not ninety

`gh pr diff` is called **once** for the whole pull request, and the result is
cached in a temporary directory for the life of the run.

Each preview then slices its own file out of that cache with a small `awk`
pass. So a 90-file pull request costs one network call, not ninety — and
arrow-keying down the file list is instant instead of waiting on the API at
every step.

The cache is a scratch directory under `$TMPDIR`, created on start and removed
when preen exits.

### How a file is sliced out

Every file in a unified diff opens with a header line:

```
diff --git a/PATH b/PATH
```

The slice matches on the ` b/PATH` **tail**, not on the path anywhere in the
line. A path that itself contains ` b/` would otherwise split in the wrong
place and show you the wrong file.

## When it cannot find a PR

Run `preen pr` on a branch with no open pull request and `gh` says so; preen
passes that first line straight through rather than burying it. The fix is
usually to name the number instead:

```sh
preen pr 42
```

## Related

- [`git diff | preen`](/docs/pipes) does the same rendering for any diff you can
  produce, including `gh pr diff 42 | preen` — that gives you one long scroll
  instead of a per-file picker.
- [Worktrees](/docs/worktrees) is the same read-only idea applied to local
  branches an agent has been working in.
