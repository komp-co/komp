# The komp CLI

komp is the KFlat project tool. Every command that compiles takes a project
directory (one containing a `kf.toml`); there is no single-file mode for
building. The exception is `komp query`, which answers questions about one
file for an editor and needs no crate around it.

komp does not compile KFlat itself: for each crate that needs building it runs
`kflatc`, the compiler, found beside the `komp` binary or wherever `KFLATC`
points, and then compiles and links the C with cc.

## Commands

| Command | What it does |
|---|---|
| `komp build <dir>` | Compile to C, then compile and link with cc |
| `komp run <dir>` | Build and run the resulting binary |
| `komp check <dir>` | Type-check only; no binary produced |
| `komp test <dir>` | Run `@test` functions in the crate |
| `komp query <what> --file <path> [--offset <N>] [--overlay <path>]` | Answer an editor's question about one file as JSON |
| `komp update <dir>` | Resolve fetched dependencies again and rewrite `kf.lock` |
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
     "source": "bundled", "member": false, "deps": [], "loads": [], "lints": []},
    {"name": "alloc", "version": "0.1.0", "kind": "lib", "root": "/home/user/komp/libs/alloc",
     "source": "bundled", "member": false, "deps": ["core"], "loads": ["core"], "lints": []},
    {"name": "greet", "version": "0.3.0", "kind": "lib", "root": "/tmp/work/greet",
     "source": "path", "member": false, "deps": ["core", "alloc"], "loads": ["core", "alloc"], "lints": []},
    {"name": "hello", "version": "0.1.0", "kind": "bin", "root": "/tmp/work/hello",
     "source": "path", "member": true, "deps": ["greet"], "loads": ["core", "alloc", "greet"],
     "lints": [{"name": "dead_code", "level": "allow"}]}
  ]
}
```

| Field | Meaning |
|---|---|
| `schema` | Raised when a field changes meaning or goes away; a new field leaves it as it is |
| `kflatc` | The compiler komp would run |
| `workspace_root` | The directory holding `[workspace]`, or `null` |
| `target_dir` | Where compiled crates' `.kfi`, `.h` and `.c` land; kflatc's `--out` |
| `members` | The crates the command was about, as roots |
| `crates` | Every crate, each once, dependencies before the crates that use them |
| `deps` | The crate's direct dependencies by crate name; kflatc's `--dep` |
| `loads` | Every crate `deps` reach, in order; kflatc's `--load` |
| `source` | `bundled` (comes with komp), `fetched` (from the cache) or `path` |
| `lints` | The crate's `[lint]` rows; kflatc's `--lint` |

A graph that does not resolve prints `{"schema": 1, "error": "..."}` and exits 1.

### komp query

`komp query <what> --file <path>` answers one question about one file and
prints a single JSON object. It exists for editors: the compiler owns the
answer, and the editor plugin owns the protocol. Nothing is cached between
runs.

Three of the ten questions — `symbols`, `folding`, `selection` — only
parse, so they still answer while the file is half-written and does not
type-check. The other seven report a type or resolve a name, which means
running the checker, which means assembling the crate around the file —
komp finds it by walking up for a `kf.toml`, the same rule the editor
plugins use. A typed query therefore costs about what `komp check` costs.

`--overlay <path>` supplies the text of `--file` from somewhere else. The
file keeps its identity — the walk still finds it in its project, under its
own module path — and only its bytes come from the overlay. That is what an
editor needs: an offset is into the document on screen, so an answer
computed against the file as last saved is an answer about different bytes
than the question was asked about. Without it, completion is the sharp
case, since it is only ever asked while the buffer is dirty.

```console
$ komp query completion --file src/lib.kf --offset 271 --overlay /tmp/buffer.kf
```

One file at a time: the editor asks about the buffer in front of it, and
the others it happens to have open are not part of the question. An overlay
komp cannot read is an error rather than an empty document — answering with
an empty outline or an empty completion list would look like a correct
answer about a file nobody has written yet.

`symbols` returns the declaration tree, which is what an outline, a
breadcrumb bar, and "go to symbol in file" all read:

```console
$ komp query symbols --file src/point.kf
{"schema_version":1,"file":"src/point.kf","symbols":[{"name":"Point","kind":"struct","detail":"","byte_start":0,"byte_end":33,"children":[{"name":"x","kind":"field","detail":"int32","byte_start":23,"byte_end":24,"children":[]}]}]}
```

`folding` returns the regions an editor offers to collapse — the import
block at the top of the file, then every declaration and every method:

```console
$ komp query folding --file src/point.kf
{"schema_version":1,"file":"src/point.kf","ranges":[{"byte_start":0,"byte_end":33,"kind":"region"}]}
```

Offsets are byte offsets into the file, zero-based and end-exclusive, the
same convention `--diagnostic-format=json` uses. They are not line and
column numbers because only the client knows the position encoding it
negotiated; converting is the plugin's job, and both editor plugins
already do it.

Symbol kinds are KFlat's words, not any protocol's numbers: `function`,
`method`, `struct`, `enum`, `variant`, `field`, `trait`, `impl`, `extern`,
`type`. A declaration that failed to parse is left out — it names nothing
to navigate to.

`hover` reports the type of the innermost expression covering a byte
offset — narrowest, so hovering `a` inside `f(a + 1)` answers about `a`
rather than about the call:

```console
$ komp query hover --file src/main.kf --offset 195
{"schema_version":1,"file":"src/main.kf","offset":195,"type":"int32","byte_start":195,"byte_end":200}
```

`type` is null when the offset covers no expression — whitespace, a
keyword, a comment, a binder's name. That is not an error; most of a file
is not an expression.

`inlays` reports the types nobody wrote down: one hint per `val`/`var` with
no written annotation, at the byte where its name ends.

```console
$ komp query inlays --file src/main.kf
{"schema_version":1,"file":"src/main.kf","inlays":[{"byte_offset":133,"label":": int32"},{"byte_offset":159,"label":": List<int32>"}]}
```

A type is rendered the way its author would write it — `List<int32>`, not
the mangled name it links under.

`selection` returns what expand-selection grows through: the chain of
spans covering an offset, innermost first, ending at the whole
declaration.

```console
$ komp query selection --file src/main.kf --offset 91
{"schema_version":1,"file":"src/main.kf","offset":91,"ranges":[{"byte_start":91,"byte_end":92},{"byte_start":91,"byte_end":96},{"byte_start":43,"byte_end":98}]}
```

It parses rather than checks — growing a selection needs where things are,
not what they are. There is no step for the enclosing statement, because a
statement's span is its leading keyword rather than its extent; the chain
goes from the outermost expression straight to the declaration.

`signature` reports the callee's parameters and which one the cursor is
in, for the innermost call around it:

```console
$ komp query signature --file src/main.kf --offset 143
{"schema_version":1,"file":"src/main.kf","offset":143,"label":"add(a: int32, b: int32): int32","parameters":[{"label":"a: int32"},{"label":"b: int32"}],"active_parameter":1}
```

`label` is null when the offset is not inside a call, or inside one whose
callee the crate does not declare. The active index counts the commas
directly inside the call — one in a nested call or inside a string
separates nothing — so it keeps working while the argument being typed is
not yet parseable, which is when it is worth having.

`references` reports every use of whatever the offset names, and where it
was declared. Each entry carries its own file — a reference reaches across
the crate, and the file the question was asked about is rarely the only
answer.

```console
$ komp query references --file src/lib.kf --offset 90
{"schema_version":1,"file":"src/lib.kf","offset":90,"declaration":{"file":"src/lib.kf","byte_start":4,"byte_end":10},"references":[{"file":"src/lib.kf","byte_start":90,"byte_end":96},{"file":"src/other.kf","byte_start":36,"byte_end":42}]}
```

Every span is a NAME. The declaration is `helper`, not the `fun` that
opens its line, and a reference is the callee, not the whole call — a
call's span covers its arguments so that `signature` can find the call
around a cursor, which is the wrong extent to select or to colour.

The offset may sit on the declaration's own name or on any use of it; both
answer the same thing. The declaration is reported once, as `declaration`,
and is not repeated in `references`, which are the uses.

Only top-level declarations answer. A parameter or a local resolves
through the typechecker's own scope, which the resolver does not build, so
the cursor on one reports nothing rather than guessing from spelling.

`tokens` reports every name in the file with what it actually is, which is
what semantic highlighting paints:

```console
$ komp query tokens --file src/lib.kf
{"schema_version":1,"file":"src/lib.kf","tokens":[{"byte_start":41,"byte_end":42,"type":"variable"},{"byte_start":84,"byte_end":93,"type":"function"}]}
```

Roles are `variable`, `function`, `method`, `field`, `type`. Tokens arrive
sorted by position, because the delta encoding a client uses is meaningless
out of order.

`completion` reports what can follow a `.` — the fields and instance
methods of whatever the receiver's type turned out to be:

```console
$ komp query completion --file src/lib.kf --offset 398
{"schema_version":2,"file":"src/lib.kf","offset":398,"prefix":"","receiver_type":"Point","items":[{"label":"x","kind":"field","detail":"int32"},{"label":"sum","kind":"method","detail":"sum(): int32"}]}
```

Where the receiver ends is a question about the TEXT, not the tree: the
cursor sits after a `.` and possibly after a partly-typed member name,
neither of which parses while it is being written. So komp scans back over
the name bytes, expects a `.`, and asks the checker what the byte before it
belongs to. `prefix` reports the partial name back; a client filters on its
own, but a CLI answer that shows what it matched against is easier to check
by hand.

Off a member position the same endpoint answers with the names **in scope**
at that offset, and `receiver_type` is null because there is no receiver to
name:

```console
$ komp query completion --file src/lib.kf --offset 271
{"schema_version":2,"file":"src/lib.kf","offset":271,"prefix":"","receiver_type":null,"items":[{"label":"seed","kind":"parameter","detail":"int32"},{"label":"total","kind":"local","detail":"int32"},{"label":"Point","kind":"struct","detail":""},{"label":"println","kind":"function","detail":"(v: T): void"}]}
```

Innermost first: locals live at that point, then the enclosing function's
parameters and `self`, then the crate's own declarations, then what this
file's imports make visible — gated by the same per-file import map the
checker uses, so the list is what would actually compile here. `kind` is
one of `local`, `parameter`, `function`, `struct`, `enum`, `trait` for a
scope answer and `field` or `method` for a member one.

`@test` functions are left out. `komp test` synthesizes a main that calls
each one and no source ever writes the name, so they are names that compile
and that nobody types — and a crate can hold more of them than of anything
else, which buries what a reader is reaching for.

**Live at that point**, not present in the function: a local declared below
the cursor is not offered, and neither is one declared inside a block the
cursor is not in. Offering either would be worse than offering nothing,
because a completion list looks authoritative and the reader finds out at
build time.

`receiver_type` is null with **no items** in one case only: the offset is
in a member position but the receiver has no type the checker could name. A
completion list built from spelling would be worse than none.

A `static fun` is left out: it takes no receiver, so offering it after `p.`
would suggest code that does not compile. Members of a generic are reported
as the declaration writes them — `push(item: T)` rather than
`push(item: int32)` on a `List<int32>` — since substituting the instance's
arguments back through a signature is its own job.

Scope completion — the names visible at an offset with no receiver — is not
answered yet. It needs to know which bindings are live at a position rather
than in the function overall.

`rename` is find-references plus the reasons to refuse. `--new-name` says
what to call it:

```console
$ komp query rename --file src/lib.kf --offset 8 --new-name scaled
{"schema_version":1,"file":"src/lib.kf","offset":8,"new_name":"scaled","ok":true,"error":null,"range":{"file":"src/lib.kf","byte_start":8,"byte_end":14},"edits":[{"file":"src/lib.kf","byte_start":8,"byte_end":14},{"file":"src/lib.kf","byte_start":133,"byte_end":139},{"file":"src/other.kf","byte_start":40,"byte_end":46}]}
```

`edits` is every span to replace, the declaration's own name included —
unlike `references`, which reports the declaration separately because a
declaration is not a use of itself. A rename has to touch both.

The edits are not the hard part. A rename that changes which declaration a
name refers to still compiles and no longer means what it did, and no
diagnostic will mention it — so `ok` is false, with a reason in `error` and
an empty `edits`, when:

| | |
|---|---|
| the new name is not one | it must lex as a single identifier, so a keyword, a leading digit, two words and trailing punctuation are all refused |
| the new name is taken | another top-level declaration in the crate already has it |
| the new name is the old one | that is not a rename |
| the offset is not on a name | a keyword or whitespace resolves to no declaration |
| the declaration is not yours | it is in a dependency; rename it where it is declared |

That last one matters more than it looks. The assembled crate holds every
dependency's declarations — which is what lets `references` reach across a
boundary — so without the check, renaming a use of `println` would edit the
standard library.

Omitting `--new-name` runs every check that does not need one and answers
with `range`, the name under the cursor. An editor asks whether a rename is
possible before it asks the user what to call it, and that question has no
new name to give.

Collisions are checked crate-wide rather than per reference site. The
resolver stamps only top-level declarations, so a local shadowing the new
name at some use is not visible — which is why rename declines on locals
entirely rather than pretending to check them.

An unknown question is an error, reported in the same JSON shape a
diagnostic uses:

```console
$ komp query refs --file src/point.kf
{"schema_version":1,"severity":"error","message":"unknown query `refs`; known queries: symbols, folding, hover, inlays, selection, signature, references, tokens, completion, rename","byte_start":0,"byte_end":0,"file":null,"line":null,"column":null}
```

A file komp cannot read answers the same as an empty one — with no symbols
and no ranges — rather than failing. A typed query on a file with no
`kf.toml` above it does fail: without a crate there is nothing to check it
against, and answering from a file checked alone would report every
imported name as missing.

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
never reads `kf.toml`: komp passes each row of the `[lint]` table as
`--lint NAME=LEVEL`, reported as the table's own row when it is wrong. `-q`,
`--deny-warnings` and `-A/-W/-D <lint>` mean what they mean to komp, which
passes its own along.

With `--tests` in place of `--bin`, `kflatc compile` instead compiles the crate
with its `_test.kf` files and a generated test main, and writes
`test/<name>_tests.h` and `.c` under `--out`, reporting no warnings. This is
the translation unit `komp test` compiles and links into the test binary.

`kflatc check` takes the same arguments, plus `--json` for newline-delimited
JSON diagnostics, and type-checks the crate with its `_test.kf` files, writing
nothing. `komp check` first brings each dependency's interface up to date with
`kflatc compile`, marking it with a `.kfi.stamp` so the next check reuses it,
then runs `kflatc check` on the root.

`kflatc unity --crate NAME=ROOT... --out FILE` compiles a whole project into
one C file, as `komp build --unity` needs: each `--crate` names a crate and its
source root, dependencies first and the root last. `--bin` and `--tests` mean
what they do to `compile`. The crates' own C sources are left out; komp
appends them.

`kflatc version` prints what komp needs to know about the compiler it runs, one
`key value` line each after the first: its interface `abi`, `runtime` and
`target`. An artifact records these and the kflatc binary's own hash, so
replacing kflatc rebuilds every crate.

`kflatc serve` keeps the compiler running and answers JSON requests on its
standard input, for editors and other tools; its protocol is
[its own chapter](serve.md).

`kflatc query` is what answers `komp query`. komp passes its arguments
through, adding a `--crate NAME=ROOT` for each crate of the project around
`--file`, dependencies first, as `unity` takes them.

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
| `--offline` | Fail rather than fetch a dependency |

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

