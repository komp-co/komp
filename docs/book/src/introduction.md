# Introduction

komp is the project tool for [KFlat](https://github.com/komp-co/kf-lang): it
reads `kf.toml`, fetches dependencies, works out the crate graph, runs
`kflatc`, the compiler, once per crate, and compiles and links the C it
writes. It also runs tests, lints, formats through installed tools, and
installs and pins compiler toolchains.

The language, its libraries and the compiler are documented in
[kf-lang's book](https://github.com/komp-co/kf-lang/tree/main/docs/book/src).
This book covers komp: installing it, laying out a project, and its
commands.

komp and the compiler are versioned separately. A project names the
compiler it needs with `kflat = "<version>"` in its `kf.toml`, and komp
installs that toolchain when it is missing; see
[Projects and kf.toml](start/projects.md).
