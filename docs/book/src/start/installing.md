# Installing komp

You need a C compiler (gcc or clang). Each release publishes
`kflat-<version>.tar.gz`: komp and `kflatc`, the compiler it runs for each
crate, as C, with the libraries they compile against and an install script.

## Installing a release

```console
$ tar -xzf kflat-0.5.1.tar.gz
$ sh kflat-0.5.1/install.sh
building komp 0.5.1 with cc
building kflatc 0.5.1 with cc
installed kflat 0.5.1 in /home/me/.kflat/toolchains/0.5.1
add /home/me/.kflat/bin to PATH, for example in your shell profile:
    export PATH="/home/me/.kflat/bin:$PATH"
```

The script builds both with `cc`, or the compiler `CC` names, and puts them
in `~/.kflat/toolchains/<version>/` with `core`, `alloc` and `std` in `libs/`
beside them. `komp` and `kflatc` are linked into `~/.kflat/bin`, the same
directory [`komp install`](../tools/cli.md#komp-install) puts programs in, so
it is the one directory to put on `PATH`. `KFLAT_HOME` moves all of it
somewhere other than `~/.kflat`. Installing a version again replaces it;
other versions stay where they are.

## Building from the seed

To build komp from a checkout of its source instead:

```console
$ KOMP_PUBLISH=out/komp sh bootstrap/build.sh
[1/4] cc the seed, kflat 0.5.0 -> komp0, kflatc
[2/4] komp0 compiler/komp -> stage1.c ; cc stage1.c -> komp1
      komp0 compiler/kflatc -> kflatc1.c ; cc kflatc1.c -> kflatc
[3/4] komp1 compiler/komp -> stage2.c ; compiler/kflatc -> kflatc2.c
[4/4] fixpoint check
OK: stage1.c == stage2.c and kflatc1.c == kflatc2.c (fixpoint holds)
OK: published the verified komp and kflatc to out
      checking that kflat-0.5.0.tar.gz installs
OK: kflat-0.5.0.tar.gz installs, and the installed komp builds a program
```

`KOMP_PUBLISH` names where the verified `komp` goes, with `kflatc` beside it.
Keep the two together: komp looks for `kflatc` in its own directory, or
wherever `KFLATC` points.

The chain:

1. The seed is fetched once into `~/.cache/kflat/seeds`, checked against the
   sha256 in `bootstrap/stage0.toml`, and compiled → komp0 and its kflatc
2. komp0 builds `compiler/komp` and `compiler/kflatc` → stage1 C → komp1 and
   the kflatc beside it
3. komp1 builds both again → stage2 C
4. Assert stage 1 == stage 2 byte-for-byte (the fixpoint)

The fixpoint is the proof: a compiler that can reproduce its own C output
exactly is self-hosting. The seed is a past compiler's output — enough for a
first build, but not proof by itself.

With no network, download the seed tarball from the release
`bootstrap/stage0.toml` names and point `KFLAT_SEED` at it.

## Why C

The compiler emits C. C toolchains (gcc, clang) target every architecture:
x86, ARM, RISC-V, AVR, bare-metal kernels. A C backend buys platform coverage
that a custom code generator would take years to reach. The C output is not a
temporary step toward a native backend — it is the strategy.

## Putting a built komp on PATH

A komp built from the seed looks for `kflatc` in its own directory, and for
the libraries in `libs/` beside that directory. Run it from where the build
put it, or install a release as above.
