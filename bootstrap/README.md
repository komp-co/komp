# Bootstrap

komp is written in KFlat, so building it needs a KFlat compiler. The **seed**
breaks that loop: a released komp and kflatc, translated to C, which any C
compiler can build.

```sh
sh bootstrap/build.sh
```

`stage0.toml` pins the seed: a release version, the URL of its
`kflat-seed-<version>.tar.gz`, and that file's sha256. `seed.sh` fetches it
once into `~/.cache/kflat/seeds` and verifies it on every use;
`KFLAT_SEED=<tarball>` uses a local one instead.

## How it works

```
cc the seed                     -> komp0, with its kflatc beside it
komp0 builds compiler/komp      -> stage1.c ; cc -> komp1
komp0 builds compiler/kflatc    -> kflatc1.c ; cc -> kflatc beside komp1
komp1 builds both again         -> stage2.c, kflatc2.c
assert stage1 == stage2         # the fixpoint
```

The fixpoint, byte for byte, is the single test that guards the whole
compiler: if komp can no longer reproduce itself, this fails.

stage1.c is the *seed's* output. A tree that changes what the compiler emits
for its own source cannot match it, so then the chain runs once more:

```
cc stage2.c, kflatc2.c          -> komp2, with its kflatc beside it
komp2 builds both again         -> stage3.c, kflatc3.c
assert stage2 == stage3         # the fixpoint
```

Either way the fixpoint is two compilers built from the same source agreeing,
and `--seed-out` packs the pair that proved it.

## A new seed

The seed only has to *build* the current source, so it can lag. A new one
comes from a release: a PR from `development` into `main` that raises
`kflat_version()`. Merging it runs the release workflow, which builds the seed
from the pinned one, checks the fixpoint, and publishes
`kflat-seed-X.Y.Z.tar.gz` with its sha256 under the tag `vX.Y.Z`, then opens
the PR that pins it in `stage0.toml`. CONTRIBUTING.md has the whole release.

To try a seed before releasing it:

```sh
sh bootstrap/build.sh --seed-out /tmp/seed
KFLAT_SEED=/tmp/seed/kflat-seed-X.Y.Z.tar.gz sh bootstrap/build.sh
```
