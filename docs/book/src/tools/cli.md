# The komp CLI

komp is the KFlat project tool. Every command that compiles takes a project
directory (one containing a `kf.toml`); there is no single-file mode.

komp does not compile KFlat itself: for each crate that needs building it runs
`kflatc`, the compiler, found beside the `komp` binary or wherever `KFLATC`
points, and then compiles and links the C with cc.

## Commands

| Command | What it does |
|---|---|
| `komp build <dir>` | Compile to C, then compile and link with cc |
| `komp run <dir>` | Build and run the resulting binary |
| `komp check <dir>` | Type-check only; no binary produced |
| `komp lint <dir>` | Check and report lints, with a tally; see [Linting](lint.md) |
| `komp test <dir>` | Run `@test` functions in the crate |
| `komp update <dir>` | Resolve fetched dependencies again and rewrite `kf.lock` |
| `komp update --installed [<name>...]` | Update installed programs within the requirements they were installed with |
| `komp add <name>[@<req>]` | Add a library from a package index to `[dependencies]` |
| `komp install [<name>[@<req>]]` | Build a program from a package index into `~/.kflat/bin`, or list what is installed |
| `komp uninstall <name>[@<version>]` | Remove an installed program, or one version of it |
| `komp search [<query>]` | List the packages an index offers, with their newest versions |
| `komp info <name>` | List every version of a package in an index |
| `komp cache list \| remove \| clean \| verify` | Look after the sources komp has downloaded |
| `komp <command>` | Run the installed `komp-<command>` |
| `komp self update [<version>]` | Install the newest komp release, or the one named |
| `komp metadata <dir>` | Print the resolved crate graph as JSON, for tools |
| `komp publish <dir>` | Add a library's version to a package index by pull request |
| `komp new <name>` | Scaffold a new project directory |
| `komp init` | Scaffold a project in the current directory |
| `komp version` | Print compiler version |

At a workspace, `build`, `check`, `test` and `fix` work on the workspace's
`default-member`. `-p <crate>` picks one member and `--workspace` picks all of
them; see [Workspaces](../start/projects.md#workspaces).

### komp build

`komp build <project-dir>` compiles the crate to C, then invokes a C
compiler to build the binary. The C output is left in `target/kflat/`.

```console
$ komp build my-project
$ ls my-project/target/kflat/
alloc.c    alloc.kfi    core.c    core.kfi    libcore.a
my_project my_project.c my_project.kfi ...
```

A hyphen in the project name becomes an underscore in the crate name, so
`my-project` produces `my_project.c` and a binary called `my_project`.

Each crate compiles to one translation unit, so linking one function from a
dependency would otherwise pull in the whole crate. komp compiles with
`-ffunction-sections -fdata-sections` and links with `-Wl,--gc-sections`, and
the linker drops whatever nothing reaches — a small program using `core` and
`alloc` comes out roughly a third of the size it would be otherwise. This
assumes a GNU-compatible linker (GNU ld or lld).

The `--unity` flag merges the entire crate (and all dependencies) into a
single C file. This produces a faster debug build and is useful for
inspecting the generated code:

```console
$ komp build --unity my-project
```

Everything lands in one translation unit, so the C compiler sees the whole
program at once. It is slower than the default separate build on anything
large, and it does not write reusable artifacts.

### komp run

`komp run <project-dir>` builds and then executes the binary. The exit code
of the binary becomes komp's exit code. A library crate cannot be run:

```console
$ komp run mylib
komp run: cannot run a library crate (set kind = "bin" in kf.toml)
```

### komp check

`komp check <project-dir>` type-checks without producing C or a binary. It
is the fastest feedback loop:

```console
$ komp check my-project
check: OK
```

If errors are found, the exit code is non-zero.

It checks the crate's `_test.kf` files along with the rest of its source,
so a crate cannot report `check: OK` and then fail to build its own test
binary. A dependency's tests are not checked — they belong to that crate's
own build and are compiled into nothing here.

`check` works on a project that has never been built: it first brings each
dependency's interface (`target/kflat/*.kfi`) up to date, then checks the
crate against them, so every check after the first reads no dependency
source.

### komp test

`komp test <project-dir>` finds all `@test` functions in `_test.kf` files
inside the crate, runs them, and reports failures. See
[Writing tests](testing.md).

### komp publish

`komp publish <project-dir>` adds a library's version to a package index,
[komp-co/index](https://github.com/komp-co/index) unless `--index <url>` or
`$KFLAT_INDEX` names another:

```console
$ git tag v0.2.0 && git push origin v0.2.0
$ komp publish
checked  json 0.2.0
entry    js/on/json.toml: 0.2.0 at 3f2a9c1
opened   https://github.com/komp-co/index/pull/12
```

The version is `kf.toml`'s, and the commit is the one its `vX.Y.Z` tag names.
`kf.toml`'s `description`, when it has one, becomes the package's description
in the index, replacing the one an earlier version gave.
komp refuses, and says what to do, when the crate is a `bin`, its name is not
lowercase `snake_case`, the working tree has uncommitted changes, the tag is
missing, names another commit or is not pushed, the crate does not pass
`komp check`, or the index already has that version.

The entry is committed on a branch `publish/<name>-<version>` in a clone
under komp's cache. Opening the pull request uses the
[GitHub CLI](https://cli.github.com), `gh`: komp pushes the branch to your fork
of the index and opens or updates the pull request with your `gh` login. When
`gh` is not installed or not logged in, the index is not on GitHub, or a step
fails, komp says why, keeps the committed entry, and exits 1; run it again
once `gh` works, or open the pull request from that branch yourself.

`komp publish --status` lists the package's versions in the index, then its
pull requests with their review state: in review, changes requested,
approved and waiting to be merged, or declined. The pull requests need `gh`;
without it only the index's versions are listed. A maintainer of the index
approves every new package.

### komp update

`komp update <project-dir>` resolves every version, `git` and `tarball`
dependency again: a version requirement moves to the highest version the index
now has, and a tag or branch to the commit it names now. It fetches what is
new and rewrites `kf.lock`. Every other command fetches only what the lock
does not already pin. See
[Fetched dependencies](../start/projects.md#fetched-dependencies).

`komp update --installed` updates the programs [`komp install`](#komp-install)
put in `~/.kflat/bin` instead. Each is resolved again against the requirement
and index it was installed with, and rebuilt only when that finds a newer
version. Names pick some; none means every one.

```console
$ komp install komp_hello@0.1
installed `komp_hello` 0.1.0 as /home/me/.kflat/bin/komp-hello
$ komp update --installed
updated `komp_hello` 0.1.0 -> 0.1.1
$ komp update --installed komp_hello
`komp_hello` 0.1.1 is the newest its requirement allows
```

Here 0.2.0 is published too, but `0.1` does not allow it; `komp install
komp_hello@0.2` moves to it, and records that requirement instead.

### komp metadata

`komp metadata <project-dir>` prints the project's resolved crates as one JSON
object on one line, for tools that run kflatc themselves, such as a language
server. It fetches first, as a build would, and takes `--locked` and
`--offline` like one. At a workspace, or at any of its members, it covers
every member and every crate they reach, so a tool asking about one file sees
the whole workspace.

With `hello` depending on `greet` by path, and `[lint] dead_code = "allow"`
(reformatted here):

```text
$ komp metadata
{
  "schema": 1,
  "komp_version": "0.2.0",
  "kflatc": "/home/user/komp/bin/kflatc",
  "workspace_root": null,
  "target_dir": "/tmp/work/hello/target/kflat",
  "members": ["/tmp/work/hello"],
  "crates": [
    {"name": "core", "version": "0.1.0", "kind": "lib", "root": "/home/user/komp/libs/core",
     "source": "bundled", "member": false, "deps": [], "loads": [], "lints": [],
     "lint_options": []},
    {"name": "alloc", "version": "0.1.0", "kind": "lib", "root": "/home/user/komp/libs/alloc",
     "source": "bundled", "member": false, "deps": ["core"], "loads": ["core"], "lints": [],
     "lint_options": []},
    {"name": "greet", "version": "0.3.0", "kind": "lib", "root": "/tmp/work/greet",
     "source": "path", "member": false, "deps": ["core", "alloc"], "loads": ["core", "alloc"], "lints": [],
     "lint_options": []},
    {"name": "hello", "version": "0.1.0", "kind": "bin", "root": "/tmp/work/hello",
     "source": "path", "member": true, "deps": ["greet"], "loads": ["core", "alloc", "greet"],
     "lints": [{"name": "dead_code", "level": "allow"}], "lint_options": []}
  ]
}
```

| Field | Meaning |
|---|---|
| `schema` | Raised when a field changes meaning or goes away; a new field leaves it as it is |
| `kflatc` | The compiler komp would run: the one the project's `kflat` pin picks, when it has one |
| `workspace_root` | The directory holding `[workspace]`, or `null` |
| `target_dir` | Where compiled crates' `.kfi`, `.h` and `.c` land; kflatc's `--out` |
| `members` | The crates the command was about, as roots |
| `crates` | Every crate, each once, dependencies before the crates that use them |
| `deps` | The crate's direct dependencies by crate name; kflatc's `--dep` |
| `loads` | Every crate `deps` reach, in order; kflatc's `--load` |
| `source` | `bundled` (comes with komp), `fetched` (from the cache) or `path` |
| `lints` | The crate's lint levels in the order they apply: its `lint.toml` rows, groups first, then its `[lint]` rows; kflatc's `--lint-toml` and `--lint` |
| `lint_options` | The crate's `lint.toml` options as `{"name", "key", "value"}`, the value as `lint.toml` writes it; kflatc's `--lint-toml-option` |

A graph that does not resolve prints `{"schema": 1, "error": "..."}` and exits 1.

### komp add

`komp add <name>` adds a library from a package index to the crate's
`[dependencies]`, then fetches it and updates `kf.lock` as a build would. The
row it writes is the newest version, which allows that version's compatible
successors; `<name>@<req>` writes that requirement instead. An entry of the
same name is replaced, and the rest of `kf.toml` is left as written.
`--index <name>` looks in an index `kf.toml` declares under `[indexes]`, and
writes the row with that `index`. At a workspace, `-p <crate>` picks the
member.

```console
$ komp add json
added `json` "0.2.0" to ./kf.toml, resolving to 0.2.0
$ komp add komp_fmt
error: `komp_fmt` is a program, not a library: `komp install komp_fmt` installs it
```

### komp install

`komp install <name>` builds a program published to a package index and makes
it the default: `~/.kflat/bin/<binary>` points at it, or `bin/` under
`$KFLAT_HOME` when that is set. The package is resolved as a dependency would
be: `<name>@0.2` takes the highest version `0.2` allows, as the same
requirement in `kf.toml` would, and a bare name the highest version published.
`--index <url>` looks in another index than the default. A package that ships
a `kf.lock` is built with the dependencies it pins.

```console
$ komp install komp_fmt
installed `komp_fmt` 0.2.0 as /home/me/.kflat/bin/komp-fmt
$ komp install
komp_fmt 0.2.0  /home/me/.kflat/bin/komp-fmt; also 0.1.0
$ komp uninstall komp_fmt@0.1.0
uninstalled `komp_fmt` 0.1.0
```

Every version komp builds goes in `~/.kflat/tools/<package>/<version>`, once:
a version already there is not built again, and installing another version
makes it the default while the earlier one stays, for the projects that
[pin](../start/projects.md#pinning-tools) it. `komp install` with no package
lists each default and the other versions beside it. `komp uninstall
<name>@<version>` removes one version, and `komp uninstall <name>` every one
and the default.

A binary is named after its package with `_` spelled `-`. Only a
`kind = "bin"` package installs; a library is a dependency, and belongs in
`[dependencies]`. Each default is recorded in `installed.toml` beside `bin/`,
in `kf.lock`'s format with the requirement it was installed with added, so
the exact source of every program is known and
[`komp update --installed`](#komp-update) can resolve it again.

`komp <command>`, for a command komp does not have, runs `komp-<command>`
with the arguments that follow it and exits with its status: the version the
current project's `[tools]` pins, else the default. Installing `komp_fmt` is
what makes `komp fmt` work, whether or not `~/.kflat/bin` is on `PATH`. A
built-in command always wins over an installed one of the same name.

### komp search and komp info

`komp search` lists the packages a package index offers, each with its newest
version that is not yanked and its description; `komp search <query>` keeps the ones whose names
contain it. `komp info <name>` lists every version of one package, marking
the newest and any yanked. Both read the index's checkout in the cache,
bringing it up to date first, and take `--index <url>` to look in another
index than the default.

```console
$ komp search
json      0.2.0  JSON reading and writing
komp_fmt  0.1.0  The KFlat formatter: komp fmt
$ komp search fmt
komp_fmt  0.1.0  The KFlat formatter: komp fmt
$ komp info json
json, in https://github.com/komp-co/index
JSON reading and writing
  0.1.0
  0.2.0  newest
```

A package's description is the one `komp publish` took from its `kf.toml`;
a package published without one shows none.

### komp cache

Fetched sources live in komp's cache, `$KFLAT_CACHE` or else
`~/.cache/kflat`: each under `git/<commit>` or `tarball/<sha256>`, never
changed once written, with the package index checkouts under `index/`.

```console
$ komp cache list
json 0.2.0  git 44a09fc77681  /home/me/.cache/kflat/git/44a09fc776814a7aa1871619f1c1b5786a9d5b43
index  /home/me/.cache/kflat/index/github.com_komp-co_index
$ komp cache verify
ok       json 0.2.0 (git 44a09fc77681)
1 checked, 0 damaged
```

When komp fetches a source it records a digest of its files beside it.
`komp cache verify` hashes each source again: one that no longer matches is
reported, removed and fetched again by the next command that needs it, and
the exit status is 1. A source fetched before digests were kept has its
digest recorded the first time it is verified.

`komp cache remove <name>[@<version>]` removes the sources of that package,
or of that one version; `komp cache clean` removes everything komp
downloaded, and keeps the bootstrap seeds that `bootstrap/build.sh` stores
in the same directory. Nothing is lost either way: a build fetches what its
`kf.lock` pins again.

### komp self update

`komp self update` installs the newest komp release, the way a release's
[install script](../start/installing.md) installs it: it downloads
`kflat-<version>.tar.gz`, checks it against the sha256 published beside it,
builds komp and kflatc with `cc`, and puts them in
`~/.kflat/toolchains/<version>/`, where `~/.kflat/bin/komp` then points.
Toolchains already installed stay where they are, for the projects that
[pin](../start/projects.md#pinning-the-toolchain) them. `komp self update 0.5.1`
installs that release instead of the newest, which also goes back to an
earlier one.

```console
$ komp self update
building komp 0.5.1 with cc
building kflatc 0.5.1 with cc
installed kflat 0.5.1 in /home/me/.kflat/toolchains/0.5.1
installed komp 0.5.1; /home/me/.kflat/bin/komp now runs it
$ komp self update
komp 0.5.1 is the newest release
```

It needs `curl`, `tar` and a C compiler. `KFLAT_RELEASES` names another
place to take releases from, laid out as GitHub lays them out.

## kflatc

`kflatc` is the compiler komp runs for each crate. You do not normally call it
yourself; it is documented so its role in a build is not a mystery.

```console
$ kflatc compile --name geometry --root ../geometry --out target/kflat --dep core=<hash> --load core
$ kflatc check --name app --root . --out target/kflat --dep geometry= --load core --load geometry --json
```

`kflatc compile` compiles one crate against the interfaces (`.kfi`) of its dependencies,
already in `--out`, and writes the crate's own `.kfi`, `.h` and `.c` there.
`--bin` marks the crate that has `main`; each `--dep NAME=HASH` names a
direct dependency and the interface hash it was built against, and each
`--load NAME` an interface to read, dependencies first, covering everything
the direct ones reach. `--project DIR` names
the project being built: warnings about files outside it are hidden. kflatc
never reads `kf.toml` or `lint.toml`: komp passes each row of
[`lint.toml`](lint.md#linttoml) as `--lint-toml NAME=LEVEL`, groups first,
each lint option as `--lint-toml-option NAME.KEY=VALUE`, anything wrong with the file's shape as `--lint-toml-error MESSAGE`, and each
row of the `[lint]` table as `--lint NAME=LEVEL`; a wrong row is reported as a
row of its file. `-q`, `--deny-warnings` and `-A/-W/-D <lint>` mean what they
mean to komp, which passes its own along.

With `--tests` in place of `--bin`, `kflatc compile` instead compiles the crate
with its `_test.kf` files and a generated test main, and writes
`test/<name>_tests.h` and `.c` under `--out`, reporting no warnings. This is
the translation unit `komp test` compiles and links into the test binary.

`kflatc check` takes the same arguments, plus `--json` for newline-delimited
JSON diagnostics or `--summary` for the tally `komp lint` prints, and
type-checks the crate with its `_test.kf` files, writing nothing. `komp check` first brings each dependency's interface up to date with
`kflatc compile`, marking it with a `.kfi.stamp` so the next check reuses it,
then runs `kflatc check` on the root.

`kflatc unity --crate NAME=ROOT... --out FILE` compiles a whole project into
one C file, as `komp build --unity` needs: each `--crate` names a crate and its
source root, dependencies first and the root last. `--bin` and `--tests` mean
what they do to `compile`. The crates' own C sources are left out; komp
appends them.

`kflatc lints` prints every lint at the level the lint flags on its command
line give it, as `komp lint --list` shows.

`kflatc version` prints what komp needs to know about the compiler it runs, one
`key value` line each after the first: its interface `abi`, `runtime` and
`target`. An artifact records these and the kflatc binary's own hash, so
replacing kflatc rebuilds every crate.

`kflatc serve` keeps the compiler running and answers JSON requests on its
standard input, for editors and other tools: the questions an editor asks
about a file, and checks of unsaved text. Its protocol is
[its own chapter](serve.md).

Every subcommand exits 0 on success, 1 when the crate has errors (reported as
usual), and 2 on a malformed command line.

## Flags

| Flag | Effect |
|---|---|
| `-q`, `--quiet` | Suppress compiler warnings (per-file copier notices) |
| `--verbose` (on `build`) | Show the cc invocation |
| `--diagnostic-format=json` (on `check`) | Output diagnostics as JSON lines |
| `--unity` (on `build`/`run`/`test`) | Emit a single merged C unit |
| `--locked` | Fail rather than change `kf.lock` |
| `--offline` | Fail rather than fetch a dependency or install a [pinned toolchain](../start/projects.md#pinning-the-toolchain) |

### Colored output

Diagnostics are colored when komp's output is a terminal and plain when it
is not, so a pipe, a redirect or a CI log never receives escape bytes in
the middle of an error message. Setting `NO_COLOR` to anything non-empty
turns color off even in a terminal — that is the only case the convention
exists for, so it wins over the terminal check.

Color is added strictly around the plain rendering: no character moves, and
the `path:line:col` head is left uncolored so a terminal can still turn it
into a clickable link.

## Structured fixes

`--diagnostic-format=json` prints one object per diagnostic, and each
carries a `fix` — a machine-applicable repair, or null:

```console
$ komp check --diagnostic-format=json my-project
{"schema_version":3,"severity":"error","code":null,"message":"no method `sunm` on `Point` (did you mean `sum`?)","byte_start":171,"byte_end":179,"file":"src/lib.kf","line":13,"column":12,"secondary":[],"fix":{"title":"change to `sum`","replacement":"sum","applicability":"machine-applicable","byte_start":179,"byte_end":183,"file":"src/lib.kf"}}
```

`code` is the lint that fired, or null for an ordinary compiler error —
the name `@allow(...)` and `kf.toml` configure, so a client can filter and
suppress on it. `secondary` is the diagnostic's supporting labels, the
ones the text renderer prints as `= note:` lines; it is always an array,
`[]` when there are none, and each label carries its own file because a
note routinely points somewhere other than the error it supports. Both
editor plugins render it as the editor's related information.

A message can say "did you mean `sum`?" and leave the reader to find the
four characters to change. A fix says which four. That is the difference
between a diagnostic a person reads and one a client can offer as a code
action (#108).

Note the two spans differ. The diagnostic points at `p.sunm()`, which is
what went wrong; the fix points at `sunm`, which is what to replace.
Applying a repair over the diagnostic's own span would overwrite the whole
call. A fix also names its own file, since a repair need not land where
the problem was reported.

`fix` is null on every diagnostic that does not know a repair — most of
them. It is a suggestion only where the compiler already knows the answer
exactly. Today that is two cases.

**A misspelled method.** A name within one edit per four characters of a
real method on the receiver's type. `frobnicate` gets no suggestion,
because a wrong one is worse than none — it sends the reader to change
working code.

**A missing import.** `cannot find function` is usually not a typo, and the
compiler knows which module declares the name. The repair inserts the
import, and a zero-width span is how a fix expresses an insertion:

```console
{"message":"cannot find function `println` in this scope","byte_start":29,"byte_end":42,"fix":{"title":"add `import core.*`","replacement":"import core.*\n\n","byte_start":0,"byte_end":0,"file":"src/lib.kf"}}
```

Note the diagnostic is on one line and the repair lands on another — an
import goes to the top of the file whatever the name below it was. A client
offers the action where the PROBLEM is, and applies the edit where the fix
says.

The insertion point is past the file's last import, or byte 0 when it has
none. Imports must precede declarations, so appending to the existing block
is the only placement that is always legal; the replacement text carries
the newline that placement needs.

Nothing is suggested when **two** modules declare the name. Two candidates
mean two imports, and picking one at random is worse than picking none: it
compiles, and may bind the wrong function. A diagnostic carries one fix, so
until it can carry several, ambiguity stays silent.

The field is additive and `schema_version` stays 1: a reader written
against the earlier shape sees one more key and keeps working.

## Legacy positional form

The form `komp <project-dir> [out.c]` (no subcommand) is retained for
backward compatibility. It compiles the crate to the named C file, or to
`<project-dir>/target/kflat/komp_out.c` if no name is given. Prefer
`komp build` — it produces artifacts in a known location and handles
dependencies correctly.

A first argument that is neither a command, an installed `komp-<command>`,
nor a directory is reported as an unknown command.

