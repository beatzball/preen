---
title: Theming
description: The roost palette, the glow style file, the delta keys, and PREEN_LAYOUT.
sidebar:
  order: 7
---

## One palette, two renderers

`glow` and `delta` know nothing about each other, and each has its own theme
format. preen ships the same palette for both so a markdown preview and a diff
preview look like one tool rather than two:

| color | where it is used |
|---|---|
| `#211e38` | background |
| `#c8c3e0` | body text |
| `#7c6ff0` | accent — borders, prompt, line numbers |
| `#bd93f9` | bright — headings, highlights, file names |
| `#8a84b0` | dim — hunk headers, quotes, headers |

The fzf picker itself is colored in the script, so it matches without any
config of yours.

## glow

The markdown style lives at:

```
~/.config/glow/roost.json
```

`install.sh` copies it there from `themes/glow-roost.json` in the checkout.

To use a different one, point `PREEN_GLOW_STYLE` at it:

```sh
PREEN_GLOW_STYLE=/path/to/style.json preen md
```

It is a glow style file, so anything glow accepts works. If the file preen is
told to use does not exist, it falls back to glow's built-in `dark` style
rather than failing.

To check a style against every markdown feature at once, render the kitchen
sink that ships in the repository:

```sh
preen demo/kitchen-sink.md
```

## delta

The diff style lives in the `[delta]` section of `~/.gitconfig`, written there
by `install.sh`. The syntax theme is `Dracula`; the rest is the palette above.

The full block is listed in [Git integration](/docs/git-integration). Edit it
like any git config:

```sh
git config --global delta.syntax-theme "Nord"
```

## The layout toggle, and the one way to break it

`ctrl-s` flips between side-by-side and inline. That works because the layout
is **not** set in the main `[delta]` section — it lives in two named features
that preen switches between:

```ini
[delta]
    features = sbs
[delta "sbs"]
    side-by-side = true
[delta "inline"]
    side-by-side = false
```

`preen` invokes `delta --features sbs` or `delta --features inline` and nothing
else changes.

**Keep `side-by-side` out of the main `[delta]` section.** Options set there
beat options set by a feature. Put it back and it wins over both features,
`ctrl-s` appears to do nothing, and there is no error to tell you why.

The installer moves that key for you if it finds it — see
[Git integration](/docs/git-integration).

## Starting in inline

To make one repository always start inline, run this inside it:

```sh
git config preen.layout inline
```

To make every repository start inline, set it globally:

```sh
git config --global preen.layout inline
```

preen asks git for the key, and git looks in the repository first, then in
your global file, then in the system file. So a repository's own value beats
the global one, and the global one still applies when you run preen outside
any repository.

For a single run, the environment variable beats both:

```sh
PREEN_LAYOUT=inline preen diff
PREEN_LAYOUT=sbs preen diff        # side-by-side, whatever git config says
git diff | PREEN_LAYOUT=inline preen
```

The order, first match wins:

1. `PREEN_LAYOUT`, if it is set and not empty
2. `git config preen.layout`
3. side-by-side

The layout applies to every mode, including the [piped path](/docs/pipes),
which has no `ctrl-s` to press. Only the exact word `inline` means inline. Any
other value — `INLINE`, a typo, `sbs` — means side-by-side, and preen does not
warn about it.

If git cannot read a config file, it is not the layout that stops you. Inside a
repository git refuses to run at all, so `diff`, `pr` and `worktrees` stop
before the picker opens. Outside a repository, and on piped input, preen starts
side-by-side and does not print git's error.

To undo it:

```sh
git config --unset preen.layout
git config --global --unset preen.layout
```

## Every environment variable

Read by `preen` itself:

| variable | effect |
|---|---|
| `PREEN_GLOW_STYLE` | path to a glow style file (default `~/.config/glow/roost.json`) |
| `PREEN_LAYOUT` | `inline` to start inline; any other non-empty value is side-by-side. When set and not empty it beats `git config preen.layout`; empty or unset falls through to it |
| `EDITOR` | what `ctrl-e` opens (default `vi`) |
| `TMPDIR` | where the scratch directory for a run is made (default `/tmp`) |

Read by `install.sh`:

| variable | effect |
|---|---|
| `PREEN_DIR` | where preen is cloned (same as `--dir`) |
| `PREEN_PREFIX` | where `preen` is linked (same as `--prefix`) |
| `PREEN_REPO_URL` | the repository to clone from |
| `NO_COLOR` | set it to get plain, uncolored installer output |
