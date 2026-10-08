# Installing komp

komp and the compiler it runs, `kflatc`, are released separately. komp is
released as a static binary for Linux on x86-64 and on ARM64. Each kflat
release is a toolchain: `kflatc` as C, with the libraries it compiles against
and an install script that builds it. The package index lists those releases
as `kflatc`. Building a toolchain needs a C compiler (gcc or clang), as komp
does for every program.

## Installing

```console
$ curl -fsSL https://github.com/komp-co/komp/releases/latest/download/install.sh | sh
installed komp 1.0.0 as /home/me/.kflat/bin/komp
building kflatc 0.28.0 with cc
installed kflat 0.28.0; /home/me/.kflat/bin/kflatc now runs it
add /home/me/.kflat/bin to PATH, for example in your shell profile:
    export PATH="/home/me/.kflat/bin:$PATH"
```

The script downloads komp's release for this machine, checks it against the
sha256 published beside it, and puts it in `~/.kflat/bin`. When there is no
`kflatc` there yet, it then runs
[`komp toolchain install`](../tools/cli.md#komp-toolchain), which builds the
newest toolchain into `~/.kflat/toolchains/<version>/`, with `core`, `alloc`
and `std` in `libs/` beside it, and links `~/.kflat/bin/kflatc` to it.
[`komp tool install`](../tools/cli.md#komp-tool) puts programs in the same
`bin` directory, so it is the one directory to put on `PATH`. `KFLAT_HOME`
moves all of it somewhere other than `~/.kflat`, and `KOMP_VERSION` installs
another komp release than the newest.

## Updating

```console
$ komp self update
installed komp 1.0.1 as /home/me/.kflat/bin/komp
$ komp toolchain install
installed kflat 0.29.0; /home/me/.kflat/bin/kflatc now runs it
```

[`komp self update`](../tools/cli.md#komp-self-update) replaces komp, and
`komp toolchain install` adds the newest toolchain and makes it the default.
Toolchains already installed stay, for the projects that
[pin](projects.md#pinning-the-toolchain) them. komp drives every kflatc from
0.6.0 on, so either can move without the other.

A komp from before komp was released on its own updates with
`komp toolchain install`, which then runs the install script above: the
`kflatc` that komp ran stays the default.

## Building komp from its source

komp is a KFlat program, built with the toolchain its `kf.toml` pins:

```console
$ komp build .
$ target/kflat/komp --version
komp 1.0.0
```

A komp built this way looks for `kflatc` in its own directory, or wherever
`KFLATC` points, and for the libraries in `libs/` beside that compiler's
directory.

## Why C

The compiler emits C. C toolchains (gcc, clang) target every architecture:
x86, ARM, RISC-V, AVR, bare-metal kernels. A C backend buys platform coverage
that a custom code generator would take years to reach. The C output is not a
temporary step toward a native backend — it is the strategy.
