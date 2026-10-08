# Projects and kf.toml

Every KFlat program lives inside a project directory. The only mandatory file
is `kf.toml` — it tells komp the crate name, version, and what kind of output
to produce.

## Creating a project

```console
$ komp new my-project
$ ls my-project
kf.toml  src/

$ komp new    # in an existing directory — scaffolds it in place
```

Both write the same two files:

### kf.toml

```toml
[project]
name = "my_project"
version = "0.1.0"
kind = "bin"
```

The name is derived from the directory's own name, the last component of the
path you give: hyphens become underscores (`komp new work/my-project` →
`my_project`), because the crate name becomes a C identifier.

A library published to an index can say what it is in one line, which
[`komp search`](../tools/cli.md#komp-search-and-komp-info) shows beside it:

```toml
[project]
name = "json"
version = "0.2.0"
kind = "lib"
description = "JSON reading and writing"
```

### kind: library vs binary

| `kind` | Entry point | Output |
|---|---|---|
| `"bin"` | Must have `fun main()` in the crate | Executable binary |
| `"lib"` | No main required | Shared or static library |

An executable needs `fun main(): void` (or `int32`). A library crate has no
entry point and can only be used as a dependency.

### A library and a program in one package

A tool that also offers a library declares both with a `[lib]` and a `[bin]`
section in place of `kind`:

```toml
[project]
name = "greeter"
version = "0.1.0"

[lib]

[bin]
```

The library's sources are under `src/lib/` and the program's under `src/bin/`.
They are two crates. The library takes the package's name; the program is the
crate `greeter_bin`, depends on the library, and imports it like any
dependency:

```
src/
  lib/
    greet.kf       # module `greeter`
  bin/
    main.kf        # module `greeter_bin`
```

```kflat
import greeter.greet.greeting

fun main(): int32 {
    println(greeting("world"))
    return 0
}
```

- `komp build` and `komp run` build the program, and the binary is named after
  the package: `target/kflat/greeter`. `komp tool install greeter` installs it.
- A package that depends on `greeter` gets the library; the program is not
  built for it.
- `komp test`, `komp check`, `komp lint` and `komp fix` work on the library,
  then the program, each with its own `_test.kf` files.

A section alone also works: `[lib]` holds a library in `src/lib/`, `[bin]` a
program in `src/bin/`. Giving `kind` as well as a section is an error.

`[lib]` may name the library crate, which is otherwise the package's name;
dependents depend on the package and import the crate:

```toml
[project]
name = "komp_test"

[lib]
name = "testing"

[bin]
```

### src/main.kf

The generated template for a binary crate:

```kflat
fun main(): int32 {
    println("Hello, world!")
    return 0
}
```

## The src/ layout

Every `.kf` file under `src/` is part of the crate. Each directory is a
module, and the files of one directory share one scope:

```
src/
  main.kf          # module `app`, the crate root
  data.kf          # module `app`: shares main.kf's scope
  util/
    format.kf      # module `app.util`
```

A module's name is the crate's name followed by its directories. A function
from another module must be `pub`, and is imported by that name:

```kflat
import app.util.*
```

Imports are always `import`, never `use`. They appear before any declarations.

## Dependencies

To depend on another crate, add a `[dependencies]` section with a path:

```toml
[project]
name = "app"
version = "0.1.0"
kind = "bin"

[dependencies]
my_lib = { path = "../my_lib" }
```

The key (left of `=`) is how the dependency is imported in KFlat source:

```kflat
import my_lib.*
```

The path is relative to the `kf.toml` that declares it.

### Versions from an index

A dependency written as a version comes from a package index:

```toml
[dependencies]
json = "0.1"
yaml = { version = "0.3", index = "work" }

[indexes]
work = "https://git.example.org/kflat-index"
```

A version requirement allows every later version that keeps its leftmost
non-zero part: `"1.4"` means at least 1.4.0 and below 2.0.0, `"0.2"` at least
0.2.0 and below 0.3.0, and `"0.0.3"` exactly 0.0.3. komp picks the highest
version the requirement allows that has not been yanked.

Without an `index` key the requirement goes to the default index,
[komp-co/index](https://github.com/komp-co/index), or to `$KFLAT_INDEX` when
that is set. `[indexes]` names any other one; an index is a git repository,
so a private one is a private repository. `komp publish` adds a library to
one; see [komp publish](../tools/cli.md#komp-publish).

The index is read only to choose a version. What was chosen is fetched like
any other remote dependency and pinned in `kf.lock`, which also records the
index, so a build with a lock never reads the index at all.

`komp add json` writes such a row for you, at the newest version, and fetches
it; [`komp search`](../tools/cli.md#komp-search-and-komp-info) finds what an
index offers. See [komp add](../tools/cli.md#komp-add).

### Fetched dependencies

A dependency can also come from a git repository or a tarball, on any host:

```toml
[dependencies]
json = { git = "https://github.com/komp-co/json" }
text = { git = "https://git.example.org/text.git", tag = "v1.2.0" }
yaml = { tarball = "https://example.org/yaml-0.3.0.tar.gz", checksum = "sha256:9f86d0…" }
```

A `git` source takes at most one of `tag`, `branch` or `rev` (a commit,
abbreviated or not). Without one, it follows the repository's default branch.
A `tarball` may carry the sha256 of the archive, which the download must
match. The crate is at the archive's root, or inside its one top-level
directory, as release archives lay it out. Each row names exactly one of
`path`, `git` or `tarball`.

Before `build`, `run`, `check`, `test` or `fix`, komp fetches whatever is new
into its cache, `$KFLAT_CACHE` or else `~/.cache/kflat`, and records exactly
what it got in `kf.lock` beside `kf.toml`:

```toml
[[package]]
name = "json"
version = "0.1.0"
source = { git = "https://github.com/komp-co/json", rev = "f1bd0aee61045540f52524d793c075cbb091cb2e" }
```

Commit `kf.lock`. While it has a row for a dependency, every build uses that
commit or that archive, from the cache, without the network, even after the
branch or tag has moved or a newer version has been published. `komp update`
resolves every dependency again and rewrites the lock. `--locked` makes a command fail rather than change
`kf.lock`, and `--offline` makes it fail rather than fetch; CI wants both.
A package index is a git checkout in the cache, brought up to date once per
command. When that update fails, as it can while another komp updates the
same checkout, komp says so and reads the index as it was last fetched.

A fetched crate's `core`, `alloc` and `std` are always the ones bundled with
komp, whatever path its own manifest gives them. A crate name may come from
only one source in a program: two commits of one crate would define the same
symbols, so two requirements no one version satisfies are an error. A
workspace has one `kf.lock`, beside the workspace manifest, which
covers every member.

`core` and `alloc` do not need an entry — the compiler injects them into any
crate that declares no dependencies of its own, and a crate that *does* have
dependencies inherits theirs. `std` needs no entry either: every crate of a
hosted program has it, since its types (`File`, `Dir`, `Env`, …) are named
without an import. A [freestanding](#the-freestanding-tier) program has none. See [std](https://github.com/komp-co/kf-lang/blob/main/docs/book/src/libs/std.md).

A `path` dependency whose directory holds no `kf.toml` is an error naming it,
from every command that reads the dependencies.

### Dev-dependencies

`[dev-dependencies]` takes the same rows as `[dependencies]`, for what the
crate's `_test.kf` files use and its code does not:

```toml
[dev-dependencies]
testing = { path = "../libs/testing" }
```

They are part of the graph only when the tests are: `komp test`, `komp check`,
`komp lint`, `komp fix` and the editor, which all compile the `_test.kf` files.
`komp build` and `komp run` leave them out, and a crate depending on this one
never sees them. komp fetches and locks them like other dependencies. Tests
import [`testing`](https://github.com/komp-co/kf-lang/blob/main/docs/book/src/libs/testing.md), which declares `@test`, so a crate
with tests names it here.

## Workspaces

Several crates that are developed together can share one workspace: a
`kf.toml` with a `[workspace]` section instead of `[project]`, in the directory
above them.

```toml
[workspace]
members = ["app", "geometry"]
default-member = "app"
```

`members` lists the crate directories, relative to the workspace. A member
depends on another through an ordinary path dependency:

```toml
[project]
name = "app"
kind = "bin"

[dependencies]
geometry = { path = "../geometry" }
```

A command run at the workspace root works on `default-member`. `--package`
(or `-p`) picks another member, and `--workspace` picks every member.
`--package` accepts the crate name or the member's directory name, so
`-p kf-core` and `-p kf_core` both work. The flags also work from inside a
member, and a command run from a subdirectory such as `app/src` finds the
nearest `kf.toml` above it.

```console
$ komp run
$ echo $?
6
$ komp check -p geometry
check: OK
$ komp build --workspace
==> komp build ./app
==> komp build ./geometry
```

`--workspace` runs on every member even when one fails, and exits non-zero if
any did. `komp run` and whole-program builds (`--unity`, `-o`) work on a single
crate, so they accept `--package` but not `--workspace`. A workspace without
`default-member` does not guess:

```console
$ komp build
error: workspace `/home/me/shapes` has no default-member: add one, or pass `--package <name>` or `--workspace`
```

Members build into one shared `target/kflat` next to the workspace manifest, so
a dependency used by several members is compiled once. The members' own
directories get no `target`. Artifacts are named per crate, so members do not
overwrite each other. `target-dir` moves the shared directory; the path is
relative to the workspace:

```toml
[workspace]
members = ["app", "geometry"]
default-member = "app"
target-dir = "../build"
```

A crate belongs to the workspace only if `members` lists it. A crate that just
sits in a subdirectory keeps its own `target`.

Several komp processes can build into the same target at the same time, for
example an editor's `komp check` while a build runs in a terminal. komp writes
each artifact under a temporary name and renames it into place, so a reader
never sees a half-written file.

## Pinning the toolchain

`kflat` in `[project]` pins the release a project builds with, as a version
requirement read the way a dependency's is:

```toml
[project]
name = "app"
version = "0.1.0"
kflat = "0.4"
```

komp builds with the default kflatc, the one beside it, when the requirement
allows its version.
Otherwise it builds with the highest toolchain under `~/.kflat/toolchains`
that the requirement allows, with that toolchain's `core`, `alloc` and `std`.
`komp metadata` names the compiler it chose, so tools that ask komp use it
too.

When none installed fits, komp installs one before building: the newest
release the requirement allows, of those the package index lists as
[`kflatc`](../tools/cli.md#komp-toolchain). It goes into
`~/.kflat/toolchains` beside the others, and the default `kflatc` stays the
one it was. With `--offline` komp installs nothing and
stops instead:

```console
$ komp build --offline
error: kf.toml pins kflat 0.7: the default kflatc is 0.6.0 and no installed toolchain fits; --offline installs none
```

komp drives kflatc 0.6.0 and newer, the releases whose command line matches
its own. A requirement that allows none of them stops the build, whatever is
installed:

```console
$ komp build
error: kf.toml pins kflat 0.5, older than the oldest kflatc this komp drives (0.6.0); pin a newer release, or build with a komp from that one
```

A `KFLATC` older than that is refused the same way, by name.

In a workspace, `kflat` goes in `[workspace]` and pins every member; a
member's own is not read. `KFLATC`, when set, wins over any pin.

## Pinning tools

`[tools]` pins the programs a project runs through komp, such as the
formatter, written as dependencies are:

```toml
[tools]
komp_fmt = "0.1"
komp_doc = { version = "0.3", index = "work" }
```

Inside the project, `komp fmt` runs the highest version of `komp_fmt` that
`"0.1"` allows among those installed, and installs one the first time none
does; elsewhere it runs the default [`komp tool install`](../tools/cli.md#komp-tool)
made. Versions sit side by side in `~/.kflat/tools`, each built once, so a
project on 0.1 and a default of 0.2 each run their own. In a workspace,
`[tools]` goes in the root `kf.toml` and pins every member.

## Native C sources

If a crate ships C alongside KFlat, list the sources under `[native]`:

```toml
[native]
c_sources = ["src/wrapper.c", "src/helper.c"]
```

These are compiled and linked into the final binary. Any KFlat function
declared `extern "C"` can call them and be called by them. See
[unsafe, extern, and C interop](https://github.com/komp-co/kf-lang/blob/main/docs/book/src/lang/unsafe.md).

### The freestanding tier

Some of a crate's C only works where there is a C library behind it — a
console to print to, a heap to allocate from, a process that can fork.
Listing it separately says so:

```toml
[native]
c_sources        = ["native/core.c"]
hosted_c_sources = ["native/core_hosted.c"]
```

Both halves compile in an ordinary build. A program that is going somewhere
with no operating system says so in its own manifest:

```toml
[project]
name = "blinky"
kind = "bin"
freestanding = true
```

and then **no** crate's `hosted_c_sources` is compiled — not the program's,
and not any dependency's. That last part is the point of putting the flag on
the program rather than on each crate: `core` cannot know whether the thing
linking it has a `stdout`, so the program has to be the one that answers.

What komp emits is already freestanding. It includes `<stdint.h>`,
`<stdbool.h>` and `<stddef.h>` — the three C guarantees a freestanding
implementation provides — and routes every allocation through the
[allocation seam](https://github.com/komp-co/kf-lang/blob/main/docs/book/src/libs/core.md). So a freestanding build of a program
compiles with no C library present at all:

```console
$ komp blinky blinky.c
$ cc -c -ffreestanding -nostdinc -isystem "$(cc -print-file-name=include)" blinky.c
```

Linking is where the program has to answer for itself. The symbols the
hosted half would have defined are now undefined, and the linker names any
that were left out:

| symbol | what the program has to say |
|---|---|
| `kf_try_alloc`, `kf_try_realloc`, `kf_free` | where memory comes from |
| `panic` | how this target stops |
| `runtime_print`, `runtime_println` | where bytes go, if anywhere |

That is the intended diagnostic. The alternative is a program that builds
and then fails on a target that never had a `stdout` to begin with.

Freestanding is a build profile, so artifacts built one way are never reused
for the other — `libcore.a` compiled for a hosted program is a different
archive from the same source compiled for a freestanding one.
