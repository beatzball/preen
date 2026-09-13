# tests

```sh
tests/run.sh            # everything
tests/run.sh worktrees  # only files whose name contains "worktrees"
```

Plain bash, no framework. Needs `git`, `delta`, `fzf` and `python3`. It does
**not** need `glow` — nothing here asserts on glow's output, so `lib.sh` stubs
the version check preen makes at startup and CI never installs it.

`python3` is for two things. `with_tty` allocates a pty so the tests can reach
the code preen runs on a terminal — `pager()` branches on `[ -t 1 ]`, and a test
harness only ever offers a pipe, so there is no other way in. `list_has` and its
neighbours read the file list, which is NUL-delimited and holds a name with a
newline in it: the pair of bytes no line-oriented tool can handle at once.

Every test builds a throwaway repository under `$TMPDIR` and removes it on
exit. Nothing touches the checkout it runs from, which matters more than usual
here: half of what preen does is read the repository it is standing in.

## How preen is driven without a terminal

preen's picker is `fzf`, which cannot be driven headlessly. Four seams get at
everything that matters without it:

- **The file list.** `preen_list` puts a fake `fzf` first on `PATH` that writes
  its stdin out and exits. What that captures is exactly the list the real
  picker would have been handed.
- **The previews.** `preview` calls `preen --preview`, which is the same
  callback fzf itself invokes, with the same `$PREEN_STATE` contract.
- **The flags and the second level.** The same shim records the arguments preen
  passed, because how fzf is told to read the list is half of whether an odd
  name survives it, and no assertion about the bytes can see a flag.
  `preen_list_raw2` accepts the first record instead of exiting, which is what
  drives worktrees mode into its file list — the level nothing else reaches.
- **What preen says before the picker.** A stand-in `fzf` that reads its stdin
  and exits, so preen can be run all the way through and graded on its stderr
  and its exit. That is the only way to reach the messages preen prints instead
  of a list, and it is what keeps a run that should die from opening a real
  picker and hanging the suite.

None of them is a workaround: all four are the real entry points, and the list
is taken from preen rather than rebuilt here. A test that reimplemented the git
commands would grade its own copy and keep passing after `bin/preen` changed
underneath it.

`$PREEN` is always the binary in this checkout, never whatever is on the
developer's `PATH` — a suite that silently graded the installed copy would be
green for the wrong reason.

## What each file covers

| file | covers |
|---|---|
| `test-harness.sh` | the harness itself: with an unusable `TMPDIR` the suite must delete nothing in the checkout, commit nothing to its branch, and fail loudly |
| `test-diff-list.sh` | the list from the root and from a subdirectory, a revision argument, a repo with no commit, staged and unstaged together |
| `test-worktrees.sh` | the count agrees with the level-one preview, merge-base rather than the branch tip, the main checkout is excluded, read-only, the pre-2.36 fallback, and the two kinds of worktree it has to drop — one git cannot spell and one that was deleted without a prune — each with the reason it is allowed to give |
| `test-stdin.sh` | the diff/markdown sniff, including `---` alone staying markdown and a `--color=always` diff still reading as a diff |
| `test-filenames.sh` | accented names, spaces, a leading dash, and the quote, backslash, tab and newline cases from #3 — in diff, md, pr and both levels of worktrees, plus a tab in a worktree's own directory name, a dash-leading directory in md mode, a PR file named ` b/x.md`, the `--read0` fzf is given and the `ctrl-e` binding a worktree path is spent through |
| `test-pr.sh` | four `gh` calls whatever the file count, previews slice the cache, read-only |
| `test-file.sh` | `preen FILE.md` and the picker's enter key: paged on a terminal, plain into a pipe, the glow gate, no less installed |

## Fourteen bugs these exist to hold shut

Each was found by review, fixed, and is now covered. Reverting any one of the
fixes turns this suite red:

- **`preen diff` from a subdirectory** mixed repo-root-relative tracked paths
  with cwd-relative untracked ones, so previews outside the current directory
  came back blank.
- **A worktree's count and its preview disagreed** — untracked files were
  counted but not shown, so a worktree could say "2 files" and show one.
- **Non-ASCII filenames** came back escaped, listed but unopenable.
- **A quote, a backslash or a newline in a filename** came back escaped too,
  whatever `core.quotePath` said, and a newline also split one name into two
  entries. Every list is now built with `-z` and read on NUL, and fzf is given
  `--read0` so it frames them the same way.
- **`pr` mode previewed an odd name as blank.** git C-quotes the whole path in
  a `diff --git` header — which is how every accented name arrives from the
  API — and the slice matched a bare `" b/NAME"` tail, which never matches
  that. It decodes the header now.
- **`ctrl-e` in a worktree pasted the worktree's own path into a shell
  command**, so a path holding a quote opened the wrong file and one holding
  `$(...)` ran it. The path goes through the environment now.
- **`preen FILE.md` was not paged**, so it exited the moment the last line was
  written. A tmux pane opened only to read the file closed with it, which read
  as glow never having run.
- **A tab in a worktree's directory name split its record in the wrong place.**
  The record was `label <tab> path` and the label already ended with that path,
  so the callbacks were handed the tail of the label. The pane counted the files
  and then said the branch had changed nothing. The two fields are joined on US
  (0x1f) now. A path can technically hold one, and such a path still splits
  wrong; no byte is safe from that, and 0x1f is the one no real name uses.
- **On git older than 2.36 a newline in a worktree's directory name listed a
  worktree that was not there.** The fallback prints each path on its own line,
  so the path arrived cut short — not a missing entry but a plausible wrong one.
  That entry is dropped now, and the picker's header says one went.
- **A worktree deleted without a prune was blamed on the git version.** The
  check above first asked only "is the path a directory", which is also false
  for a worktree someone `rm -rf`'d and did not `git worktree prune` — on every
  git. preen then told them a newline needed git 2.36, on a git that had `-z`
  and a name with no newline in it, and exited 1 if that was the only worktree.
  Only the fallback can cut a path short, so only the fallback names the git
  version now; everywhere else the advice is to prune — worded as a condition,
  because a worktree locked on a disk that is not mounted is also "not there"
  and prune will not touch it.
- **The fallback listed a worktree's parent as a worktree** when the newline
  started the last path component, because the cut path was then a real
  directory. A worktree carries a `.git` entry and a bare parent does not, and
  that is what the fallback asks. A cut path can land on a real *worktree* too —
  the outer one when they nest, `wts/a` when the other is `wts/a<newline>b`, the
  main checkout when the worktree sits directly inside it — and `.git` passes
  every one of those. Each is a shape git cannot print: a trailing slash, the
  root, or a path already listed.
- **The suite deleted the checkout's own `tests/` directory**, and on another
  occasion committed the working tree to the live branch. Both came from a
  `$TMPDIR` that no longer existed: `mktemp` fails silently, the variable is
  empty, and `rm -rf "$(cd "" && pwd -P)"` resolves to the suite's own cwd while
  `git -C ""` acts on the repository it is testing. Nothing in `tests/` calls
  `mktemp` directly any more — `mktmpd`, `mktmpf` and `resolve_dir` in `lib.sh`
  fail loudly instead — and `test-harness.sh` holds it shut.
- **`preen md` on a dash-leading directory found nothing.** `find -weird` read
  the name as options. The root gets a `./`, and the names keep it, because
  glow and `$EDITOR` would read the name as options in turn.
- **`pr` mode previewed two files stitched together** for a file named
  ` b/x.md`, whose header's last seven bytes are ` b/x.md` and so matched the
  tail slice for `x.md`. An unquoted `a/P b/P` is solved rather than tail-
  matched now; a rename, whose paths differ, still falls back to the tail.

## Writing a new one

Copy the shape of an existing file: `set -u`, source `lib.sh`, build a fixture,
assert, clean up in a `trap`. Assertions are `assert_eq`, `assert_contains`,
`assert_not_contains`, `assert_true` and `assert_nonempty`, and each prints one
`PASS:` or `FAIL:` line that `run.sh` counts.

Two things worth knowing:

- **Prove a new test fails on the bug it names.** Revert the fix, watch it go
  red, put the fix back. A test that has never failed is not evidence. Watch
  what it goes red *for*, too: a loop over a list can pass by never running,
  and a fixture can miss the code path it was written for.
- **`run.sh` fails the run if a file exits non-zero**, even when every line it
  printed was a `PASS` — a syntax error or an early `set -e` abort otherwise
  just contributes fewer PASS lines and no FAIL lines, and the totals would
  under-report. It also fails when no test ran at all.
