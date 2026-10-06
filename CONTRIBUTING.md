# Contributing to komp

## Where work is tracked

- **Issues** hold all open work and set the direction. There is no roadmap
  document in the tree. A bug in the compiler or the language goes to
  [kf-lang](https://github.com/komp-co/kf-lang/issues).
- **Design reasoning** goes in the issue and the PR body, not in a file.
- **`docs/book/`** is komp's book: what its commands and `kf.toml` do today.
- **`AGENTS.md`** holds the house rules: style, comments, tests, commits.

## Documentation lands with the change

A PR that alters observable behaviour and leaves the docs describing the old
behaviour is incomplete. Keep the doc edit in the same commit as the change it
describes. Run every example before you write it down;
`docs/book/AUTHORING.md` explains why that is the one hard rule.

## Branch + PR convention

- **One branch per issue**, named `<type>/<issue#>-<slug>`:
  - `type` ∈ `feat`, `fix`, `hardening`, `perf`, `docs`, `chore`
  - example: `fix/5-unresolved-dep-error`
- Close the issue from the PR with `Closes #<n>`.
- **PRs target `development`**, the default branch. Nothing is committed to
  `development` or `main` directly.

## The compiler komp is built with

komp is built with a released kflat toolchain: `compiler/kf.toml` pins it
with `kflat = "<version>"`, and CI installs the highest release the pin
allows from kf-lang's releases. komp's source may use only what that release
compiles; a newer language feature waits for a kf-lang release and a bump of
the pin, in a PR of its own.

With the pinned toolchain installed, `komp build compiler` builds komp, and
`komp test compiler/kf-tool` runs its tests.

## CI

Two jobs, each installing the pinned toolchain and building komp with it:

1. **test**: kf-tool's tests (`CHECK_CLI=0 sh scripts/check.sh`),
2. **cli**: the command-line checks (`CHECK_TESTS=0 sh scripts/check.sh`).

Both run the ratchets first: no `.kf` file may grow past 350 lines of code
or gain a line over 120 columns beyond its baseline in `scripts/`.

Run `sh scripts/check.sh` before pushing; it is both jobs.

## Local dev quickstart

```sh
git config core.hooksPath .githooks   # once per clone
sh scripts/check.sh                   # before pushing
```
