# preen

Markdown and diffs in the terminal, without opening an editor.

Birds preen to tidy their feathers. You preen your diff before you commit.

Thin glue over three tools that already do the hard part:

| job | tool |
|---|---|
| render markdown | `glow` |
| render diffs | `delta` |
| file navigation | `fzf` |

## Install

```sh
git clone <this repo> preen && cd preen && ./install.sh
```

The installer is safe to run again. It:

1. installs `glow`, `delta` and `fzf` if they are missing,
2. copies `themes/glow-roost.json` to `~/.config/glow/roost.json`,
3. writes the delta theme into `~/.gitconfig` (backed up first, once),
4. links `bin/preen` into `~/.local/bin`,
5. tells you if that directory is not on your PATH.

### Options

| flag | effect |
|---|---|
| `--dry-run` | print every step, change nothing |
| `--no-deps` | config only, install no packages |
| `--user` | always fetch tools into `~/.local/bin`, never use sudo |
| `--prefix DIR` | link `preen` somewhere else |
| `--uninstall` | undo the theme, the link and the config |

### Platforms

macOS and Linux. It uses whichever of `brew`, `apt-get`, `dnf`, `pacman`,
`zypper` or `apk` it finds. If the package manager has no package for a tool,
it falls back to that tool's official GitHub release tarball and drops the
binary in `~/.local/bin`. No sudo is needed for the fallback path.

`--uninstall` keeps `core.pager`, `interactive.diffFilter`, `delta.navigate`
and `delta.dark`, because those are a plain delta setup rather than this theme.
It never removes packages.

## Use

```sh
preen                 # auto: diffs in a git repo, else markdown
preen md [DIR]        # browse markdown files under DIR (default .)
preen diff [REV]      # browse files changed vs REV (default: working tree)
preen FILE.md         # render one file and quit
preen --help
```

### Keys

| key | action |
|---|---|
| `ctrl-s` | toggle side-by-side / inline (diff mode) |
| `enter` | open the full render in a pager |
| `ctrl-e` | open in `$EDITOR` |
| `ctrl-d` / `ctrl-u` | scroll the preview 8 lines |
| `pgdn` / `pgup` | scroll the preview half a page |
| `shift-down` / `shift-up` | scroll the preview one line |
| `home` / `end` | jump the preview to the top or bottom |
| `ctrl-/` | hide or show the preview |
| `esc` | quit |

## Theming

Both renderers use the roost palette (`#7c6ff0` purple, `#c8c3e0` text, `#8a84b0` dim).

- **glow**: `~/.config/glow/roost.json`. Override with `PREEN_GLOW_STYLE=/path/to/style.json`.
- **delta**: the `[delta]` section of `~/.gitconfig`, syntax theme `Dracula`.
- Start in inline layout with `PREEN_LAYOUT=inline preen diff`.

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

## Notes

- `glow` prints no colour when its output is not a terminal, and fzf hands
  previews a pipe. `preen` runs glow under a pseudo-tty (`script`) to keep the
  colours, then strips the stray CRs. Without that the preview is grey.
- Preview scrolling jumps; it is not animated. fzf has no timer or delay action,
  so a `--bind` chain of `preview-down` steps still paints one frame. Smooth
  scrolling would need an app that redraws on its own tick, the way
  `snacks.nvim` does it in Neovim.
- Inline images do not work. tmux swallows the kitty graphics escapes and dumps
  the payload into the pane title. `mdcat` was tested and dropped for this reason.
- `demo/kitchen-sink.md` exercises every markdown feature. Use it to check a theme:
  `preen demo/kitchen-sink.md`.
