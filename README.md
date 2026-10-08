<img src="https://raw.githubusercontent.com/komp-co/kf-extensions/main/brand/kiwi.svg" width="96" alt="The KFlat paper kiwi">

# komp

The project tool for [KFlat](https://github.com/komp-co/kf-lang): `kf.toml`,
dependencies, the crate graph, builds, tests, lints, and the compiler
toolchains it runs. komp is written in KFlat and does not compile KFlat
itself: for each crate it runs `kflatc`, the compiler, which lives in
[komp-co/kf-lang](https://github.com/komp-co/kf-lang), then compiles and links
the C with cc.

## Use it

```sh
komp new hello        # scaffold a project
komp run hello        # build and run
komp check hello      # type-check only
komp test hello       # run its @test functions
```

`komp build` writes per-crate artifacts and links them; `--unity` builds
through a single C file instead. `komp check --fix` applies the repairs the
checker suggests. Every command takes a project directory, one containing a
`kf.toml`, or `--manifest-path`. A project names the compiler it needs with
`kflat = "<version>"`, and komp installs that toolchain when it is missing.

## Build it

Install a released komp and toolchain with
`curl -fsSL https://github.com/komp-co/komp/releases/latest/download/install.sh | sh`.
komp is built with the kflat toolchain `kf.toml`'s `kflat` pin names. With
that toolchain installed:

```sh
komp build .   # target/kflat/komp
```

## Repository layout

| | |
|---|---|
| `kf.toml`, `src/` | komp, one program crate: manifests, fetching, the build graph, `cc`, tests, installs, toolchains |
| `native/` | the C it links |
| `scripts/` | `check.sh` and the ratchets CI runs |
| `docs/book/` | komp's book: installing, projects, the commands |

komp links no part of the compiler. It runs kflatc as a process and talks to
it through kflatc's documented command line; tools that need the resolved
crate graph read `komp metadata`. komp's whole-project tests are its
`integration` module.

## Contributing

```sh
scripts/check.sh                   # build, komp's tests, the CLI checks
CHECK_TESTS=0 scripts/check.sh     # without the tests
CHECK_CLI=0 scripts/check.sh       # without the CLI checks
```

komp depends on the [`json`](https://github.com/komp-co/json) package, and
its tests on [`komp_test`](https://github.com/komp-co/komp-test)'s `testing`,
both from the index, so the first build needs the network.

Work is tracked in [issues](https://github.com/komp-co/komp/issues); compiler
and language issues go to [kf-lang](https://github.com/komp-co/kf-lang/issues).
[`CONTRIBUTING.md`](CONTRIBUTING.md) covers branches and CI;
[`AGENTS.md`](AGENTS.md) has the style, comment, test and commit rules.
