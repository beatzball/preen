# tests

```sh
tests/run.sh            # everything
tests/run.sh worktrees  # only files whose name contains "worktrees"
```

Plain bash, no framework. Needs `git`, `delta` and `fzf`. It does **not** need
`glow` — nothing here asserts on glow's output, so `lib.sh` stubs the version
check preen makes at startup and CI never installs it.

Every test builds a throwaway repository under `$TMPDIR` and removes it on
exit. Nothing touches the checkout it runs from, which matters more than usual
here: half of what preen does is read the repository it is standing in.

## How preen is driven without a terminal

preen's picker is `fzf`, which cannot be driven headlessly. Two seams get at
everything that matters without it:

- **The file list.** `preen_list` puts a fake `fzf` first on `PATH` that writes
  its stdin out and exits. What that captures is exactly the list the real
  picker would have been handed.
- **The previews.** `preview` calls `preen --preview`, which is the same
  callback fzf itself invokes, with the same `$PREEN_STATE` contract.

Neither is a workaround: both are the real entry points, and the list is taken
from preen rather than rebuilt here. A test that reimplemented the git commands
would grade its own copy and keep passing after `bin/preen` changed underneath
it.

`$PREEN` is always the binary in this checkout, never whatever is on the
developer's `PATH` — a suite that silently graded the installed copy would be
green for the wrong reason.

## What each file covers

| file | covers |
|---|---|
| `test-diff-list.sh` | the list from the root and from a subdirectory, a revision argument, a repo with no commit, staged and unstaged together |
| `test-worktrees.sh` | the count agrees with the level-one preview, merge-base rather than the branch tip, the main checkout is excluded, read-only |
| `test-stdin.sh` | the diff/markdown sniff, including `---` alone staying markdown and a `--color=always` diff still reading as a diff |
| `test-filenames.sh` | accented names, spaces, a leading dash, and the quote case from #3 as a known limit |
| `test-pr.sh` | four `gh` calls whatever the file count, previews slice the cache, read-only |

## Three bugs these exist to hold shut

Each was found by review, fixed, and is now covered. Reverting any one of the
fixes turns this suite red:

- **`preen diff` from a subdirectory** mixed repo-root-relative tracked paths
  with cwd-relative untracked ones, so previews outside the current directory
  came back blank.
- **A worktree's count and its preview disagreed** — untracked files were
  counted but not shown, so a worktree could say "2 files" and show one.
- **Non-ASCII filenames** came back escaped, listed but unopenable.

## Writing a new one

Copy the shape of an existing file: `set -u`, source `lib.sh`, build a fixture,
assert, clean up in a `trap`. Assertions are `assert_eq`, `assert_contains`,
`assert_not_contains`, `assert_true` and `assert_nonempty`, and each prints one
`PASS:` or `FAIL:` line that `run.sh` counts.

Two things worth knowing:

- **Prove a new test fails on the bug it names.** Revert the fix, watch it go
  red, put the fix back. A test that has never failed is not evidence.
- **`run.sh` fails the run if a file exits non-zero**, even when every line it
  printed was a `PASS` — a syntax error or an early `set -e` abort otherwise
  just contributes fewer PASS lines and no FAIL lines, and the totals would
  under-report. It also fails when no test ran at all.
