---
title: Git Integration
description: git preen and git difftool -t preen, and what the installer writes to your gitconfig.
sidebar:
  order: 6
---

## Two entry points from git

`install.sh` adds two ways to reach preen from `git` itself:

```sh
git preen                  # same as: preen diff
git difftool -t preen      # render one file's diff at a time
git difftool               # the same; preen is the default diff.tool
```

## `git preen`

An alias for [`preen diff`](/docs/browsing) — the file picker over everything
you have not committed.

It is a `!` alias, which means git runs it as a shell command instead of
looking for a `git-preen` binary on your `PATH`. A side effect worth knowing:
git runs a `!` alias **from the repository root**, so `git preen` shows the
whole repository no matter which subdirectory you happen to be standing in.

That is usually what you want, and `preen diff` does the same thing: it runs
`git diff` without a path limit, so it also lists the whole repository
whichever directory you start it in.

**Both are unreliable from a subdirectory today.** Tracked paths come back
relative to the repository root while untracked ones come back relative to
where you are standing, so the two halves of the list disagree and a preview
of a file outside your directory renders empty. Run either from the repository
root until that is fixed.

## `git difftool`

`git difftool` walks the changed files one at a time and hands each pair to the
tool you name. With preen registered, each one is rendered by delta and paged.

The command it runs per file is:

```sh
diff -u "$LOCAL" "$REMOTE" | preen -
```

Plain `diff -u` builds a unified diff, and `preen -` reads it from stdin,
recognizes it as a diff, sends it to delta and pages it. It is the
[pipe path](/docs/pipes) with nothing extra bolted on.

`difftool.prompt` is set to `false`, so git does not stop and ask
`Launch 'preen' [Y/n]?` before every single file.

`preen` is also set as `diff.tool`, so bare `git difftool` uses it without the
`-t`.

### `git preen` or `git difftool`?

- **`git preen`** — jump around. A file list you can search, with the diff
  beside it. This is the one to reach for.
- **`git difftool`** — go through in order, one file per pager, `q` for the
  next. Better when you want to be sure you looked at every file exactly once.

## What the installer writes

Everything goes into your **global** git config, `~/.gitconfig`. Nothing is
written per repository.

Before the first write, `install.sh` copies `~/.gitconfig` to
`~/.gitconfig.preen.bak` — **once**. A later re-run will not overwrite that
backup with an already-modified file.

### The two entry points

```ini
[core]
    pager = delta
[interactive]
    diffFilter = delta --color-only
[alias]
    preen = !preen diff
[diff]
    tool = preen
[difftool]
    prompt = false
[difftool "preen"]
    cmd = diff -u "$LOCAL" "$REMOTE" | preen -
```

Those first two are worth reading twice: **they change `git diff` and
`git add -p` for every repository on the machine**, not just when you run
preen. They are also the two `--uninstall` deliberately keeps — see below.

### The delta theme

The rest is the color scheme and the layout features, described in
[Theming](/docs/theming):

```ini
[delta]
    features = sbs
    navigate = true
    dark = true
    true-color = always
    syntax-theme = Dracula
    line-numbers = true
    file-style = "#bd93f9 bold"
    file-decoration-style = "#7c6ff0 ul"
    hunk-header-style = "#8a84b0"
    hunk-header-decoration-style = "#7c6ff0 box"
    line-numbers-left-style = "#7c6ff0"
    line-numbers-right-style = "#7c6ff0"
    line-numbers-zero-style = "#8a84b0"
    plus-style = "syntax #1e3326"
    minus-style = "syntax #3a1e28"
    plus-emph-style = "syntax #2d5a3d"
    minus-emph-style = "syntax #5c2d3a"
    zero-style = syntax
[delta "sbs"]
    side-by-side = true
[delta "inline"]
    side-by-side = false
```

### One key it moves

If you already have `delta.side-by-side` set in the main `[delta]` section, the
installer **unsets it** and puts the setting into the `sbs` feature instead.

That is not tidying. Options in the main `[delta]` section beat options set by a
feature, so a stray `side-by-side` there wins over both features and `ctrl-s`
stops doing anything at all. See [Theming](/docs/theming).

## Preview it, or undo it

```sh
./install.sh --dry-run     # print every step, change nothing
./install.sh --no-deps     # config only, install no packages
./install.sh --uninstall   # take the git config back out
```

`--uninstall` removes the `delta.*` **theme** keys, plus `alias.preen`,
`diff.tool`, `difftool.preen.cmd` and `difftool.prompt`. It also deletes
`~/.config/glow/roost.json` and the `preen` link in your prefix.

It **keeps** four keys, and `delta.navigate` and `delta.dark` are `delta.*`
keys among them, so "every `delta.*` key" would be wrong:

| kept | why |
|---|---|
| `core.pager` | a plain delta setup that works without preen |
| `interactive.diffFilter` | the same |
| `delta.navigate` | the same |
| `delta.dark` | the same |

It never removes packages, and it leaves `~/.gitconfig.preen.bak` in place —
that is your pre-preen config, so delete it yourself once you are sure.
