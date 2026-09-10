# preen

Markdown and diffs in the terminal, without opening an editor.

Birds preen to tidy their feathers. You preen your diff before you commit.

![preen picking a git worktree, then browsing what it changed](demo/preen.gif)

Markdown mode, same keys:

![preen rendering markdown files from a picker](demo/preen-md.png)

Thin glue over three tools that already do the hard part:

| job | tool |
|---|---|
| render markdown | `glow` (3.0 or newer) |
| render diffs | `delta` |
| file navigation | `fzf` |

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/beatzball/preen/main/install.sh | bash
```

That clones preen to `~/.local/share/preen` and links `preen` into
`~/.local/bin`. Or clone it first and run the installer out of the checkout:

```sh
gh repo clone beatzball/preen && ./preen/install.sh
```

The installer is safe to run again. It:

0. clones the repo if it is not already running from a checkout,
1. installs `glow`, `delta` and `fzf` if they are missing,
2. copies `themes/glow-roost.json` to `~/.config/glow/roost.json`,
3. writes the delta theme into `~/.gitconfig` (backed up first, once),
4. registers the `git preen` alias and the `preen` difftool,
5. links `bin/preen` into `~/.local/bin`,
6. tells you if that directory is not on your PATH.

### Options

| flag | effect |
|---|---|
| `--dry-run` | print every step, change nothing |
| `--no-deps` | config only, install no packages |
| `--user` | always fetch tools into `~/.local/bin`, never use sudo |
| `--dir DIR` | clone preen somewhere else (default `~/.local/share/preen`) |
| `--prefix DIR` | link `preen` somewhere else |
| `--uninstall` | undo the theme, the git alias, the difftool, the link and the config |

### Platforms

macOS and Linux. It uses whichever of `brew`, `apt-get`, `dnf`, `pacman`,
`zypper` or `apk` it finds. If the package manager has no package for a tool,
it falls back to that tool's official GitHub release tarball and drops the
binary in `~/.local/bin`. No sudo is needed for the fallback path.

`--uninstall` removes every `delta.*` theme key plus `alias.preen`, `diff.tool`,
`difftool.preen.cmd` and `difftool.prompt`. It keeps `core.pager`,
`interactive.diffFilter`, `delta.navigate` and `delta.dark`, because those are a
plain delta setup rather than this theme. It never removes packages.

## Use

```sh
preen                 # auto: diffs in a git repo, else markdown
preen md [DIR]        # browse markdown files under DIR (default .)
preen diff [REV]      # browse files changed vs REV (default: working tree)
preen pr [NUMBER]     # browse the files in a GitHub PR (default: this branch)
preen worktrees       # pick a git worktree, then browse what it changed
preen wt              # short for the same
preen FILE.md         # render one file, paged, and quit
preen --help
```

### Pull requests

```sh
preen pr 42           # review PR 42
preen pr              # the PR opened from the current branch
```

Same picker as `preen diff`: file list on the left, delta diff on the right,
`ctrl-s` to flip layout, `enter` for the full file in a pager.

It needs the [`gh`](https://cli.github.com) CLI and a logged-in account
(`gh auth login`). It is **read-only**: the diff comes over the API, so there is
no checkout, no fetch, no branch switch and no stash. Your working tree is left
exactly as it was.

`gh pr diff` is called once for the whole PR and cached for the life of the
run. Each preview slices its own file out of that cache, so a 90-file PR still
costs one network call, not ninety.

### Worktrees

```sh
preen worktrees       # or: preen wt
```

Agents work in git worktrees, and when one finishes the question is always
"what did it actually change?". This mode answers it in two levels.

First a picker of every worktree except the main checkout, one line each:

```
   1 file   worktree-cutoff           .claude/worktrees/cutoff
   5 files  worktree-read-render      .claude/worktrees/read-render
   6 files  worktree-rewire           .claude/worktrees/rewire
```

The preview shows the branch, the base it is measured against, the commits
made on it, and the whole diff. Pick one and the normal file picker opens on
that worktree: file list on the left, delta diff on the right, `ctrl-s` to flip
layout, `enter` for the full file in a pager. `esc` goes back to the worktree
list; `ctrl-c` quits.

The count is files changed against the **merge-base** with the default branch,
not against its tip, so commits landed on the default branch since the worktree
branched do not show up. The default branch is read from `origin/HEAD`, falling
back to `main` and then `master`. Uncommitted and untracked files are counted
and browsable too.

Like `pr` mode it is **read-only**: it runs `git worktree list`, `merge-base`,
`log`, `diff` and `ls-files` and nothing else. No checkout, no fetch, no stash,
no commit, in any worktree.

A repo with no worktrees besides the main checkout says so and exits.

### Pipes

With something on stdin and no file argument, `preen` renders it and quits. No
picker, no fzf. A single `-` asks for the same thing out loud.

```sh
git diff | preen           # delta renders it
gh pr diff 42 | preen      # so does a PR diff
cat NOTES.md | preen       # glow renders it
preen - < NOTES.md         # the same, said out loud
git diff | preen > out.txt # color is kept in the file too
```

It picks the renderer by sniffing the content: `diff --git`, `--- ` / `+++ ` or
`@@ ` headers mean `delta`, anything else means `glow`. The sniff strips ANSI
escapes first, so `git diff --color=always | preen` is still read as a diff.

On a terminal the output is paged through `less -R`. Into a pipe or a file it
is written plain, color and all. `PREEN_LAYOUT=inline` applies here too.

### Git integration

`install.sh` adds two entry points to your global git config:

```sh
git preen                  # same as: preen diff
git difftool -t preen      # render one file's diff at a time
git difftool               # the same; preen is the default diff.tool
```

`git preen` is a `!` alias, so it runs `preen diff` from the repo root. The
difftool builds a plain unified diff and pipes it into `preen -`, which sends it
to delta and pages it. `difftool.prompt` is set to `false` so git does not ask
before each file.

### Keys

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

## Theming

Both renderers use the roost palette (`#7c6ff0` purple, `#c8c3e0` text, `#8a84b0` dim).

- **glow**: `~/.config/glow/roost.json`. Override with `PREEN_GLOW_STYLE=/path/to/style.json`.
- **delta**: the `[delta]` section of `~/.gitconfig`, syntax theme `Dracula`.
- Start in inline layout with `PREEN_LAYOUT=inline preen diff`. This is the only
  way to do it today. A per-repo `git config preen.layout inline` is a planned
  follow-up and is **not implemented yet**, so setting that key does nothing.

The diff layout lives in two named delta features so `preen` can flip between them:

```ini
[delta]
    features = sbs
[delta "sbs"]
    side-by-side = true
[delta "inline"]
    side-by-side = false
```

Keep `side-by-side` out of the main `[delta]` section. Options there beat feature options, and the toggle stops working.

## Tests

```sh
tests/run.sh            # everything
tests/run.sh worktrees  # one area
```

Plain bash, no framework. Needs `git`, `delta`, `fzf` and `python3`. Every test
builds a throwaway repository under `$TMPDIR`, so nothing touches the checkout
you run it from. `tests/README.md` explains how preen is driven without a
terminal, and why reaching that code needs a pty.

## Rebuilding the recordings

```sh
brew install vhs
./demo/seed-repo.sh /tmp/preen-demo-repo
vhs demo/preen.tape
vhs demo/preen-pipes.tape
vhs demo/preen-pr.tape
vhs demo/preen-md.tape
```

One tape per thing worth watching, so none of them runs long enough to lose you:

| tape | writes | shows |
|---|---|---|
| `demo/preen.tape` | `demo/preen.gif` | `preen worktrees`: pick a worktree, open its files, `ctrl-s`, `esc` back |
| `demo/preen-pipes.tape` | `demo/preen-pipes.gif` | `git diff \| preen`, then `cat docs/api.md \| preen` |
| `demo/preen-pr.tape` | `demo/preen-pr.gif` | `preen pr 673` against a real public PR |
| `demo/preen-md.tape` | `demo/preen-md.png` | the markdown picker |

`seed-repo.sh` builds the whole stage in one directory: a dirty working tree, three
git worktrees under `.worktrees/` with real commits on them, and a `.pr/` sandbox
whose only content is a remote for PR numbers to resolve against. `.worktrees/`
and `.pr/` are git-ignored, so they stay out of `preen diff`.

`preen-pr.tape` needs `gh` and a logged-in account. It reads
[charmbracelet/vhs#673](https://github.com/charmbracelet/vhs/pull/673) over the
API and checks nothing out.

Two things to keep in mind when editing a tape. Every `cd` and every `export`
belongs between `Hide` and `Show`, so no real path reaches a frame. And
`Screenshot` wants a path relative to the repo root plus a `Sleep` after it, or
vhs writes nothing at all.

`preen-pipes.tape` records a narrower frame than the rest on purpose: piped
output is rendered 80 columns wide, so a wider one would only be empty on the
right.

## Notes

- **glow 3.0 or newer is required.** glow 2 throws away all color when its
  output is not a terminal, and fzf hands previews a pipe, so every preview came
  out gray. Wrapping glow in a pseudo-tty (`script`) fixed it under tmux but hung
  forever inside fzf elsewhere. glow 3 keeps its color in a pipe, so `preen`
  calls it directly and `install.sh` upgrades anything older.
- Preview scrolling jumps; it is not animated. fzf has no timer or delay action,
  so a `--bind` chain of `preview-down` steps still paints one frame. Smooth
  scrolling would need an app that redraws on its own tick, the way
  `snacks.nvim` does it in Neovim.
- Inline images do not work. tmux swallows the kitty graphics escapes and dumps
  the payload into the pane title. `mdcat` was tested and dropped for this reason.
- **An odd filename is listed and opened as itself.** A quote, a backslash, a
  tab or a newline in a name is escaped by git on output whatever
  `core.quotePath` says, and a name that comes back escaped is listed but
  cannot then be opened. So every file list is asked for with `-z` and handed
  to fzf with `--read0`, and `pr` mode decodes the C-quoted path git writes
  into a `diff --git` header — which is how an accented name arrives from the
  GitHub API. The one name `pr` mode still cannot spell is one containing a
  **newline**: its list comes from `gh pr diff --name-only`, which has no NUL
  form and separates its output with a newline. Every other mode carries that
  too.
- **fzf 0.53 or newer draws a name containing a newline on more than one line.**
  `--read0` itself has been in fzf since 0.15, so an older fzf still treats such
  a name as one entry and still opens it; it just draws it on a single line.
- `demo/kitchen-sink.md` exercises every markdown feature. Use it to check a theme:
  `preen demo/kitchen-sink.md`.

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) covers what to run before a pull request,
where documentation goes, and what the `P0`-`P3` labels mean.

## License

MIT. See [LICENSE](LICENSE).
