---
title: Pipes
description: Pipe a diff or some markdown into preen and it renders it, paged.
sidebar:
  order: 3
---

## Pipe anything in

![git diff piped into preen, then a markdown file piped in](/preen-pipes.webp)

Give `preen` something on stdin and no file argument, and it renders it and
quits. No picker, no fzf.

```sh
git diff | preen           # delta renders it
gh pr diff 42 | preen      # so does a PR diff
cat NOTES.md | preen       # glow renders it
preen - < NOTES.md         # the same, said out loud
git diff | preen > out.txt # color is kept in the file too
```

A single `-` is the explicit form. It asks for the same behavior out loud,
which is what you want in a script where stdin might or might not be a pipe.

## How it picks a renderer

It sniffs the content. In the first 200 lines it looks for the headers a
unified diff always has:

- a `diff --git ` line, **or**
- an `@@ ... @@` hunk header, **or**
- a `--- ` line **and** a `+++ ` line

Any one of those means `delta`. Anything else means `glow`.

The `--- ` test needs `+++ ` alongside it because markdown uses `---` too — for
a horizontal rule, and for the top of a frontmatter block. On its own it would
send half your notes to delta.

**The sniff strips ANSI escapes first.** `git diff --color=always` paints its
own header lines, so without that step `^--- ` would never match and a colored
diff would be read as markdown. This works:

```sh
git diff --color=always | preen
```

## Terminal or pipe

`preen` looks at where its own output is going:

- **To a terminal** — the result is paged through `less -R`. Scroll, search
  with `/`, quit with `q`.
- **To a pipe or a file** — the bytes are written plain, color and all.

That second case is deliberate. `git diff | preen > out.txt` keeps the color
in the file, so `less -R out.txt` later looks the same as it did live. So does
`git diff | preen | head -40`.

## Layout

`PREEN_LAYOUT=inline` applies here too:

```sh
PREEN_LAYOUT=inline git diff | preen
```

There is no `ctrl-s` on this path — there is no picker to press it in — so the
environment variable is the only way to choose.

## What it needs

Only the renderer it actually reaches for. A piped diff needs `delta` and does
not touch `glow`; piped markdown needs `glow` 3 or newer and does not touch
`delta`. Neither needs `fzf`, and neither needs to be in a git repository.

If stdin is empty, preen says `nothing on stdin` and exits rather than opening
an empty pager.

## Where this is already wired up for you

The `preen` difftool in your git config is built on exactly this: it makes a
plain unified diff and pipes it into `preen -`. See
[Git integration](/docs/git-integration).
