# Contributing

preen is one bash script, a test suite, and a docs site. Nothing here needs a
toolchain: clone it, run `tests/run.sh`, and you are set up.

## Before you open a pull request

```sh
bash -n bin/preen     # catches an unclosed quote or a broken heredoc
tests/run.sh          # the behavior suite
```

Both run in CI, along with a site build and a real Docker image probe. Green
locally is not the same as green in CI — the runner has no glow and no
terminal, which is exactly where the interesting failures live.

Nor is green on your machine the same as green on the other one. The suite runs
twice, on `ubuntu-latest` and on `macos-latest`, because macOS gives preen
**bash 3.2.57** and the BSD `sort`, `tr`, `find` and `awk`, while Linux gives it
bash 5 and the GNU ones. `mapfile`, `declare -A`, `${var^^}`, `grep -P` and
`find -printf` all work on one and fail on the other, and preen is written to
the older, stricter side of both.

If you changed the site, build it too:

```sh
cd site && pnpm install && pnpm build
```

## Tests

Plain bash, no framework. `tests/README.md` explains how preen is driven
without a terminal, which is the part that is not obvious.

Two rules worth stating out loud:

- **A new assertion must be checked against the broken code.** Remove the fix,
  run the test, watch it fail, put the fix back. An assertion that passes either
  way is worse than no assertion, because it reads like cover.
- **Do not reimplement preen inside a test.** A test that runs its own `git
  diff` grades the copy in the test, and keeps passing after `bin/preen` changes
  underneath it. Drive the real entry points instead.

## Where documentation goes

| audience | lives in |
|---|---|
| people **using** preen | `site/content/docs/` — published to [preening.dev](https://preening.dev) |
| people **changing** preen | `README.md`, `tests/README.md`, `site/AGENTS.md`, this file |

Do not duplicate one into the other. Link instead.

US English throughout: color, behavior, center.

## Labels

Every issue gets one **type** and one **priority**.

### Type

| label | means |
|---|---|
| `bug` | it does not do what it says |
| `enhancement` | it does not do this yet |
| `documentation` | the words are wrong, the code is fine |
| `good first issue` | small, self-contained, and the right answer is clear |

### Priority

| label | means | example |
|---|---|---|
| `P0` | Critical or breaking. CI is red, or users are blocked. Drop other work. | the site is down; `main` will not build |
| `P1` | A top feature, or an urgent bug that is not severely breaking. | a real bug on real user data; something broken on the live site |
| `P2` | Worth doing, nowhere near as urgent as P1. | a latent regression risk; a documented option that does nothing |
| `P3` | Tech debt, nice-to-have, or a simple content or reference fix. | a wrong sentence; a leaked temp directory |

Two things this scheme is **not** for:

- **P0 is not "important to me".** It means work stops. If nothing is red and
  nobody is blocked, it is not P0. An empty P0 list is the normal state.
- **P3 is not "never".** A blocked issue sits at P3 because it cannot start
  yet, not because it does not matter. Say so in the issue.

Priority is about urgency, type is about kind. They move independently: a P3
bug is still a bug, and a P1 `documentation` issue is still just words.

## Pull requests

Squash-merged, one commit per pull request on `main`. Write the description for
someone who was not there:

- what was wrong, and what it cost — not just what you changed
- what you ran to prove it, and what the result was
- anything you decided **not** to do, and why

If a reviewer finds something you chose to leave alone, say so in the pull
request rather than quietly fixing it later. That is how the next person learns
it was a decision.

## License

MIT. By contributing you agree your work ships under it.
