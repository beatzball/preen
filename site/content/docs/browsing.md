---
title: Browsing
description: The picker, the keys, and flipping between side-by-side and inline.
sidebar:
  order: 2
---

## The ways in

```sh
preen                 # auto: diffs in a git repo, else markdown
preen md [DIR]        # browse markdown files under DIR (default .)
preen diff [REV]      # browse files changed vs REV (default: working tree)
preen watch [REV]     # keep local diffs live (fzf 0.73 or newer)
preen log [RANGE]     # pick a commit, then browse its files
preen FILE.md         # render one file, paged, and quit
... | preen           # render piped input and quit
preen - < FILE        # the same, said out loud
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

With fzf 0.45 or newer, press `ctrl-l` to choose a relative Markdown link
from the current file.
Following a link clears the search and selects its destination in the file
list. If the destination is outside the list, the picker shows a message
and stays on the current file. `esc` closes the link menu.

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

## `preen log` — browse commits

```sh
preen log
preen log main..HEAD
preen log HEAD~5..HEAD
preen log HEAD^!       # only the latest commit
```

The first picker lists each commit's short hash, author date, file count and
subject. Its preview shows the commit details and stat. Press `enter` to browse
that commit's files, then `esc` to return to commits. At the commit list, `esc`
quits; `ctrl-c` quits from either level, as in [Worktrees](/docs/worktrees).
An empty commit opens an empty file picker; `esc` still returns to commits.

`RANGE` accepts a Git revision or range. Without one, preen shows commits on
the current branch since its merge-base with the default branch. It reads
`origin/HEAD`, then tries `main`, then `master`. When that inferred range is
empty, or no merge-base is available, it shows the last 50 commits. Bare
`preen log` therefore also browses recent history on the default branch.
An explicitly supplied empty range reports that there is nothing to show.

Each file compares the commit with its first parent. A root commit compares
with the empty tree. Renames appear as a removal and an addition. Local edits,
staged changes and untracked files stay outside these comparisons. Nothing is
checked out, fetched or stashed.

If a range includes a commit whose parent history is missing, such as the
boundary of a shallow clone, preen reports the affected commit and stops before
opening the picker. Choose a newer range with available parents, or obtain the
missing history yourself before retrying. Only commits with no parent in their
stored header compare with the empty tree; preen does not fetch history.

The file picker supports the usual layout toggle, full render, viewed marks,
review notes and editor jump. Viewed progress belongs to the full commit SHA, so opening the
same commit through another range preserves it. `ctrl-e` opens your checkout's
copy of the path at the first hunk from the commit; your local lines may differ,
and a missing file opens plainly. The commit list uses `enter` to open files
and has no editor, viewed, or review-note action.

## Viewed files

Press `ctrl-v` in a diff, PR, commit, or worktree file picker to mark the current file
as viewed. A dim `✓` appears beside it, and the header counts `12 of 40 viewed`.
Press `ctrl-v` again to unmark it.

Marks survive quitting and reopening the same review. Each repository and
comparison has separate progress: the working tree, an explicit revision, a
PR number, commit SHA, or a worktree path. A mark records the file's diff content; when
that diff changes, the next list refresh clears the mark. Reopening the picker
or returning from the editor refreshes the list. Markdown mode has no viewed
marks.

Review state lives in `preen/` under `$XDG_STATE_HOME`, or under
`$HOME/.local/state` when that variable is unset or empty. It stays outside the
checkout. Set `XDG_STATE_HOME` to an absolute directory outside your repositories
to choose another location. Removing the `preen/` state directory clears saved
review progress.

## Review notes

Press `ctrl-n` in a diff, PR, commit, or worktree file picker to edit a note for the
current file in `$EDITOR`. A separate `✎` marks files with notes. The editor
opens a temporary buffer; saving an empty buffer removes the note. Use a
waiting editor, for example `EDITOR="code --wait"`. If the editor exits with
an error, the saved note stays as it was.

Notes survive restarting the same review and remain when the file's diff
changes or disappears. They share the viewed-mark store outside checkouts,
with separate notes for each repository and comparison. Markdown mode has
no review notes.

Print the notes as plain Markdown to paste or pipe elsewhere:

```sh
preen notes             # working-tree review
preen notes diff main   # review against main
preen notes pr 42       # PR review
preen notes wt PATH     # worktree review
preen notes log SHA     # one commit's review
```

`preen notes diff` also exports the working-tree review. Run these commands
inside the repository you used for the review. `PATH` names one of that
repository's worktrees. `log SHA` exports the same immutable commit target
used by the log file picker; a short SHA or single-commit reference such as
`HEAD` resolves to that full SHA. Ranges are not accepted for this export.
Export follows the current file list's order, with
notes for paths that left the diff appended in filename order. Each section
starts with `## filename`, followed by the note's text. Export is plain text,
without colors or a pager; an empty review prints nothing. PR export reads
the current PR list over the network, just as the picker does.

## `preen watch` — follow changes as they happen

```sh
preen watch           # staged, unstaged and untracked changes
preen watch main      # changes against a revision, like preen diff main
```

Watch checks local content every second. Edits refresh the preview, new files
enter the list, and reverted files leave it. The selected file stays selected
while it remains in the list, including when another file is inserted ahead of
it. The header shows the time changes were last detected. A clean repository
opens an empty picker and waits for its first change.

Watch uses the same keys as the diff picker below. Viewed marks clear as soon
as a watched file changes, and the header updates its viewed count. `esc` or `ctrl-c` quits and
stops polling. It watches local diffs; PR and worktree lists are not watched.
With a revision, untracked files stay outside the list, just as in `preen diff`.

**Watch needs fzf 0.73 or newer**, whose path identity and background reload support
preserve your selection across list reloads. Older fzf still works for other preen modes;
watch exits with upgrade advice before starting a poller. Update fzf with
your package manager or an [upstream release](https://github.com/junegunn/fzf/releases).

## `preen FILE.md` — render one file

```sh
preen README.md
```

No picker and no fzf. On a terminal the render is paged through `less -R`, so
it stays on screen until you press `q`. That matters in a split pane opened
only to read a file: without a pager the command ends the moment the last line
is written, and the pane closes with it.

Into a pipe there is no pager, so `preen NOTES.md | head` behaves. The output
keeps its color codes, which a terminal shows as color and a paste does not —
see the last bullet below.

### Scrolling, and the one thing it costs

The wheel scrolls the page, because preen adds `--mouse` when your `less`
knows it (551 and up). While `less` holds the mouse, though, it is `less`
receiving the clicks rather than the terminal — so **a plain drag no longer
selects text**.

Three ways around it:

- **In tmux, `prefix + [`.** This is the one to reach for. Copy mode moves and
  selects from the keyboard, the wheel scrolls the buffer, and — the part that
  matters in a split — it selects **within the pane**.
- **Hold the modifier your terminal uses to bypass mouse reporting**, then drag:
  shift in Ghostty and xterm, **option** in iTerm2. Be aware of what this
  really does. The modifier takes the mouse away from `less` *and* from tmux,
  so the **terminal** makes the selection, and a terminal knows nothing about
  panes. In a split you get a rectangle across the whole screen, with the
  neighboring pane's text spliced into every line. Fine in a single pane,
  usually wrong in a split.
- **Copy the file, not the render**, when what you want is the text rather
  than a read: `pbcopy < NOTES.md` puts the markdown on the clipboard. Piping
  the render instead does not work. Out of a terminal preen still writes the
  color codes, so `preen NOTES.md | pbcopy` pastes them as `[38;2;…m` noise,
  not as color, and `preen NOTES.md > out.txt` keeps them in the file, which
  only `less -R out.txt` shows the way it looked.

`less` keeps its own keys throughout: `/` to search, `g` and `G` for the ends,
`q` to quit.


**Any file is treated as markdown here**, whatever its extension. There is no
check: `preen foo.py` hands the file to glow and you get mangled markdown
rather than an error. To render a single **diff**, pipe it in instead — see
[Pipes](/docs/pipes).

## Side-by-side or inline

Diffs start **side-by-side**. Press `ctrl-s` to flip to inline, and `ctrl-s`
again to flip back. The preview repaints immediately; the toggle is live, so
you can switch mid-review on a file that is too wide for two columns.

To start in inline instead, for this repository or for every one:

```sh
git config preen.layout inline
git config --global preen.layout inline
```

Or for one run only: `PREEN_LAYOUT=inline preen diff`. See
[Theming](/docs/theming#starting-in-inline) for which one wins.

The toggle works in `diff`, `pr`, `log` files and `worktrees` modes. Markdown has one
layout, so `ctrl-s` does nothing in `md` mode.

How the toggle is wired — two named delta features — is explained in
[Theming](/docs/theming). It matters if you edit your own delta config, because
one common mistake silently breaks it.

## Keys

| key | action |
|---|---|
| `ctrl-s` | toggle side-by-side / inline (diff, pr, log and worktree files) |
| `enter` | open files from a commit or worktree list; otherwise open the full render in a pager |
| `ctrl-e` | open in `$EDITOR` at the first diff hunk (Markdown opens at the top) |
| `ctrl-n` | edit the current file's review note; save an empty buffer to clear it |
| `ctrl-v` | mark or unmark the current diff, PR, commit, or worktree file as viewed |
| `ctrl-l` | choose a relative Markdown link (md mode, fzf 0.45 or newer) |
| `ctrl-d` / `ctrl-u` | scroll the preview 8 lines |
| `pgdn` / `pgup` | scroll the preview half a page |
| `shift-down` / `shift-up` | scroll the preview one line |
| `home` / `end` | jump the preview to the top or bottom |
| `ctrl-/` | hide or show the preview |
| `esc` | return from links, worktree files, or commit files, or quit |
| `ctrl-c` | quit |

`preen watch` keeps these keys while refreshing the list and preview.

Typing filters the list, as in any fzf picker. The arrow keys move the cursor
and the list cycles at both ends.

### Open at the change

`ctrl-e` opens at the new-side start of the first diff hunk, including its
context lines. New files start at line 1. It uses the same comparison as the
preview: staged and unstaged changes together, a supplied revision, a
worktree's merge-base, a commit's first parent (empty tree for a root), or the
cached PR diff.

vi, vim, nvim, nano, emacs, emacsclient, micro and Helix (`hx` or `helix`)
receive `+LINE FILE`. VS Code (`code` or `code-insiders`) receives
`--goto FILE:LINE`; Zed receives `FILE:LINE`. `$EDITOR` can include options,
such as `code --wait`. Unknown editors open the file plainly. If a recognized
editor rejects the jump invocation, preen retries with just the file.

Markdown has no diff and opens plainly. Binary files and changes without a
hunk also open plainly. A deleted path keeps the plain editor invocation;
there is no existing file to jump into. In PR mode, this still opens your
checkout's copy of the path, using the line number from the PR; your local
copy may have different lines.

### `enter` versus the preview

The preview pane is a preview: it is 65% of the window. `enter` renders the same file at full terminal width into
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
- **File edits use your editor.** `ctrl-e` opens the checkout file in
  `$EDITOR`; `ctrl-n` opens a review note stored outside the checkout.

Next: [Pipes](/docs/pipes), or [Pull requests](/docs/pull-requests).
