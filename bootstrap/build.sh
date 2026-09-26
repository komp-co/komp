#!/usr/bin/env sh
# Bootstrap komp from the released seed and verify the self-hosting fixpoint.
# Needs a C compiler, and the network once to fetch the seed.
#
#   bootstrap/build.sh                   # build + fixpoint check
#   bootstrap/build.sh --seed-out DIR    # ... and write this tree's seed to DIR
#   KFLAT_SEED=seed.tar.gz bootstrap/build.sh   # start from a local seed
#   CC=clang bootstrap/build.sh          # pick a C compiler (default: cc)
#   CFLAGS=-O0 bootstrap/build.sh        # cheaper cc, a far slower komp
#
# The seed is a released komp and kflatc as C, pinned by bootstrap/stage0.toml
# and verified by its sha256; bootstrap/seed.sh fetches and caches it.
#
# Chain:
#   1. cc the seed                    -> komp0, with its kflatc beside it
#   2. komp0 builds compiler/komp     -> stage1.c ; cc stage1.c -> komp1
#      komp0 builds compiler/kflatc   -> kflatc1.c ; cc -> kflatc, beside komp1
#   3. komp1 builds compiler/komp     -> stage2.c, running that kflatc
#      komp1 builds compiler/kflatc   -> kflatc2.c
#   4. assert stage1.c == stage2.c and kflatc1.c == kflatc2.c (the fixpoint)
#
# stage1.c is the seed's output, so a tree that changes what the compiler
# emits for its own source cannot match it. Then komp2 and kflatc2 are built
# from stage2.c and kflatc2.c, build the tree once more, and the fixpoint is
# stage2.c == stage3.c and kflatc2.c == kflatc3.c: two compilers from the same
# source agree.
#
# `--seed-out` packs the pair the fixpoint just proved as
# kflat-seed-<version>.tar.gz. A release publishes that file.
#
# Each step fails for its own reason, named with its remedy.
#
# Exit non-zero if any stage or the fixpoint fails. Run this in CI.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CC="${CC:-cc}"
CFLAGS="${CFLAGS:--O2}"

SEED_OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --seed-out) [ $# -ge 2 ] || { echo "usage: $0 [--seed-out DIR]" >&2; exit 2; }; SEED_OUT="$2"; shift ;;
        *) echo "usage: $0 [--seed-out DIR]" >&2; exit 2 ;;
    esac
    shift
done
. "$ROOT/bootstrap/seed.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# fail HEADLINE [DETAIL...] — one FAIL: line, then indented remedy lines.
fail() {
    echo ""
    echo "FAIL: $1"
    shift
    for line in "$@"; do
        echo "  $line"
    done
    exit 1
}

# A tool killed by a signal did not reject anything. 137 is SIGKILL, on a
# build machine almost always the OOM killer: this script's peak is one whole
# self-compile.
#
# Call with the exit status of the tool that just failed; returns 0 when it
# named a signal, having already explained it.
report_if_killed() {
    status="$1"
    stage="$2"
    if [ "$status" -le 128 ]; then
        return 1
    fi
    echo ""
    echo "FAIL: $stage was killed by signal $((status - 128))."
    if [ "$status" -eq 137 ]; then
        echo "  SIGKILL, and nothing here sends it — this is the machine, not"
        echo "  your source. bootstrap/build.sh peaks at roughly one whole"
        echo "  self-compile; check free memory, and whether another build or"
        echo "  CI job was running at the same time."
    fi
    exit 1
}

echo "[1/4] $CC the seed, kflat $(seed_field version) -> komp0, kflatc"
if ! seed_build "$WORK/s0"; then
    fail "the seed did not build." \
         "Either it could not be fetched or verified (the lines above say which)," \
         "or it does not compile with $CC: it is generated C that a working komp" \
         "emitted, so a failure there is about the C toolchain, not your source."
fi

# Absolute project root: a seed older than the walk_project dedup fix
# (abs_path.kf) assembles shared crates twice when the root is relative.
echo "[2/4] komp0 compiler/komp -> stage1.c ; $CC stage1.c -> komp1"
stage1_status=0
"$WORK/s0/komp0" "$ROOT/compiler/komp" "$WORK/stage1.c" || stage1_status=$?
if [ "$stage1_status" -ne 0 ]; then
    report_if_killed "$stage1_status" "the seed reading the current source" || true
    fail "the seed rejected the current source." \
         "The errors above come from komp0 — the seed binary — reading" \
         "compiler/komp. Either the source is genuinely broken, or it uses a" \
         "construct the pinned seed predates. Build with a current komp to" \
         "tell the two apart: if that succeeds, the seed is the problem." \
         "See \"The bootstrap seed\" in CONTRIBUTING.md."
fi
# From inside `$WORK`, so its random name stays out of the hashed command line.
if ! (cd "$WORK" && "$CC" $CFLAGS -c -o stage1.o stage1.c) || ! "$CC" $CFLAGS -o "$WORK/komp1" "$WORK/stage1.o"; then
    fail "the seed cannot build this tree." \
         "The errors above are in stage1.c — the seed's *output*, not your" \
         "source. The seed miscompiles something this tree now depends on," \
         "typically a codegen defect fixed after it was released. Land the fix," \
         "release it, and pin the new seed before the change that needs it." \
         "See \"The bootstrap seed\" in CONTRIBUTING.md."
fi

# komp1 compiles through the kflatc beside it, which the seed builds here.
echo "      komp0 compiler/kflatc -> kflatc1.c ; $CC kflatc1.c -> kflatc"
kflatc1_status=0
"$WORK/s0/komp0" "$ROOT/compiler/kflatc" "$WORK/kflatc1.c" || kflatc1_status=$?
if [ "$kflatc1_status" -ne 0 ]; then
    report_if_killed "$kflatc1_status" "the seed reading compiler/kflatc" || true
    fail "the seed rejected compiler/kflatc." \
         "It accepted compiler/komp, which holds the same compiler, so look at" \
         "compiler/kflatc itself."
fi
if ! (cd "$WORK" && "$CC" $CFLAGS -c -o kflatc1.o kflatc1.c) || ! "$CC" $CFLAGS -o "$WORK/kflatc" "$WORK/kflatc1.o"; then
    fail "the seed cannot build kflatc; see the stage1.c advice above."
fi

echo "[3/4] komp1 compiler/komp -> stage2.c ; compiler/kflatc -> kflatc2.c"
stage2_status=0
"$WORK/komp1" "$ROOT/compiler/komp" "$WORK/stage2.c" || stage2_status=$?
if [ "$stage2_status" -ne 0 ]; then
    report_if_killed "$stage2_status" "the freshly built compiler reading this tree" || true
    fail "the compiler this tree builds cannot compile this tree." \
         "komp1 came from the current source and step 2 proved the seed can" \
         "build it, so the seed is not implicated: this is a regression in the" \
         "tree itself. Releasing a seed from it would only bake it in."
fi

kflatc2_status=0
"$WORK/komp1" "$ROOT/compiler/kflatc" "$WORK/kflatc2.c" || kflatc2_status=$?
if [ "$kflatc2_status" -ne 0 ]; then
    report_if_killed "$kflatc2_status" "the freshly built compiler reading compiler/kflatc" || true
    fail "the compiler this tree builds cannot compile compiler/kflatc."
fi

echo "[4/4] fixpoint check"
# The compiler that proved the fixpoint and the C it reproduced.
proven_komp="$WORK/komp1"
proven_kflatc="$WORK/kflatc"
proven_komp_c="$WORK/stage1.c"
proven_kflatc_c="$WORK/kflatc1.c"
if ! diff -q "$WORK/stage1.c" "$WORK/stage2.c" >/dev/null || ! diff -q "$WORK/kflatc1.c" "$WORK/kflatc2.c" >/dev/null; then
    echo "NOTE: this tree changes what the compiler emits for itself; checking one stage later"
    mkdir -p "$WORK/s2"
    if ! (cd "$WORK" && "$CC" $CFLAGS -c -o s2/stage2.o stage2.c) || ! "$CC" $CFLAGS -o "$WORK/s2/komp2" "$WORK/s2/stage2.o"; then
        fail "stage2.c, the current compiler's own output, does not compile."
    fi
    if ! (cd "$WORK" && "$CC" $CFLAGS -c -o s2/kflatc2.o kflatc2.c) || ! "$CC" $CFLAGS -o "$WORK/s2/kflatc" "$WORK/s2/kflatc2.o"; then
        fail "kflatc2.c, the current compiler's own output, does not compile."
    fi
    stage3_status=0
    "$WORK/s2/komp2" "$ROOT/compiler/komp" "$WORK/stage3.c" || stage3_status=$?
    "$WORK/s2/komp2" "$ROOT/compiler/kflatc" "$WORK/kflatc3.c" || stage3_status=$?
    if [ "$stage3_status" -ne 0 ]; then
        report_if_killed "$stage3_status" "the self-built compiler reading this tree" || true
        fail "the compiler built by the current compiler cannot compile this tree."
    fi
    if ! diff -q "$WORK/stage2.c" "$WORK/stage3.c" >/dev/null; then
        echo "FAIL: fixpoint broken (stage2.c != stage3.c)"
        echo "  the compiler does not reproduce itself; see diff:"
        diff "$WORK/stage2.c" "$WORK/stage3.c" | head -40
        exit 1
    fi
    if ! diff -q "$WORK/kflatc2.c" "$WORK/kflatc3.c" >/dev/null; then
        echo "FAIL: fixpoint broken (kflatc2.c != kflatc3.c)"
        diff "$WORK/kflatc2.c" "$WORK/kflatc3.c" | head -40
        exit 1
    fi
    proven_komp="$WORK/s2/komp2"
    proven_kflatc="$WORK/s2/kflatc"
    proven_komp_c="$WORK/stage2.c"
    proven_kflatc_c="$WORK/kflatc2.c"
    echo "OK: stage2.c == stage3.c and kflatc2.c == kflatc3.c (fixpoint holds)"
else
    echo "OK: stage1.c == stage2.c and kflatc1.c == kflatc2.c (fixpoint holds)"
fi

# KOMP_PUBLISH names a path to copy the verified komp to, with the kflatc
# beside it, so other jobs can reuse both instead of rebuilding them from the
# seed. Each is written beside its target and renamed, so a reader sees the
# whole binary or none.
if [ -n "${KOMP_PUBLISH:-}" ]; then
    publish_dir="$(dirname "$KOMP_PUBLISH")"
    mkdir -p "$publish_dir"
    cp "$proven_kflatc" "$publish_dir/kflatc.tmp.$$" && mv -f "$publish_dir/kflatc.tmp.$$" "$publish_dir/kflatc"
    cp "$proven_komp" "$KOMP_PUBLISH.tmp.$$" && mv -f "$KOMP_PUBLISH.tmp.$$" "$KOMP_PUBLISH"
    echo "OK: published the verified komp and kflatc to $publish_dir"
fi

# Informational: whether the pinned seed matches the current source. A stale
# seed is harmless until the tree needs something it cannot build.
if diff -q "$proven_komp_c" "$WORK/s0/seed/komp.c" > /dev/null && diff -q "$proven_kflatc_c" "$WORK/s0/seed/kflatc.c" > /dev/null; then
    echo "OK: the seed is current (it matches a fresh self-build)"
else
    echo "NOTE: the seed is behind the current source; a release would catch it up."
fi

if [ -n "$SEED_OUT" ]; then
    version="$("$proven_komp" version | sed -n 's/^komp //p')"
    name="kflat-seed-$version"
    mkdir -p "$WORK/out/$name" "$SEED_OUT"
    cp "$proven_komp_c" "$WORK/out/$name/komp.c"
    cp "$proven_kflatc_c" "$WORK/out/$name/kflatc.c"
    # Byte-identical from identical C: sorted, a fixed date, no owner, gzip -n.
    (cd "$WORK/out" && tar --sort=name --mtime='2000-01-01 00:00Z' --owner=0 --group=0 --numeric-owner -cf - "$name" \
        | gzip -n -9 > "$name.tar.gz")
    cp "$WORK/out/$name.tar.gz" "$SEED_OUT/"
    (cd "$SEED_OUT" && seed_sha256 "$name.tar.gz" | sed "s/\$/  $name.tar.gz/" > "$name.tar.gz.sha256")
    echo "OK: wrote $SEED_OUT/$name.tar.gz"
fi
