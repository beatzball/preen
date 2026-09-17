# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/).

## [0.1.0]

The first numbered version. It does not try to describe everything preen does;
the README does that. It records the work that landed before versioning began:
mostly names and paths that preen listed wrong or could not open, and the CI
that now runs on the platform preen is most used on.

### Added

- **CI runs the test suite on macOS as well as Linux** (#23, PR #26). macOS
  ships bash 3.2 and BSD `sort`, `find` and `awk`, and the file lists are built
  from exactly the constructs where those disagree with bash 5 and GNU. The
  macOS job is pinned to the system bash, so a newer one on the runner cannot
  quietly take the 3.2 coverage away. Tried against 16 constructs that break on
  3.2 or BSD, the macOS job failed on all 16 and the Linux job on none.
- **CI runs `site/sync-assets.sh` instead of only parsing it** (#27, PR #29). A
  `--dry-run` resolves every source and destination without encoding anything,
  and the workflow compares the destinations with the five images the site
  actually reads. A renamed tape or a mistyped output name now fails CI; before,
  it shipped green and left the old image in place. A third runner OS added to
  the matrix now stops with a message naming it, not deep inside the suite.
- **Every GitHub Action is pinned to a commit** (#28, PR #29), with its version
  in a comment and Dependabot keeping both current. A tag can be moved to other
  code; a commit cannot. The workflow also states `permissions: contents: read`
  instead of inheriting the repository default, which took away a
  `packages: read` nothing used.

### Fixed

- **A filename with a quote, a backslash or a newline is listed and opens**
  (#3, PR #19). git escapes those bytes whatever `core.quotePath` says, so the
  name was listed in a spelling nothing could open, and the preview was blank.
  A newline was worse: it also split one file into two entries, so a
  worktree's count was too high. Every list is now read on NUL, the one byte a
  filename cannot hold, and fzf is told to read it that way.
- **`pr` mode previews an accented or odd name** (PR #19). git quotes the whole
  path in a `diff --git` header when the name holds a quote, a backslash, a
  control character or any byte above ASCII, so every accented name arrived
  quoted and the preview matched nothing. preen decodes the header now.
- **A tab in a worktree's directory name no longer breaks worktrees mode** (#24,
  PR #31). The record joined its label and its path with a tab, and the label
  already ended with the path, so the split landed in the wrong place. The pane
  counted two files, showed a blank preview, and then said the branch had
  changed nothing. The two fields are joined on a byte no real name uses.
- **A worktree preen cannot open is explained honestly** (#25, PR #31). A
  worktree deleted by hand without `git worktree prune` was blamed on git
  being older than 2.36, on any git, and preen exited 1 if it was the only one.
  Now the advice is to prune if it is gone for good, and git's version is named
  only when git really is too old. On that older git, a newline in a worktree's
  name used to list a plausible worktree that did not exist; that entry is
  dropped now, and the picker's header says one went.
- **`preen md` on a directory whose name starts with a dash finds its files**
  (#22, PR #31). `find` read the name as options.
- **`pr` mode no longer previews two files stitched together** (#22, PR #31). A
  PR holding `x.md` and a file named ` b/x.md` matched both when previewing
  `x.md`. The header is now split exactly instead of matched on its tail.
- **The mouse wheel scrolls a rendered file** (#36, PR #37). `preen FILE.md` and
  piped input page through `less`, which was never asked for the mouse, so
  under tmux the wheel did nothing while every picker mode scrolled. `less` is
  given `--mouse` when it supports it. The cost: a plain drag now selects inside
  `less`, so copying a line wants tmux copy mode or a modifier key, and the docs
  now say so (PR #39).
- **A narrow pane no longer folds a render twice** (PR #41). preen asked `tput`
  for the width in a way that often answered 80 whatever the pane was, so in a
  66-column pane a piped render was 80 wide and `less` wrapped every line again,
  mid-word. preen now asks the terminal itself. `COLUMNS` still wins, and 80 is
  still the answer when there is no terminal at all.
- **The site stopped serving its build manifest** (#7, PR #30). `/nitro.json`
  was public with a week-long cache, for a file that changes on every deploy and
  that nothing reads. It is left out of the image now.
- **An image the site cannot size fails the build** (#5, PR #30). The site reads
  sizes from PNG and WebP headers only. Anything else reserved no space on the
  page, so the layout shifted as it loaded, and nothing said so. The build now
  stops and names every such image. Converting it to WebP, or writing the tag
  with both `width` and `height`, is the way out.

### Known limits

- **`pr` mode cannot list a filename that contains a newline.** `gh pr diff
  --name-only` separates its output with newlines and has no NUL form, so such a
  name cannot be told apart from two. Every other odd name lists and opens in
  `pr` mode.
