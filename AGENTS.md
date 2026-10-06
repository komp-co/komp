# Repository Guidelines

## Where the truth lives

- **The issue tracker** (GitHub issues) sets direction and holds every piece
  of open work. There is no roadmap document; do not write one. Compiler and
  language issues are komp-co/kf-lang's.
- **`docs/book/`** describes komp, its commands and `kf.toml` as they are.
  The language, libraries and compiler are documented in kf-lang's book.
- **This file, `CONTRIBUTING.md` and `README.md`** hold the working rules.

## Project Structure

komp is KFlat's project tool. The compiler, its libraries and the seed are in
komp-co/kf-lang; komp is built with a released kflat toolchain, the one
`kf.toml`'s `kflat` pin names.

```
kf.toml      — komp, one program crate, and the kflat release it is built with
src/         — its sources: `main.kf`, and a module per area (build, cli,
               fetch, install, project, publish, testing)
native/      — the C it links
docs/book/   — komp's book
scripts/     — check.sh and the ratchets CI runs
```

komp is one crate and nothing links it as a library: tools that need a
project's crates read `komp metadata`. Declare what other modules use
`internal`, not `pub`. Its whole-project tests are the `integration` module. komp
links no part of the compiler: it runs `kflatc` per crate and cc after it.
What the two must agree on (the files kflatc writes, which files make a crate,
the `serve` protocol) is kflatc's documented command line, and komp keeps its
own copy of those rules. komp drives every kflatc from `oldest_kflatc_driven()`
up, so a change to how it calls kflatc must keep the older ones working.

## Build, Test, and Development Commands

Every command takes a project directory — the one holding `kf.toml`. There is
no single-file mode.

| Command | Purpose |
|---|---|
| `sh scripts/check.sh` | The gate before pushing: build with the pinned toolchain, komp's tests, the CLI checks |
| `komp build .` | Build komp, to `target/kflat/komp` |
| `komp test .` | Run komp's `@test` functions |

## Coding Style & Naming

- **Types:** `UpperCamelCase` — `Expression`, `TypeKind`
- **Functions & variables:** `lower_snake_case` — `parse_expr`, `check_stmt`
- **Constants:** `UPPER_SNAKE_CASE`; **files:** `lower_snake_case`
- **No abbreviations** except universal ones (`ctx` ok; `tc` is not)
- **No emojis** in code or commits
- **One concept per `.kf` file**: if you cannot describe the file in one
  sentence without "and", it is two files. No grab-bags (`utils.kf`,
  `helpers.kf`, `misc.kf`) — put a helper next to what uses it.
- **A module is the directory, not the file.** Splitting a file inside its
  directory changes no import; adding a sub-directory creates a new module and
  touches every importer.
- **File length ratchets on growth.** `scripts/check_file_sizes.sh` fails when
  a file grows past its recorded size, or crosses 350 lines without a baseline
  entry. Imports and comment-only lines are not counted. Split it, or bless it
  with `--update` and say why in the commit.
- **Long lines ratchet too.** `scripts/check_line_lengths.sh` freezes the
  count of lines over 120 columns per file. Wrap instead: a trailing binary
  operator continues a line, and parameter and argument lists may span lines.
- **Unsafe ratchets down.** `scripts/check_unsafe.sh` freezes the count of
  `unsafe {` blocks per compiler source file. Own a node with
  `Box<T>`, borrow with `&T` or `&var T`, and call the library rather than
  declaring an `extern`; bless a block that must stay with `--update` and say
  why in the commit.
- **The tree is formatted.** CI runs `komp fmt --check compiler libs` with
  the formatter from the package index (`komp tool install komp_fmt`); run
  `komp fmt` on what you touch before committing. The `pre-commit` hook in
  `.githooks` checks the staged files when the formatter is installed.
- **Lints are fixed, not tolerated.** Fix what `komp lint` reports; when a
  finding must stay, put `@allow(<lint>)` on the declaration and say why in
  the commit. The pinned toolchain refuses an `@allow` naming a lint it
  predates, so for a newer lint set it in the crate's `lint.toml`.
- **komp's output is deterministic.** Artifacts are reused by content hash, so
  nothing whose order depends on hashing or addresses may reach a file komp
  writes.
- **komp's source uses only what the pinned kflat release compiles.** A newer
  language feature waits for the release that has it and a bump of the
  `kflat` pin in `kf.toml`.
- **Replace, don't accrete.** No `parse_expr_v2` beside `parse_expr`, no
  TODO comments (file an issue), no helper until there is a third use.

### Comments

**Comment the code, not the decision that produced it.** The reasoning behind
a change goes in the commit message and the PR body. A comment is re-read
every time the file is opened, and it rots.

Write only:

| Keep | Example |
|---|---|
| the contract a caller needs | "Indexing yields a borrow, never a copy" |
| a constraint, marked `CONSTRAINT:` | "runs after alpha_rename, so a plain name comparison is exact" |
| a mechanism the code cannot state | a layout diagram, a table of what arrives at a `when` |

Delete: history ("it used to", "before this", "no longer"), issue numbers and
issue archaeology, design alternatives, comparisons to other languages,
references to documents, and anything the code plainly says.

**Length is the smell.** Most files need no header at all; a header past ~5
lines, or a function comment past ~3, is nearly always a decision being
narrated. If it needs a paragraph, it belongs in the commit message.

### Kotlin style

The compiler was written before the language had most of its conveniences.
Write new code, and code you touch, the way the language reads now:

| Write | Rather than |
|---|---|
| `while d in &decls { ... }` | `var i = 0` / `while i < decls.size()` / `i = i + 1` |
| `while i in 0..n { ... }` when the index matters | the same, by hand |
| `val kind = if c { a } else { b }` | `var kind = b` then `if c { kind = a }` |
| `val g = find(xs, "g") ?: return 1` | a `when` whose `None` arm returns |
| `find(xs, "g")?.arity ?: -1` | nested `when`s over each optional |
| `fun Decl.is_nullary(): bool` | `fun is_nullary(d: &Decl): bool` |
| `"${name}/${arity}"` | a chain of `append` calls |
| `val` | `var` that is never reassigned |

Keep `append` for building a string in a loop, where `+` would copy the whole
accumulator each time. The List adapters (`map`, `filter`, `any`, `count`,
`fold`, `position`) are eager and hand each element to the lambda by value, so
over owning elements they copy; prefer a borrowing loop there. `let`, `also`,
`apply` and `take_if` are for removing a temporary, not for decoration.

## Testing

Tests use `@test` and live as sibling `_test.kf` files sharing scope with source:

```kf
@test
fun int32_ty_is_not_poison(): void {
    val t = int32_ty(no_span())
    assert_eq(t.is_poison(), false, "int32 isn't poison")
}
```

- New functions with branching logic ship with tests in the same commit
- Bug fixes include a regression test; run `komp test` on the crate before
  every commit, and `sh scripts/check.sh` (the quick gate) before pushing;
  CI runs the full gate, so do not run `--full` as well unless a job is red
- A change that breaks an existing test fixes the test or the change in the
  same commit — never leave the suite red
- One assertion per test; split unrelated assertions into named tests
- A test that builds a whole project goes in the `integration` module

### Verifying a change

**`komp check` passing does not mean the program builds.** Confirm a change to
how komp builds with `komp run`, not `komp check`.

**Only komp reads a manifest.** The build graph (`effective_deps`) is the one
place a crate's dependencies are worked out, for every command. kflatc is
handed what it needs on its command line (`--crate`, `--dep`, `--lint`); do
not give it a reason to open `kf.toml`.

**Only `sync_sources` fetches.** It runs before a command builds, reads package
indexes, fetches dependencies into the cache and writes `kf.lock`. The build graph
reads the lock and the cache and nothing else, so it never touches the network.
Tests fetch from `file://` sources in scratch space, never from a real host.

## Commit Guidelines

- **Subject under 70 chars**, body wraps at 72; **name the *why*, not what**
- **One concept per commit** — split if the subject says "and" or "also"
- **Every commit passes CI** — tests green at every history point
- **Area prefix** in subjects: `tool:`, `build:`, `fetch:`, `install:`, `docs:`, `ci:`

## Documentation

**A change that alters observable behaviour updates the book in the same
commit**, so the tree never contradicts itself at any point in history.

| You changed | Update |
|---|---|
| the CLI, its flags, or `kf.toml` | `docs/book/src/tools/cli.md`, `start/projects.md` |
| testing or linting | `docs/book/src/tools/testing.md`, `lint.md` |
| a rule other code must follow | this file |

**Every book example is run before it is written down**, with a komp built
from the tree being changed. `docs/book/AUTHORING.md` has the method.

## Git and Forge

The repository is `komp-co/komp` on GitHub, with `kf-lang` (the compiler),
`json`, `komp-test`, `kf-lsp` and `kf-extensions` beside it in the same
organization. Use the `gh` CLI:

| Command | Purpose |
|---|---|
| `gh issue create --repo komp-co/komp ...` | Create an issue |
| `gh pr create --repo komp-co/komp --base development ...` | Open a pull request |
| `gh pr checks <n> --repo komp-co/komp` | Watch a PR's CI |
| `gh pr merge <n> --repo komp-co/komp` | Merge once CI is green |

Work merges into `development`.
