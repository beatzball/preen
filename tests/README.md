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
harness only ever offers a pipe, so there is no other way in. A fresh pty has no
size, so a test about width sets `PREEN_TTY_COLS` and gets a terminal that many
columns wide. `list_has` and its
neighbors read the file list, which is NUL-delimited and holds a name with a
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
| `test-harness.sh` | the harness itself: the shapes that caused the damage are forbidden at the source in any spelling, the guards are called directly, and every path to `mktemp` that a clean run of each file takes is failed in turn while the checkout is watched; a call that skips the helpers fails the run. The slow half of the suite — see below |
| `test-diff-list.sh` | the list from the root and from a subdirectory, a revision argument, a repo with no commit, staged and unstaged together |
| `test-worktrees.sh` | the count agrees with the level-one preview, merge-base rather than the branch tip, the main checkout is excluded, read-only, the pre-2.36 fallback, and the two kinds of worktree it has to drop — one git cannot spell and one that was deleted without a prune — each with the reason it is allowed to give |
| `test-stdin.sh` | the diff/markdown sniff, including `---` alone staying markdown and a `--color=always` diff still reading as a diff; a failed `mktemp` for the buffer stops with a reason instead of writing `/input.md` (#33) |
| `test-filenames.sh` | accented names, spaces, a leading dash, and the quote, backslash, tab and newline cases from #3 — in diff, md, pr and both levels of worktrees, plus a tab in a worktree's own directory name, a dash-leading directory in md mode, a PR file named ` b/x.md`, the `--read0` fzf is given and the `ctrl-e` binding a worktree path is spent through |
| `test-pr.sh` | four `gh` calls whatever the file count, previews slice the cache, read-only |
| `test-file.sh` | `preen FILE.md` and the picker's enter key: paged on a terminal, plain into a pipe, the glow gate, no less installed |
| `test-layout.sh` | the starting layout (#8): `PREEN_LAYOUT` beats the repository's `preen.layout`, which beats the global one, which beats side-by-side — for the picker's state file, its previews, `ctrl-s` after start, and piped input. Only the exact word `inline` counts; outside a repository the global value still applies, and neither that nor a config git cannot read (md mode outside a repository, and piped input) prints anything |
| `test-width.sh` | the `-w` every render outside fzf asks glow for: the terminal's own width on a 66- and a 132-column pty, for a named file, the enter key and piped input; `COLUMNS` still winning; 80 with no terminal on any fd |

## Nineteen bugs these exist to hold shut

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
  empty, and resolving it through `cd` answers for the suite's own cwd while
  `git -C ""` acts on the repository it is testing. Nothing in `tests/` calls
  `mktemp` directly any more — `mktmpd`, `mktmpf` and `resolve_dir` in `lib.sh`
  fail loudly instead.
- **The test that was supposed to hold that shut only held one guard.** It broke
  `$TMPDIR` from the first call, so every file died at `lib.sh`'s own first
  `mktemp` and no guard past that line was ever reached: the exact line that
  deleted `tests/` could be put back and the suite stayed green. The sweep aims
  the failure at one use of one name at a time now, so the run reaches it.
- **And then it still passed on two ordinary spellings of that line.** Failing
  *every* use of a name killed the file at the first one, so a later site sharing
  the name was never reached; and the source rules matched `=$(mktemp` and
  `cd "$x" && pwd` exactly, so `x="$( mktemp -d )"`, `cd "${x}" && pwd -P` and
  ``x=`new_repo` `` all walked past. The rules match the word `mktemp`, any
  `&& pwd`, and both capture forms now, and the sweep fails the Nth use rather
  than all of them.
- **And then it still passed when the bug moved into `lib.sh`** (#34). The sweep
  found its jobs by grepping for template names, and `lib.sh` was exempt from
  every source rule. So a nameless `d="$(mktemp -d)"` in `new_repo` — the
  round-2 bug again — had no name, lost its jobs without a word, and passed at
  205 of 205; a second helper sharing `preen-test` was never reached, because
  the first use of the name killed the file. The sweep is built from clean runs
  now and keyed on the functions that asked, a call that skips the helpers fails
  wherever it is, `lib.sh` is under the rules by function, and the job list is
  pinned in `tests/sweep-sites`.
- **preen's own state directory was unchecked too.** With an empty
  `$PREEN_STATE` it wrote `/kind`, `/mode` and `/rev` at the filesystem root and
  exited 0.
- **Piped input had the same gap** (#33). With no temporary directory for the
  stdin buffer, the buffer became `/input.md`: as root the input was written
  there, left behind, and preen exited 0.
- **`preen md` on a dash-leading directory found nothing.** `find -weird` read
  the name as options. The root gets a `./`, and the names keep it, because
  glow and `$EDITOR` would read the name as options in turn.
- **`pr` mode previewed two files stitched together** for a file named
  ` b/x.md`, whose header's last seven bytes are ` b/x.md` and so matched the
  tail slice for `x.md`. An unquoted `a/P b/P` is solved rather than tail-
  matched now; a rename, whose paths differ, still falls back to the tail.

## What holds the harness itself

`tests/test-harness.sh` is the only file here that grades the suite rather than
preen, and it is in three parts because they hold different things:

- **the shapes, at the source.** Nothing may name `mktemp` outside `mktmpd`,
  `mktmpf` and `tmp_refused_for`, every `$(new_repo)` and `$(preen_state …)`
  must carry `|| exit 1`, and nothing may resolve a path with `cd "$x" && pwd`
  outside `resolve_dir`. These are greps over every file but the harness
  itself — `lib.sh` included, by function, so a helper of its own is graded like
  a test. A new unguarded site is a source edit, and this is what refuses it the
  moment it is written.
- **the guards, called directly.** `mktmpd`, `mktmpf` and `resolve_dir` must exit
  rather than hand back an empty string, and say what they could not get.
- **every path to `mktemp`, end to end.** Each file is run once with nothing
  failing, under a stand-in `mktemp` that records every call. Then one run per
  job, with `mktemp` failing at ONE call and nowhere else so the run reaches
  it, against a throwaway copy of the checkout that is watched for deleted
  files, staged changes and new commits.

The sweep is built from those clean runs, not from reading the source. `mktmpd`
and `mktmpf` tell the stand-in which call they are making: the template name and
the functions that asked for it, innermost first — `preen-test+new_repo`, or
`preen-shim+preen_list_raw+preen_list`. A job is one such key and the Nth use of
it, never a call index: an index moves with the environment, since a git hook
that calls `mktemp` shifts every number after it.

A call that arrives without a key did not come through the helpers. The stand-in
walks up its parent processes to see whose it is: preen's own calls and git's are
let through, and anything else — a nameless `mktemp -d` in `new_repo`, a raw
call however it is spelled — fails the run.

**What it covers, exactly.** By default the FIRST use of every key in every
file: 73 jobs today, against a few hundred real `mktemp` calls, because
`new_repo` and the list helpers are called many times over. Two helpers that
share a template name are two keys, so each is failed at its own first call. What
the default does not reach is the second *line* that takes the same path, which
is what the `|| exit 1` rule in part 1 is for. `PREEN_HARNESS_DEPTH=full` fails
every use of every key instead — `lib.sh`'s helpers included, to the last call —
at one job per call.

`tests/sweep-sites` pins the default job list, one line per job. The sweep must
produce exactly that list: a job that stops existing fails the run instead of
quietly shrinking it, and a new one fails until its line is added, so the review
sees which call paths came or went. The failure prints the lines to add or
remove.

Every job also reports whether its failure actually **fired**, and one that did
not fails the run. Without that a job whose file died earlier comes back green
having graded nothing, which is how two earlier versions of this file looked
healthy while holding almost nothing.

It is the slow half of the suite — more than all the other files together: nine
clean runs and then 73 jobs of real fixture work, four at a time. On an idle
machine the whole suite takes about three minutes; on a busy one it has taken
more than six. `PREEN_HARNESS_JOBS=8 tests/run.sh` widens the batch if the
machine has the cores, and `tests/run.sh NAME` runs one file without the sweep
while you work.

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
