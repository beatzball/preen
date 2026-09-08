---
title: Browsing
description: The picker, the keys, and flipping between side-by-side and inline.
sidebar:
  order: 2
---

## The three ways in

```sh
preen                 # auto: diffs in a git repo, else markdown
preen md [DIR]        # browse markdown files under DIR (default .)
preen diff [REV]      # browse files changed vs REV (default: working tree)
preen FILE.md         # render one file and quit
```

`preen` with no argument asks git one question — *am I inside a work tree?* —
and picks `diff` if the answer is yes and `md` if it is no.

## `preen md` — browse markdown

```sh
preen md              # every .md under the current directory
preen md docs/        # under docs/ instead
```

It finds every `.md` and `.markdown` file below the directory you name,
skipping `.git/` and `node_modules/`, and sorts them. The file list is on the
left; `glow` renders the file under the cursor on the right.

## `preen diff` — browse changes

```sh
preen diff            # everything not committed yet
preen diff main       # everything that differs from main
preen diff HEAD~3     # ...or from three commits ago
```

With **no revision**, the list is what `git diff --name-only HEAD` reports plus
your untracked files, sorted and de-duplicated. That means **staged and
unstaged changes appear together** — you see the file as it will land, not one
half of it.

An untracked file has nothing to diff against, so preen shows the whole file as
one large addition rather than skipping it.

In a repository with no commit yet there is no `HEAD` to compare with, so it
falls back to the index.

With a **revision**, the list is exactly `git diff --name-only REV`.

## `preen FILE.md` — render one file

```sh
preen README.md
```

No picker and no fzf: it renders the file and exits. Useful in a script, and
useful when you already know which file you want.

This path is for markdown only. To render a single **diff**, pipe it in — see
[Pipes](/docs/pipes).

## Side-by-side or inline

Diffs start **side-by-side**. Press `ctrl-s` to flip to inline, and `ctrl-s`
again to flip back. The preview repaints immediately; the toggle is live, so
you can switch mid-review on a file that is too wide for two columns.

To start in inline instead:

```sh
PREEN_LAYOUT=inline preen diff
```

The toggle works in `diff`, `pr` and `worktrees` modes. Markdown has one
layout, so `ctrl-s` does nothing in `md` mode.

How the toggle is wired — two named delta features — is explained in
[Theming](/docs/theming). It matters if you edit your own delta config, because
one common mistake silently breaks it.

## Keys

| key | action |
|---|---|
| `ctrl-s` | toggle side-by-side / inline (diff, pr and worktrees modes) |
| `enter` | open the full render in a pager |
| `ctrl-e` | open in `$EDITOR` |
| `ctrl-d` / `ctrl-u` | scroll the preview 8 lines |
| `pgdn` / `pgup` | scroll the preview half a page |
| `shift-down` / `shift-up` | scroll the preview one line |
| `home` / `end` | jump the preview to the top or bottom |
| `ctrl-/` | hide or show the preview |
| `esc` | quit, or in worktrees mode go back one level |
| `ctrl-c` | quit |

Typing filters the list, as in any fzf picker. The arrow keys move the cursor
and the list cycles at both ends.

### `enter` versus the preview

The preview pane is a preview: it is 65% of the window and it does not scroll
with your mouse. `enter` renders the same file at full terminal width into
`less -R`, which is where to read anything longer than a screen. `q` comes back
to the picker.

### Preview scrolling is jumpy, on purpose

`ctrl-d` moves eight lines in one step rather than sliding. fzf has no timer or
delay action, so a chain of `preview-down` binds still paints a single frame.
Smooth scrolling would need something that redraws on its own tick, which a
`--bind` chain cannot do.

## What it will not do

- **No inline images.** tmux swallows the kitty graphics escapes and dumps the
  payload into the pane title. `mdcat` was tried and dropped for this reason.
- **No editing.** `ctrl-e` hands the file to `$EDITOR` and that is as far as it
  goes.

Next: [Pipes](/docs/pipes), or [Pull requests](/docs/pull-requests).
