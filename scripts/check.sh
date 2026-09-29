#!/usr/bin/env sh
# What CI runs, locally: the self-hosting fixpoint, the file-size ratchet, CLI
# regressions, and every crate's test suite.
#
#   scripts/check.sh              # fixpoint + CLI checks + full sweep
#   scripts/check.sh --fixpoint   # the self-hosting fixpoint alone
#   scripts/check.sh --sweep      # CLI checks + the crate sweep alone
#   scripts/check.sh --isolated   # ... in a throwaway worktree, so this tree
#                                 # stays usable while it runs
#
# The two halves share no state, so CI runs them as separate jobs. With no
# argument this is every gate CI applies.
#
# CFLAGS is honoured, but lowering it is a false economy: `-O0` makes cc
# quicker and the resulting komp slower, and the sweep runs that komp once per
# crate.
#
# The sweep does not stop at the first failing crate. Each crate's output is
# kept in its own file and printed only if it failed.
#
# The sweep runs SWEEP_JOBS crates at once, one per core up to four; each
# crate's peak RSS is its whole dependency chain, and MEM_BUDGET_MB is per
# crate. kf-integration's test time sets the floor. Crates sharing
# compiler/target are safe concurrently: artifacts are written under a private
# name and renamed into place.
#
# Every phase is timed; the totals print after the OK line, slowest first,
# beside the ccache hit rate. Each crate's PASS line carries its wall time and
# peak RSS, and the sweep fails a crate over `MEM_BUDGET_MB`.
#
# Exit is non-zero if any gate failed.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ── Where the time went ────────────────────────────────────────────────
#
# One `date +%s` per phase, always on.
KF_TIMES=""
KF_PHASE=""
KF_PHASE_T0=0
KF_RUN_T0="$(date +%s)"

phase() {
    kf_now="$(date +%s)"
    if [ -n "$KF_PHASE" ]; then
        KF_TIMES="$KF_TIMES$((kf_now - KF_PHASE_T0)) $KF_PHASE
"
    fi
    KF_PHASE="$1"
    KF_PHASE_T0="$kf_now"
    echo "==> $1"
}

# Closes the last phase and prints the table, slowest first.
report_times() {
    kf_now="$(date +%s)"
    if [ -n "$KF_PHASE" ]; then
        KF_TIMES="$KF_TIMES$((kf_now - KF_PHASE_T0)) $KF_PHASE
"
    fi
    echo ""
    echo "--- where the time went ---"
    printf '%s' "$KF_TIMES" | sort -rn | while read -r secs name; do
        [ -n "$name" ] || continue
        printf '  %5ss  %s\n' "$secs" "$name"
    done
    printf '  %5ss  TOTAL\n' "$((kf_now - KF_RUN_T0))"
    report_ccache
}

# The cache hit rate beside the timings. A miss storm is a legitimate
# consequence of changing what komp emits, so this reports and never fails.
report_ccache() {
    command -v ccache > /dev/null 2>&1 || return 0
    [ -n "${CCACHE_DIR:-}" ] || return 0
    kf_stats="$(ccache --show-stats 2>/dev/null || true)"
    kf_hit="$(printf '%s' "$kf_stats" | sed -n 's/^ *Hits: *\([0-9]*\) *\/ *\([0-9]*\).*/\1 \2/p' | head -1)"
    [ -n "$kf_hit" ] || return 0
    set -- $kf_hit
    if [ "${2:-0}" -gt 0 ]; then
        echo "  ccache  $1/$2 hits ($(( $1 * 100 / $2 ))%)"
    fi
}

# `--isolated` runs the gate in a throwaway worktree: the gate compiles the
# working tree, so an edit landing mid-run would be compiled by it. Off by
# default; CI jobs already start from their own checkout.
if [ "${1:-}" = "--isolated" ]; then
    shift
    iso="$(mktemp -d)"
    trap 'git -C "$ROOT" worktree remove --force "$iso/komp" >/dev/null 2>&1 || true
          git -C "$ROOT" worktree prune >/dev/null 2>&1 || true
          rm -rf "$iso"' EXIT INT TERM
    # HEAD plus uncommitted tracked edits: `stash create` writes a commit and
    # touches neither index nor tree. It prints nothing when the tree is clean.
    snap="$(git stash create 2>/dev/null || true)"
    [ -n "$snap" ] || snap="$(git rev-parse HEAD)"
    git worktree add --detach "$iso/komp" "$snap" >/dev/null
    # Untracked, unignored files, such as a new tests/cases/*.kf, are in no
    # commit.
    ( git ls-files --others --exclude-standard -z | xargs -0 -r tar -cf - ) \
        | ( cd "$iso/komp" && tar -xf - ) 2>/dev/null || true
    # The tool and compiler crates depend on the sibling, and it is swept too.
    if [ -d "$ROOT/../json" ]; then
        cp -r "$ROOT/../json" "$iso/json"
        rm -rf "$iso/json/target"
    fi
    rc=0
    sh "$iso/komp/scripts/check.sh" "$@" || rc=$?
    exit "$rc"
fi

# Every crate, unless the caller names a subset. `../json` is a sibling
# checkout but a first-party crate: the tool and compiler crates depend on it.
#
# `CRATES` lets CI shard the sweep. `CHECK_CLI=0` skips the CLI gates, which
# belong to one shard.
CRATES="${CRATES:-compiler/kf-core compiler/kf-parse compiler/kf-assemble
        compiler/kf-resolve compiler/kf-typecheck compiler/kf-mono
        compiler/kf-lower compiler/kf-codegen compiler/kf-interface
        compiler/kf-shared compiler/kf-lint compiler/kf-driver compiler/kf-tool compiler/kf-integration
        libs/core libs/alloc libs/std ../json}"
CHECK_CLI="${CHECK_CLI:-1}"

# Peak RSS a single crate's `komp test` may reach, in MB: a ceiling with room
# above the real numbers, so a regression trips it and ordinary growth does
# not. Raise it only with a measurement saying why.
MEM_BUDGET_MB="${MEM_BUDGET_MB:-2560}"
# How many crates the sweep runs at once; 1 is serial. Past four the crates
# wait on each other's dependencies more than on the cores.
cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
[ "$cores" -le 4 ] 2>/dev/null || cores=4
SWEEP_JOBS="${SWEEP_JOBS:-$cores}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Pin the C dialect, so a green run here means CI is green. komp shells out to
# `cc` per crate where CFLAGS cannot reach, so the pin is a shim on PATH. gcc
# 16 (C23) accepts an identical struct redefinition that gcc 13 (C17, what CI
# runs) rejects; pinning the older dialect makes local the stricter of the two.
#
# CONSTRAINT: the shim restores the original PATH before exec'ing. CI's `cc`
# is ccache, which finds the real compiler by scanning PATH for another `cc`,
# and would find this shim and loop forever.
#
# `KF_STD=` (empty) opts out. The same value lives in `dialect_flags()` in
# compiler/kf-tool/src/build/compile_c.kf, which pins the C komp compiles;
# this covers the direct `cc` calls here and the C under libs/*/native.
KF_STD="${KF_STD-gnu17}"
if [ -n "$KF_STD" ]; then
    real_cc="$(command -v "${CC:-cc}")"
    if [ -z "$real_cc" ]; then
        echo "FAIL: cannot resolve ${CC:-cc} to pin -std=$KF_STD" >&2
        exit 1
    fi
    mkdir -p "$WORK/shim"
    {
        echo '#!/bin/sh'
        echo "PATH=\"$PATH\""
        echo 'export PATH'
        echo "exec \"$real_cc\" -std=$KF_STD \"\$@\""
    } > "$WORK/shim/cc"
    chmod +x "$WORK/shim/cc"
    # Fail fast: a re-entrant shim spins rather than errors. Twenty seconds is
    # far above a trivial compile and far below any CI timeout.
    if command -v timeout > /dev/null 2>&1; then
        echo 'int main(void){return 0;}' > "$WORK/shim-probe.c"
        if ! timeout 20 "$WORK/shim/cc" -o "$WORK/shim-probe.out" "$WORK/shim-probe.c" > /dev/null 2>&1; then
            echo "FAIL: the -std=$KF_STD shim cannot compile a trivial file." >&2
            echo "      Re-entrant PATH, or ${CC:-cc} does not accept -std=$KF_STD." >&2
            echo "      Re-run with KF_STD= to skip pinning." >&2
            exit 1
        fi
    fi
    PATH="$WORK/shim:$PATH"
    export PATH
fi

run_fixpoint=1
run_sweep=1
case "${1:-}" in
    --fixpoint) run_sweep=0 ;;
    --sweep)    run_fixpoint=0 ;;
    "") ;;
    *) echo "usage: $0 [--isolated] [--fixpoint|--sweep]" >&2; exit 2 ;;
esac

if [ "$run_fixpoint" -eq 1 ]; then
phase "fixpoint"
# A whole run hands the fixpoint's komp to the sweep, as CI's jobs do.
if [ "$run_sweep" -eq 1 ] && [ -z "${KOMP_PREBUILT:-}" ] && [ -z "${KOMP_PUBLISH:-}" ]; then
    KOMP_PUBLISH="$WORK/fixpoint-bin/komp"
    KOMP_PREBUILT="$KOMP_PUBLISH"
    export KOMP_PUBLISH
fi
if ! sh bootstrap/build.sh > "$WORK/fixpoint.log" 2>&1; then
    cat "$WORK/fixpoint.log"
    echo "FAIL: fixpoint" >&2
    exit 1
fi
grep -E '^(OK|NOTE):' "$WORK/fixpoint.log" || true
fi

phase "file sizes"
if ! sh scripts/check_file_sizes.sh; then
    echo "FAIL: file sizes" >&2
    exit 1
fi

phase "line lengths"
if ! sh scripts/check_line_lengths.sh; then
    echo "FAIL: line lengths" >&2
    exit 1
fi

phase "unsafe blocks"
if ! sh scripts/check_unsafe.sh; then
    echo "FAIL: unsafe blocks" >&2
    exit 1
fi

if [ "$run_sweep" -eq 0 ]; then
    echo "OK: fixpoint"
    exit 0
fi

# Peak RSS of a child, from wait4's rusage; no shell reports it and GNU time
# is not on every CI image.
#
# `ru_maxrss` is the largest single process among the child and every
# descendant it waited for, not a sum, so it understates a moment when komp's
# forked children overlap. The same measurement every run, which is what a
# ceiling needs.
cat > "$WORK/maxrss.c" <<'MAXRSS'
#include <stdio.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>
int main(int argc, char** argv) {
    if (argc < 2) return 2;
    pid_t pid = fork();
    if (pid == 0) { execvp(argv[1], &argv[1]); _exit(127); }
    int status = 0;
    struct rusage usage;
    if (wait4(pid, &status, 0, &usage) < 0) return 2;
    fprintf(stderr, "KF_MAXRSS_KB %ld\n", (long)usage.ru_maxrss);
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return 128 + WTERMSIG(status);
}
MAXRSS
"${CC:-cc}" -O1 -o "$WORK/maxrss" "$WORK/maxrss.c"

# The sweep needs a komp of its own. KOMP_PREBUILT names one the fixpoint
# published for this commit, in this run or in CI's fixpoint job; without one,
# the seed builds it here.
if [ -n "${KOMP_PREBUILT:-}" ] && [ -x "$KOMP_PREBUILT" ] && [ -x "$(dirname "$KOMP_PREBUILT")/kflatc" ]; then
phase "using the published komp"
cp "$KOMP_PREBUILT" "$WORK/komp"
cp "$(dirname "$KOMP_PREBUILT")/kflatc" "$WORK/kflatc"
else
phase "building komp for the sweep"
. "$ROOT/bootstrap/seed.sh"
seed_build "$WORK/s0" || { echo "FAIL: the seed did not build; see the lines above" >&2; exit 1; }
# Keep the seed's diagnostics: a seed that cannot read this tree otherwise
# fails later at `cc` on a stage1.c that was never written.
if ! "$WORK/s0/komp0" "$ROOT/compiler/komp" "$WORK/stage1.c" > "$WORK/seed-emit.log" 2>&1; then
    echo "FAIL: the seed cannot read this tree." >&2
    echo "      The errors below are from komp0 -- the SEED -- compiling" >&2
    echo "      compiler/komp, not from your compiler. A syntax feature the" >&2
    echo "      seed predates reads exactly like a broken source file; build" >&2
    echo "      with a current komp to tell the two apart." >&2
    echo "      See \"The bootstrap seed\" in CONTRIBUTING.md." >&2
    grep -E 'error' "$WORK/seed-emit.log" | head -20 >&2
    exit 1
fi
# From inside `$WORK`, so its random name stays out of the hashed command line.
(cd "$WORK" && "${CC:-cc}" ${CFLAGS:--O2} -c -o stage1.o stage1.c)
"${CC:-cc}" ${CFLAGS:--O2} -o "$WORK/komp" "$WORK/stage1.o"
# komp runs the compiler as a process, found beside it, so the seed builds it.
"$WORK/s0/komp0" "$ROOT/compiler/kflatc" "$WORK/kflatc.c" > "$WORK/kflatc-emit.log" 2>&1 || {
    cat "$WORK/kflatc-emit.log" >&2
    echo "FAIL: the seed could not build kflatc" >&2
    exit 1
}
(cd "$WORK" && "${CC:-cc}" ${CFLAGS:--O2} -c -o kflatc.o kflatc.c)
"${CC:-cc}" ${CFLAGS:--O2} -o "$WORK/kflatc" "$WORK/kflatc.o"
fi

if [ "$CHECK_CLI" = "1" ]; then

# The compiler and libraries are laid out as komp fmt formats them: the
# formatter is installed from the package index at the version below, as a
# user would, and `--check` names every file it would change.
phase "formatting"
mkdir -p "$WORK/fmt-toolchain/bin"
cp "$WORK/komp" "$WORK/kflatc" "$WORK/fmt-toolchain/bin/"
[ -e "$WORK/fmt-toolchain/libs" ] || ln -s "$ROOT/libs" "$WORK/fmt-toolchain/libs"
KFLAT_HOME="$WORK/fmt-home" "$WORK/fmt-toolchain/bin/komp" tool install komp_fmt@0.1 > "$WORK/fmt-install.log" 2>&1 || {
    cat "$WORK/fmt-install.log" >&2
    echo "FAIL: komp_fmt could not be installed from the package index" >&2
    exit 1
}
if ! unformatted=$(cd "$ROOT" && "$WORK/fmt-home/bin/komp-fmt" --check compiler libs); then
    echo "$unformatted" | sed 's/^/       /' >&2
    echo "FAIL: these files are not formatted; run \`komp fmt compiler libs\`" >&2
    exit 1
fi
echo "  PASS  compiler and libs are formatted"

phase "cli quiet flags"
mkdir -p "$WORK/quiet-project/src"
{
    echo '[project]'
    echo 'name = "quiet_project"'
    echo 'version = "0.1.0"'
    echo 'kind = "lib"'
} > "$WORK/quiet-project/kf.toml"
echo 'pub fun answer(): int32 { return 42 }' > "$WORK/quiet-project/src/lib.kf"
"$WORK/komp" -q build "$WORK/quiet-project"
"$WORK/komp" --quiet build "$WORK/quiet-project"
"$WORK/komp" build -q "$WORK/quiet-project"
"$WORK/komp" build --quiet "$WORK/quiet-project"
echo "  PASS  all quiet positions select the project root"

# Two ergonomics rules:
#
#   1. A project directory is optional and defaults to "."
#   2. A help or version flag is answered wherever it appears, including
#      first position, where it would read as the project path
#
# The legacy positional form, which the bootstrap depends on, is checked too.
# $WORK/komp is staged without a sysroot beside it, so $WORK gets the
# workspace shape: the walk up from a crate root then finds libs/.
[ -e "$WORK/libs" ] || ln -s "$ROOT/libs" "$WORK/libs"

mkdir -p "$WORK/cwd-project/src"
{
    echo '[project]'
    echo 'name = "cwd_project"'
    echo 'version = "0.1.0"'
    echo 'kind = "bin"'
} > "$WORK/cwd-project/kf.toml"
printf 'fun main(): int32 {\n    return 7\n}\n' > "$WORK/cwd-project/src/main.kf"

( cd "$WORK/cwd-project" && "$WORK/komp" check >/dev/null )
( cd "$WORK/cwd-project" && "$WORK/komp" build >/dev/null )
( cd "$WORK/cwd-project" && "$WORK/komp" run >/dev/null; test "$?" = "7" ) || {
    echo "FAIL: bare \`komp run\` did not build and run the current directory" >&2
    exit 1
}

for flag in --version -V; do
    out=$("$WORK/komp" "$flag" 2>&1) || true
    case "$out" in
        komp\ *) ;;
        *) echo "FAIL: \`komp $flag\` answered '$out', not a version" >&2; exit 1 ;;
    esac
done

# Command-specific help names only that command: "check" not appearing is the
# evidence.
build_help=$("$WORK/komp" build --help 2>&1)
case "$build_help" in
    *"komp build"*) ;;
    *) echo "FAIL: \`komp build --help\` did not describe build" >&2; exit 1 ;;
esac
case "$build_help" in
    *"type-check without producing a binary"*)
        echo "FAIL: \`komp build --help\` printed the whole command list" >&2; exit 1 ;;
esac
"$WORK/komp" help build >/dev/null

# The flag may also occupy the slot the directory would have used.
( cd "$WORK/cwd-project" && "$WORK/komp" test --case nothing_matches >/dev/null )

# Legacy `komp <project-dir> <out.c>`, which bootstrap/build.sh runs.
"$WORK/komp" "$WORK/cwd-project" "$WORK/legacy.c" >/dev/null
test -s "$WORK/legacy.c" || {
    echo "FAIL: the legacy positional form wrote no C" >&2
    exit 1
}
echo "  PASS  commands default to the current directory, and -h/-V answer anywhere"

# `komp <tool>` hands its process to the tool, so an editor that stops the
# tool leaves no komp behind: the tool's parent is komp's parent, the exit
# status is the tool's own, and KOMP_BIN names a komp it can run.
mkdir -p "$WORK/exec-home/bin"
printf '#!/bin/sh\ntest -x "$KOMP_BIN" && echo "$PPID $*"\nexit 3\n' > "$WORK/exec-home/bin/komp-probe"
chmod +x "$WORK/exec-home/bin/komp-probe"
probe=$(KFLAT_HOME="$WORK/exec-home" sh -c 'echo "$$"; "$0" probe a "b c"; echo "status $?"' "$WORK/komp")
expected=$(printf '%s\n%s a b c\nstatus 3' "${probe%%
*}" "${probe%%
*}")
[ "$probe" = "$expected" ] || {
    echo "FAIL: \`komp probe\` did not exec the tool; got:" >&2
    echo "$probe" >&2
    exit 1
}
echo "  PASS  komp <tool> replaces itself with the tool"

# --manifest-path names a manifest; downstream appends kf.toml itself, so the
# flag hands on its directory. Passing the directory works too.
"$WORK/komp" check --manifest-path "$WORK/cwd-project/kf.toml" >/dev/null
"$WORK/komp" check --manifest-path "$WORK/cwd-project" >/dev/null

# `komp build -o <file>` is the whole-program form: one named output file.
rm -f "$WORK/dash-o.c"
"$WORK/komp" build -o "$WORK/dash-o.c" "$WORK/cwd-project" >/dev/null
test -s "$WORK/dash-o.c" || {
    echo "FAIL: \`komp build -o\` wrote no C" >&2
    exit 1
}

# `komp build --unity` with no `-o` writes beside the crate's other output,
# not into the CWD.
rm -f "$WORK/cwd-project/target/kflat/komp_out.c" "$WORK/cwd-project/komp_out.c"
( cd "$WORK/cwd-project" && "$WORK/komp" build --unity >/dev/null )
test -s "$WORK/cwd-project/target/kflat/komp_out.c" || {
    echo "FAIL: \`komp build --unity\` wrote no C under target/kflat" >&2
    exit 1
}
if [ -e "$WORK/cwd-project/komp_out.c" ]; then
    echo "FAIL: \`komp build --unity\` dropped komp_out.c into the CWD" >&2
    exit 1
fi

# An unknown flag is refused rather than read as a project directory, and
# a second positional is refused rather than silently ignored.
if "$WORK/komp" build --bogus >/dev/null 2>&1; then
    echo "FAIL: \`komp build --bogus\` was accepted" >&2
    exit 1
fi
if "$WORK/komp" run a b >/dev/null 2>&1; then
    echo "FAIL: \`komp run\` accepted two project directories" >&2
    exit 1
fi
echo "  PASS  --manifest-path, -o, and refusal of unknown flags"

# A warning is about the crate being checked, however it was named: the
# dependency filter and the sysroot walk-up both work from a relative path.
# Checked by the warning, since failure exits 0.
mkdir -p "$WORK/warn-project/src"
{
    echo '[project]'
    echo 'name = "warn_project"'
    echo 'version = "0.1.0"'
    echo 'kind = "bin"'
} > "$WORK/warn-project/kf.toml"
{
    echo 'import core.assert.*'
    echo ''
    echo 'fun main(): int32 {'
    echo '    return 0'
    echo '}'
} > "$WORK/warn-project/src/main.kf"

for where in absolute inside relative; do
    case "$where" in
        absolute) out=$("$WORK/komp" check "$WORK/warn-project" 2>&1) ;;
        inside)   out=$( cd "$WORK/warn-project" && "$WORK/komp" check 2>&1 ) ;;
        relative) out=$( cd "$WORK" && "$WORK/komp" check warn-project 2>&1 ) ;;
    esac
    case "$out" in
        *"unused import \`core.assert.*\`"*) ;;
        *)
            echo "FAIL: \`komp check\` ($where project path) dropped the unused-import warning" >&2
            echo "$out" >&2
            exit 1 ;;
    esac
done
echo "  PASS  a warning about the crate under check survives a relative project path"

# A lint means the same on a warm tree as a cold one: `komp check` loads
# dependencies from source when their interfaces are absent and from `.kfi`
# when present, and both paths set `Module.crate`. The fixture needs a
# dependency, since an interface is what the fast path keys on.
rm -rf "$WORK/lint-dep" "$WORK/lint-app"
mkdir -p "$WORK/lint-dep/src" "$WORK/lint-app/src"
{
    echo '[project]'
    echo 'name = "lint_dep"'
    echo 'version = "0.1.0"'
    echo 'kind = "lib"'
} > "$WORK/lint-dep/kf.toml"
echo 'pub fun only_one(): int32 { return 1 }' > "$WORK/lint-dep/src/lib.kf"
{
    echo '[project]'
    echo 'name = "lint_app"'
    echo 'version = "0.1.0"'
    echo 'kind = "bin"'
    echo ''
    echo '[dependencies]'
    echo 'lint_dep = { path = "../lint-dep" }'
} > "$WORK/lint-app/kf.toml"
{
    echo 'import lint_dep.*'
    echo ''
    echo 'fun main(): int32 {'
    echo '    return only_one() - 1'
    echo '}'
} > "$WORK/lint-app/src/main.kf"

cold=$("$WORK/komp" check "$WORK/lint-app" 2>&1)
case "$cold" in
    *"wildcard import"*) ;;
    *) echo "FAIL: the wildcard lint did not fire on a cold tree" >&2; echo "$cold" >&2; exit 1 ;;
esac

# Populates target/kflat with the dependency's interface, which is what
# switches `check` onto the other path.
"$WORK/komp" -q build "$WORK/lint-app" > /dev/null
test -s "$WORK/lint-app/target/kflat/lint_dep.kfi" || {
    echo "FAIL: the build wrote no dependency interface, so the warm path is untested" >&2
    exit 1
}

warm=$("$WORK/komp" check "$WORK/lint-app" 2>&1)
case "$warm" in
    *"wildcard import"*) ;;
    *) echo "FAIL: the wildcard lint fired on a cold tree and not on a warm one" >&2; echo "$warm" >&2; exit 1 ;;
esac
echo "  PASS  an import lint fires on a cold tree and on a warm one"

# The `[lint]` table reaches the compiler, which never reads kf.toml: komp
# passes each row, and a misspelled row is named as the table's own.
rm -rf "$WORK/lint-table"
cp -r "$WORK/lint-app" "$WORK/lint-table"
rm -rf "$WORK/lint-table/target"
printf '\n[lint]\nwildcard_import = "deny"\n' >> "$WORK/lint-table/kf.toml"
if denied=$("$WORK/komp" check "$WORK/lint-table" 2>&1); then
    echo "FAIL: a lint the [lint] table denies did not fail the check" >&2; echo "$denied" >&2; exit 1
fi
case "$denied" in
    *"error: wildcard import"*) ;;
    *) echo "FAIL: the denied lint was not reported as an error" >&2; echo "$denied" >&2; exit 1 ;;
esac
if "$WORK/komp" -q build "$WORK/lint-table" > /dev/null 2>&1; then
    echo "FAIL: a lint the [lint] table denies did not fail the build" >&2; exit 1
fi
sed -i 's/^wildcard_import = /wildcard_imports = /' "$WORK/lint-table/kf.toml"
misspelled=$("$WORK/komp" check "$WORK/lint-table" 2>&1 || true)
case "$misspelled" in
    *"kf.toml [lint]: no lint or lint group named \`wildcard_imports\`"*) ;;
    *) echo "FAIL: a misspelled [lint] row was not named" >&2; echo "$misspelled" >&2; exit 1 ;;
esac
echo "  PASS  the [lint] table denies in check and build, and names a misspelled row"

# lint.toml reaches the compiler the same way: a group row sets its lints, a
# lint row after it wins, and `komp lint` tallies what it reports.
rm -rf "$WORK/lint-file"
cp -r "$WORK/lint-app" "$WORK/lint-file"
rm -rf "$WORK/lint-file/target"
printf '[groups]\nstyle = "deny"\n' > "$WORK/lint-file/lint.toml"
if grouped=$("$WORK/komp" lint "$WORK/lint-file" 2>&1); then
    echo "FAIL: a group lint.toml denies did not fail komp lint" >&2; echo "$grouped" >&2; exit 1
fi
case "$grouped" in
    *"error: wildcard import"*"lint: 1 error, 0 warnings"*"wildcard_import  1"*) ;;
    *) echo "FAIL: komp lint did not report the denied group and its tally" >&2; echo "$grouped" >&2; exit 1 ;;
esac
printf '[lints]\nwildcard_import = "warn"\n' >> "$WORK/lint-file/lint.toml"
"$WORK/komp" lint "$WORK/lint-file" > /dev/null 2>&1 || {
    echo "FAIL: a lint row did not override its group's row" >&2; exit 1
}
echo "  PASS  lint.toml sets groups and lints, and komp lint tallies them"

# `komp outdated` finds its project wherever the directory sits among its
# flags, as an editor passes them.
mkdir -p "$WORK/outdated-app/src"
printf '[project]\nname = "outdated_app"\nversion = "0.1.0"\nkind = "bin"\n' > "$WORK/outdated-app/kf.toml"
outdated=$(cd / && "$WORK/komp" outdated --offline --format=json "$WORK/outdated-app" 2>&1 || true)
case "$outdated" in
    *'"project":"'*'/outdated-app","dependencies":[],"tools":[]}') ;;
    *) echo "FAIL: komp outdated did not read the directory after its flags" >&2; echo "$outdated" >&2; exit 1 ;;
esac
echo "  PASS  komp outdated takes its directory after its flags"

# `komp new` with no name scaffolds the current directory, named after it.
mkdir -p "$WORK/new-here"
(cd "$WORK/new-here" && "$WORK/komp" new > /dev/null) || {
    echo "FAIL: komp new with no name failed in an empty directory" >&2; exit 1
}
grep -q '^name = "new_here"$' "$WORK/new-here/kf.toml" || {
    echo "FAIL: komp new did not name the project after its directory" >&2; cat "$WORK/new-here/kf.toml" >&2; exit 1
}
echo "  PASS  komp new scaffolds the current directory"

# A crate declaring no dependencies still gets `core` and `alloc`, on both
# check paths: the source walk serves a never-built project and every
# `--format=json` run.
phase "cli check resolves the implicit stdlib"
mkdir -p "$WORK/implicit-project/src"
{
    echo '[project]'
    echo 'name = "implicit_project"'
    echo 'version = "0.1.0"'
} > "$WORK/implicit-project/kf.toml"
{
    echo 'import alloc.list.*'
    echo ''
    echo 'fun main(): int32 {'
    echo '    var xs = List.new<int32>()'
    echo '    xs.push(7)'
    echo '    return 0'
    echo '}'
} > "$WORK/implicit-project/src/main.kf"

# Cold: nothing has ever written target/kflat for this project.
"$WORK/komp" -q check "$WORK/implicit-project" > /dev/null
"$WORK/komp" check --format=json "$WORK/implicit-project" > "$WORK/implicit.json"
if [ -s "$WORK/implicit.json" ]; then
    echo "  FAIL  json check reported errors on a clean project:"
    head -3 "$WORK/implicit.json"
    exit 1
fi

# And the same paths still find a real error, so the above is not vacuous.
echo 'fun main(): int32 { return nope() }' > "$WORK/implicit-project/src/main.kf"
if "$WORK/komp" -q check "$WORK/implicit-project" > /dev/null 2>&1; then
    echo "  FAIL  check exited 0 on an undefined function" >&2
    exit 1
fi
"$WORK/komp" check --format=json "$WORK/implicit-project" > "$WORK/implicit-bad.json" || true
if ! grep -q '"severity":"error"' "$WORK/implicit-bad.json"; then
    echo "  FAIL  json check reported no error for an undefined function" >&2
    exit 1
fi
echo "  PASS  cold and json checks resolve core/alloc, and still catch errors"

# `kflatc serve` is a stable protocol for other tools (docs/book/src/tools/
# serve.md). A scripted session pins the shape of every answer, so a compiler
# change that would break a client fails here, not in the client.
phase "cli kflatc serve keeps its protocol"
serve_root="$WORK/serve-project"
mkdir -p "$serve_root/src"
{
    echo '[project]'
    echo 'name = "serve_project"'
    echo 'version = "0.1.0"'
    echo 'kind = "bin"'
} > "$serve_root/kf.toml"
printf 'fun main(): int32 {\n    val x: int32 = "text"\n    return x\n}\n' > "$serve_root/src/main.kf"
"$WORK/komp" check "$serve_root" > /dev/null 2>&1 || true
serve_crate="{\"name\":\"serve_project\",\"root\":\"$serve_root\",\"loads\":[\"core\",\"alloc\"],\"lints\":[],\"kind\":\"bin\"}"
serve_check="{\"target_dir\":\"$serve_root/target/kflat\",\"crate\":$serve_crate}"
serve_file="$serve_root/src/main.kf"
serve_crates="[{\"name\":\"core\",\"root\":\"$ROOT/libs/core\"},{\"name\":\"alloc\",\"root\":\"$ROOT/libs/alloc\"},{\"name\":\"serve_project\",\"root\":\"$serve_root\"}]"
{
    echo '{"id":1,"method":"check"}'
    echo '{"id":2,"method":"hello","params":{"protocol":1}}'
    echo "{\"id\":3,\"method\":\"check\",\"params\":$serve_check}"
    # printf, not echo: dash's echo would turn the `\n` into a line break.
    printf '%s\n' "{\"id\":\"s\",\"method\":\"stage\",\"params\":{\"path\":\"$serve_file\",\"text\":\"fun main(): int32 { return 4 }\\n\"}}"
    echo "{\"id\":5,\"method\":\"check\",\"params\":$serve_check}"
    # Offset 27 is the staged `4`; on disk it is a space inside `val x`.
    echo "{\"id\":\"hs\",\"method\":\"hover\",\"params\":{\"path\":\"$serve_file\",\"offset\":27,\"crates\":$serve_crates}}"
    echo "{\"id\":6,\"method\":\"unstage\",\"params\":{\"path\":\"$serve_file\"}}"
    echo "{\"id\":7,\"method\":\"check\",\"params\":$serve_check}"
    echo "{\"id\":\"sym\",\"method\":\"symbols\",\"params\":{\"path\":\"$serve_file\"}}"
    echo "{\"id\":\"fold\",\"method\":\"folding\",\"params\":{\"path\":\"$serve_file\"}}"
    echo "{\"id\":\"sel\",\"method\":\"selection\",\"params\":{\"path\":\"$serve_file\",\"offset\":40}}"
    echo "{\"id\":\"gone\",\"method\":\"symbols\",\"params\":{\"path\":\"$serve_root/src/gone.kf\"}}"
    echo "{\"id\":\"hov\",\"method\":\"hover\",\"params\":{\"path\":\"$serve_file\",\"offset\":39,\"crates\":$serve_crates}}"
    echo "{\"id\":\"far\",\"method\":\"hover\",\"params\":{\"path\":\"$serve_root/src/gone.kf\",\"offset\":0,\"crates\":$serve_crates}}"
    serve_typed="\"path\":\"$serve_file\",\"crates\":$serve_crates"
    echo "{\"id\":\"sig\",\"method\":\"signature\",\"params\":{$serve_typed,\"offset\":39}}"
    echo "{\"id\":\"refs\",\"method\":\"references\",\"params\":{$serve_typed,\"offset\":4}}"
    echo "{\"id\":\"comp\",\"method\":\"completion\",\"params\":{$serve_typed,\"offset\":57}}"
    echo "{\"id\":\"ren\",\"method\":\"rename\",\"params\":{$serve_typed,\"offset\":4,\"new_name\":\"start\"}}"
    echo "{\"id\":\"inl\",\"method\":\"inlays\",\"params\":{$serve_typed}}"
    echo "{\"id\":\"tok\",\"method\":\"tokens\",\"params\":{$serve_typed}}"
    echo "{\"id\":\"nooff\",\"method\":\"references\",\"params\":{$serve_typed}}"
    echo "{\"id\":8,\"method\":\"check\",\"params\":{\"target_dir\":\"$serve_root/target/kflat\",\"crate\":{\"name\":\"serve_project\",\"root\":\"$serve_root\",\"loads\":[\"missing\"],\"lints\":[]}}}"
    echo '{"id":9,"method":"stage","params":{"text":""}}'
    echo '{"id":10,"method":"compile"}'
    echo 'not json'
    echo ''
    echo '{"id":12,"method":"hello","params":{"protocol":999}}'
    echo '{"id":13,"method":"shutdown"}'
    echo '{"id":14,"method":"hello","params":{"protocol":1}}'
} > "$WORK/serve-session.in"
serve_status=0
"$WORK/kflatc" serve < "$WORK/serve-session.in" > "$WORK/serve-session.out" || serve_status=$?
serve_diagnostic='{"schema_version":3,"severity":"error","code":null,"message":"[^"]*","byte_start":[0-9]*,"byte_end":[0-9]*,"file":"'"$serve_file"'","line":2,"column":[0-9]*,"secondary":\[\],"fix":null}'
{
    echo '{"id":1,"error":{"code":"not_ready","message":"[^"]*"}}'
    echo '{"id":2,"result":{"protocol":1,"compiler":"[^"]*"}}'
    echo '{"id":3,"result":{"errors":1,"diagnostics":\['"$serve_diagnostic"'\]}}'
    echo '{"id":"s","result":null}'
    echo '{"id":5,"result":{"errors":0,"diagnostics":\[\]}}'
    echo '{"id":"hs","result":{"schema_version":2,"file":"'"$serve_file"'","offset":27,"type":"int32","signature":null,"documentation":null,"byte_start":27,"byte_end":28}}'
    echo '{"id":6,"result":null}'
    echo '{"id":7,"result":{"errors":1,"diagnostics":\['"$serve_diagnostic"'\]}}'
    echo '{"id":"sym","result":{"schema_version":1,"file":"'"$serve_file"'","symbols":\[{"name":"main","kind":"function","detail":"(): int32","byte_start":0,"byte_end":[0-9]*,"children":\[\]}\]}}'
    echo '{"id":"fold","result":{"schema_version":1,"file":"'"$serve_file"'","ranges":\[{"byte_start":0,"byte_end":[0-9]*,"kind":"region"}\]}}'
    echo '{"id":"sel","result":{"schema_version":1,"file":"'"$serve_file"'","offset":40,"ranges":\[{"byte_start":39,"byte_end":45},{"byte_start":0,"byte_end":[0-9]*}\]}}'
    echo '{"id":"gone","error":{"code":"no_such_file","message":"[^"]*"}}'
    echo '{"id":"hov","result":{"schema_version":2,"file":"'"$serve_file"'","offset":39,"type":"[^"]*","signature":null,"documentation":null,"byte_start":39,"byte_end":45}}'
    echo '{"id":"far","error":{"code":"not_in_crate","message":"[^"]*"}}'
    serve_name_span='{"file":"'"$serve_file"'","byte_start":4,"byte_end":8}'
    echo '{"id":"sig","result":{"schema_version":1,"file":"'"$serve_file"'","offset":39,"label":null,"parameters":\[\],"active_parameter":0}}'
    echo '{"id":"refs","result":{"schema_version":1,"file":"'"$serve_file"'","offset":4,"declaration":'"$serve_name_span"',"references":\[\]}}'
    echo '{"id":"comp","result":{"schema_version":2,"file":"'"$serve_file"'","offset":57,"receiver_type":null,"prefix":"","items":\[.*{"label":"x","kind":"local","detail":"[^"]*"}.*\]}}'
    echo '{"id":"ren","result":{"schema_version":1,"file":"'"$serve_file"'","offset":4,"new_name":"start","ok":true,"error":null,"range":'"$serve_name_span"',"edits":\['"$serve_name_span"'\]}}'
    echo '{"id":"inl","result":{"schema_version":1,"file":"'"$serve_file"'","inlays":\[\]}}'
    echo '{"id":"tok","result":{"schema_version":1,"file":"'"$serve_file"'","tokens":\[{"byte_start":4,"byte_end":8,"type":"function"},{"byte_start":57,"byte_end":58,"type":"variable"}\]}}'
    echo '{"id":"nooff","error":{"code":"invalid_params","message":"[^"]*"}}'
    echo '{"id":8,"error":{"code":"check_failed","message":"[^"]*"}}'
    echo '{"id":9,"error":{"code":"invalid_params","message":"[^"]*"}}'
    echo '{"id":10,"error":{"code":"unknown_method","message":"[^"]*"}}'
    echo '{"id":null,"error":{"code":"parse_error","message":"[^"]*"}}'
    echo '{"id":12,"error":{"code":"unsupported_protocol","message":"[^"]*"}}'
    echo '{"id":13,"result":null}'
} > "$WORK/serve-session.expected"
serve_ok=1
[ "$serve_status" -eq 0 ] || serve_ok=0
[ "$(wc -l < "$WORK/serve-session.out")" -eq "$(wc -l < "$WORK/serve-session.expected")" ] || serve_ok=0
serve_line=0
while IFS= read -r serve_pattern; do
    serve_line=$((serve_line + 1))
    sed -n "${serve_line}p" "$WORK/serve-session.out" | grep -qx -- "$serve_pattern" || {
        echo "  FAIL  answer $serve_line does not match: $serve_pattern" >&2
        serve_ok=0
    }
done < "$WORK/serve-session.expected"
if [ "$serve_ok" -ne 1 ]; then
    echo "  FAIL  kflatc serve exited $serve_status and answered:" >&2
    cat "$WORK/serve-session.out" >&2
    exit 1
fi
echo "  PASS  every answer keeps its shape, and the server stops at shutdown"

# A `check` naming `sources` reads their interfaces as their staged text
# makes them, so an unsaved edit to a library reaches the crate using it,
# its visibility rules included; without them it reads the target directory.
phase "cli kflatc serve checks against staged dependencies"
staged_root="$WORK/serve-workspace"
mkdir -p "$staged_root/geometry/src" "$staged_root/app/src"
printf '[workspace]\nmembers = ["app", "geometry"]\ndefault-member = "app"\n' > "$staged_root/kf.toml"
printf '[project]\nname = "geometry"\nversion = "0.1.0"\nkind = "lib"\n' > "$staged_root/geometry/kf.toml"
printf 'pub fun area(w: int32, h: int32): int32 {\n    return w * h\n}\n' > "$staged_root/geometry/src/lib.kf"
printf '[project]\nname = "app"\nversion = "0.1.0"\nkind = "bin"\n\n[dependencies]\ngeometry = { path = "../geometry" }\n' \
    > "$staged_root/app/kf.toml"
printf 'import geometry.area\n\nfun main(): int32 {\n    return area(2, 3)\n}\n' > "$staged_root/app/src/main.kf"
"$WORK/komp" check --workspace "$staged_root" > /dev/null 2>&1 || true
staged_lib="$staged_root/geometry/src/lib.kf"
staged_app="{\"name\":\"app\",\"root\":\"$staged_root/app\",\"loads\":[\"core\",\"alloc\",\"geometry\"],\"lints\":[]}"
staged_sources="[{\"name\":\"geometry\",\"root\":\"$staged_root/geometry\",\"loads\":[\"core\",\"alloc\"]}]"
staged_plain="{\"target_dir\":\"$staged_root/target/kflat\",\"crate\":$staged_app}"
staged_check="{\"target_dir\":\"$staged_root/target/kflat\",\"sources\":$staged_sources,\"crate\":$staged_app}"
{
    echo '{"id":1,"method":"hello","params":{"protocol":1}}'
    printf '%s\n' "{\"id\":2,\"method\":\"stage\",\"params\":{\"path\":\"$staged_lib\",\"text\":\"pub fun surface(w: int32, h: int32): int32 {\\n    return w * h\\n}\\n\"}}"
    echo "{\"id\":3,\"method\":\"check\",\"params\":$staged_plain}"
    echo "{\"id\":4,\"method\":\"check\",\"params\":$staged_check}"
    printf '%s\n' "{\"id\":5,\"method\":\"stage\",\"params\":{\"path\":\"$staged_lib\",\"text\":\"fun area(w: int32, h: int32): int32 {\\n    return w * h\\n}\\n\"}}"
    echo "{\"id\":6,\"method\":\"check\",\"params\":$staged_check}"
    echo "{\"id\":7,\"method\":\"unstage\",\"params\":{\"path\":\"$staged_lib\"}}"
    echo "{\"id\":8,\"method\":\"check\",\"params\":$staged_check}"
    echo '{"id":9,"method":"shutdown"}'
} > "$WORK/serve-staged.in"
"$WORK/kflatc" serve < "$WORK/serve-staged.in" > "$WORK/serve-staged.out" 2>&1 || true
staged_errors() {
    sed -n "s/^{\"id\":$1,\"result\":{\"errors\":\([0-9]*\),.*/\1/p" "$WORK/serve-staged.out"
}
if [ "$(staged_errors 3)" != "0" ] || [ "$(staged_errors 4)" = "0" ] || [ -z "$(staged_errors 4)" ] ||
    [ "$(staged_errors 6)" = "0" ] || [ -z "$(staged_errors 6)" ] || [ "$(staged_errors 8)" != "0" ]; then
    echo "  FAIL  a staged dependency's edit should reach its user through sources only; answers:" >&2
    cat "$WORK/serve-staged.out" >&2
    exit 1
fi
echo "  PASS  a staged rename and a staged loss of pub reach the using crate; unstaged, it checks clean"

# `core.ptr` turns a C function's null into absence, with the generic argument
# inferred at a user struct, the type an FFI wrapper points at.
phase "cli core.ptr answers about a null pointer"
mkdir -p "$WORK/ptr-project/src"
{
    echo '[project]'
    echo 'name = "ptr_project"'
    echo 'version = "0.1.0"'
    echo 'kind = "bin"'
} > "$WORK/ptr-project/kf.toml"
cat > "$WORK/ptr-project/src/main.kf" <<'PTR'
import core.ptr.*

pub struct Node { pub val n: int32 }

extern "C" fun kf_alloc(size: uint64): Ptr<uint8>
extern "C" fun kf_free(p: Ptr<void>): void

fun main(): int32 {
    // null, at a struct pointee, with the type argument inferred
    val absent = ptr_null<Node>()
    if !ptr_is_null(absent) { return 1 }
    if ptr_as_option(absent).is_some() { return 2 }

    // and a live one, which must not read as absent
    val live = unsafe { kf_alloc(16) as Ptr<Node> }
    if ptr_is_null(live) { return 3 }
    if ptr_as_option(live).is_none() { return 4 }
    unsafe { kf_free(live as Ptr<void>) }

    // the trap the vocabulary exists to close: the direct coercion keeps
    // null as a present value, so `ptr_as_option` is not interchangeable
    // with an assignment.
    val wrapped: Ptr<Node>? = absent
    if wrapped.is_none() { return 5 }
    return 0
}
PTR
if ! "$WORK/komp" -q build "$WORK/ptr-project" > "$WORK/ptr-build.log" 2>&1; then
    echo "  FAIL  a program using core.ptr did not build:" >&2
    tail -5 "$WORK/ptr-build.log" >&2
    exit 1
fi
ptr_rc=0
"$WORK/ptr-project/target/kflat/ptr_project" || ptr_rc=$?
if [ "$ptr_rc" != "0" ]; then
    echo "  FAIL  core.ptr answered wrongly at step $ptr_rc" >&2
    exit 1
fi
echo "  PASS  null, a live pointer and the Some(null) trap all answer correctly"

# The unity path, `komp <project> out.c`: separate compilation's qualify pass
# respells every type, so names the unity path emits raw are gated here. A
# type's `crate::module::Name` identity must not reach C. Built, compiled and
# run: the name must also match the definition.
phase "cli the unity path emits C identifiers"
# The shape is load-bearing: a dependency's type arriving from a method's
# return. Weaker fixtures passed against the bug; mutate this one before
# trusting a change to it.
mkdir -p "$WORK/unity-project/src" "$WORK/unity-dep/src"
{
    echo '[project]'
    echo 'name = "unity_dep"'
    echo 'version = "0.1.0"'
    echo 'kind = "lib"'
} > "$WORK/unity-dep/kf.toml"
cat > "$WORK/unity-dep/src/lib.kf" <<'UNITYDEP'
pub struct Mark { pub val n: int32 }

pub fun no_mark(): Mark { return Mark { n: 0 } }
UNITYDEP
{
    echo '[project]'
    echo 'name = "unity_project"'
    echo 'version = "0.1.0"'
    echo 'kind = "bin"'
    echo ''
    echo '[dependencies]'
    echo 'unity_dep = { path = "../unity-dep" }'
} > "$WORK/unity-project/kf.toml"
cat > "$WORK/unity-project/src/main.kf" <<'UNITY'
import core.ptr.*
import unity_dep.*

pub struct Node { pub val n: int32 }

pub enum Pick { Left  Right }

pub struct Board { pub var base: int32 }

impl Board {
    pub fun mark(k: int32): Mark {
        return Mark { n: self.base + k }
    }
}

// The type argument is INFERRED at a user struct, through a Ptr<T>.
// Written out as `is_absent<Node>(absent)` it always worked; inferred, the
// write-back stamped the canonical identity onto the call.
pub fun is_absent<T>(p: Ptr<T>): bool { return unsafe { p as uint64 } == 0 }

// A `when` used as a VALUE whose type arrives from a METHOD returning
// a dependency's type. The temporary is declared from a TypeRef built out of
// that type's identity, two lines above a `__when_subj` the same codegen
// spells correctly.
fun choose(p: Pick, b: &var Board): int32 {
    val picked = when (p) {
        Left  => b.mark(1)
        Right => no_mark()
    }
    return picked.n
}

fun main(): int32 {
    val absent = ptr_null<Node>()
    if !is_absent(absent) { return 1 }
    var b = Board { base: 10 }
    if choose(Pick.Left, &var b) != 11 { return 2 }
    if choose(Pick.Right, &var b) != 0 { return 3 }
    return 0
}
UNITY
if ! "$WORK/komp" -q "$WORK/unity-project" "$WORK/unity.c" > "$WORK/unity-emit.log" 2>&1; then
    echo "  FAIL  the unity build did not emit:" >&2
    tail -5 "$WORK/unity-emit.log" >&2
    exit 1
fi
# Name the failure before cc does: `::` in the output is always this bug.
if grep -q '::' "$WORK/unity.c"; then
    echo "  FAIL  the unity output carries a canonical identity, which is not a C name:" >&2
    grep -n '::' "$WORK/unity.c" | head -5 | sed 's/^/         /' >&2
    exit 1
fi
if ! "${CC:-cc}" -o "$WORK/unity-bin" "$WORK/unity.c" > "$WORK/unity-cc.log" 2>&1; then
    echo "  FAIL  the unity output did not compile:" >&2
    tail -10 "$WORK/unity-cc.log" >&2
    exit 1
fi
unity_rc=0
"$WORK/unity-bin" || unity_rc=$?
if [ "$unity_rc" != "0" ]; then
    echo "  FAIL  the unity binary answered wrongly at step $unity_rc" >&2
    exit 1
fi
echo "  PASS  an inferred type argument and a cross-crate when-value both emit real C names"

# Every allocation, generated or core's own, goes through one replaceable ABI:
# a program defining its own kf_alloc links and serves them all.
phase "cli a program can replace the allocator"
mkdir -p "$WORK/alloc-project/src" "$WORK/alloc-project/native"
{
    echo '[project]'
    echo 'name = "alloc_project"'
    echo 'version = "0.1.0"'
    echo 'kind = "bin"'
    echo ''
    echo '[native]'
    echo 'c_sources = ["native/my_alloc.c"]'
} > "$WORK/alloc-project/kf.toml"
cat > "$WORK/alloc-project/native/my_alloc.c" <<'ALLOC'
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
static unsigned long calls = 0;
void* kf_alloc(size_t size)            { calls++; return malloc(size); }
void* kf_realloc(void* p, size_t size) { calls++; return realloc(p, size); }
void  kf_free(void* p)                 { free(p); }
uint64_t kf_override_count(void)       { return (uint64_t)calls; }
ALLOC
cat > "$WORK/alloc-project/src/main.kf" <<'MAIN'
extern "C" fun kf_override_count(): uint64

fun main(): int32 {
    var s = String.from("hello")
    s.append(", world")
    if s.byte_len() != 12 { return 1 }
    if unsafe { kf_override_count() } == 0 { return 2 }
    return 0
}
MAIN
if ! "$WORK/komp" -q build "$WORK/alloc-project" > "$WORK/alloc-build.log" 2>&1; then
    echo "  FAIL  a program defining its own kf_alloc did not link:" >&2
    tail -5 "$WORK/alloc-build.log" >&2
    exit 1
fi
alloc_rc=0
"$WORK/alloc-project/target/kflat/alloc_project" || alloc_rc=$?
if [ "$alloc_rc" = "2" ]; then
    echo "  FAIL  it linked, but core allocated around the ABI (count was 0)" >&2
    exit 1
fi
if [ "$alloc_rc" != "0" ]; then
    echo "  FAIL  the replacement-allocator program returned $alloc_rc" >&2
    exit 1
fi
echo "  PASS  a replaced allocator serves generated code and core alike"

# A program replacing only `kf_try_alloc` has its allocator serve every
# allocation and the failure policy derived from it. Past its budget it
# returns NULL, and the program lands in its own kf_alloc_failed.
phase "cli a fallible allocator drives the infallible one"
mkdir -p "$WORK/oom-project/src" "$WORK/oom-project/native"
{
    echo '[project]'
    echo 'name = "oom_project"'
    echo 'version = "0.1.0"'
    echo 'kind = "bin"'
    echo ''
    echo '[native]'
    echo 'c_sources = ["native/budget.c"]'
} > "$WORK/oom-project/kf.toml"
cat > "$WORK/oom-project/native/budget.c" <<'BUDGET'
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <unistd.h>
static unsigned long allocs = 0;
static unsigned long reallocs = 0;
static int budget_open = 1;
/* Only the FALLIBLE primitives are replaced. kf_alloc/kf_realloc are left to
   core's wrappers, so this also proves they route through here.
   Counted SEPARATELY: one shared counter cannot tell a derived kf_alloc from
   a kf_alloc that still calls malloc itself, because the realloc path alone
   keeps the total non-zero. */
void* kf_try_alloc(size_t size) {
    if (!budget_open) return NULL;
    allocs++;
    return malloc(size);
}
void* kf_try_realloc(void* p, size_t size) {
    if (!budget_open) return NULL;
    reallocs++;
    return realloc(p, size);
}
void kf_alloc_failed(size_t size) {
    (void)size;
    _exit(42);
}
uint64_t budget_allocs(void)   { return (uint64_t)allocs; }
uint64_t budget_reallocs(void) { return (uint64_t)reallocs; }
void budget_close(void)        { budget_open = 0; }
BUDGET
cat > "$WORK/oom-project/src/main.kf" <<'OOM'
extern "C" fun budget_allocs(): uint64
extern "C" fun budget_reallocs(): uint64
extern "C" fun budget_close(): void

fun main(): int32 {
    var s = String.from("hello")
    s.append(", world")
    if s.byte_len() != 12 { return 1 }
    // BOTH infallible wrappers went through the replaced fallible pair
    if unsafe { budget_allocs() } == 0 { return 2 }
    if unsafe { budget_reallocs() } == 0 { return 4 }
    // past the budget, an infallible allocation must reach kf_alloc_failed,
    // which exits 42 — never return NULL for the caller to write through
    unsafe { budget_close() }
    var overflow = String.from("this allocation cannot be served")
    overflow.append("!")
    return 3
}
OOM
if ! "$WORK/komp" -q build "$WORK/oom-project" > "$WORK/oom-build.log" 2>&1; then
    echo "  FAIL  a program replacing only the fallible pair did not link:" >&2
    tail -5 "$WORK/oom-build.log" >&2
    exit 1
fi
oom_rc=0
"$WORK/oom-project/target/kflat/oom_project" || oom_rc=$?
if [ "$oom_rc" = "2" ]; then
    echo "  FAIL  kf_alloc did not route through the replaced kf_try_alloc" >&2
    exit 1
fi
if [ "$oom_rc" = "4" ]; then
    echo "  FAIL  kf_realloc did not route through the replaced kf_try_realloc" >&2
    exit 1
fi
if [ "$oom_rc" = "3" ]; then
    echo "  FAIL  an infallible allocation returned past an exhausted budget" >&2
    exit 1
fi
if [ "$oom_rc" != "42" ]; then
    echo "  FAIL  out of memory did not reach kf_alloc_failed (rc $oom_rc)" >&2
    exit 1
fi
echo "  PASS  the infallible pair is derived, and OOM reaches the handler"

# The freestanding tier: the emitted C compiles with no C library.
# `-nostdinc -isystem $(cc -print-file-name=include)` removes libc's headers
# and keeps the compiler's own, what a freestanding implementation provides.
#
# Built both ways: the hosted build must still pull in <stdio.h>, so the
# difference comes from the tier and not from an empty file.
phase "cli a freestanding program needs no C library"
mkdir -p "$WORK/bare-project/src"
{
    echo '[project]'
    echo 'name = "bare_project"'
    echo 'version = "0.1.0"'
    echo 'kind = "bin"'
    echo 'freestanding = true'
} > "$WORK/bare-project/kf.toml"
cat > "$WORK/bare-project/src/main.kf" <<'BARE'
struct Vec2 { val x: int32  val y: int32 }

fun add(a: Vec2, b: Vec2): Vec2 {
    return Vec2 { x: a.x + b.x, y: a.y + b.y }
}

fun main(): int32 {
    val sum = add(Vec2 { x: 1, y: 2 }, Vec2 { x: 3, y: 4 })
    return sum.x + sum.y
}
BARE
"$WORK/komp" "$WORK/bare-project" "$WORK/bare.c" > /dev/null

# The hosted spelling of the same program, as the control.
sed '/^freestanding = true$/d' "$WORK/bare-project/kf.toml" > "$WORK/bare-project/kf.hosted.toml"
mv "$WORK/bare-project/kf.toml" "$WORK/bare-project/kf.free.toml"
cp "$WORK/bare-project/kf.hosted.toml" "$WORK/bare-project/kf.toml"
"$WORK/komp" "$WORK/bare-project" "$WORK/hosted.c" > /dev/null
cp "$WORK/bare-project/kf.free.toml" "$WORK/bare-project/kf.toml"

if ! grep -q '#include <stdio.h>' "$WORK/hosted.c"; then
    echo "  FAIL  the hosted build no longer carries core's hosted half," >&2
    echo "        so the freestanding check below proves nothing" >&2
    exit 1
fi
if grep -q '#include <stdio.h>' "$WORK/bare.c"; then
    echo "  FAIL  freestanding = true still appended core's hosted half" >&2
    exit 1
fi

FREESTANDING_INCLUDE="$("${CC:-cc}" -print-file-name=include)"
bare_rc=0
"${CC:-cc}" -c -ffreestanding -fno-stack-protector -nostdinc -isystem "$FREESTANDING_INCLUDE" \
    -o "$WORK/bare.o" "$WORK/bare.c" > "$WORK/bare-cc.log" 2>&1 || bare_rc=$?
if [ "$bare_rc" -ne 0 ]; then
    echo "  FAIL  the freestanding output does not compile without a C library:" >&2
    head -5 "$WORK/bare-cc.log" >&2
    exit 1
fi

# Linking with -nostdlib against a runtime written from scratch proves the
# program needs only the seams a bare-metal target provides. Dead glue shows
# up here: an unreachable `Display` impl drags in `int64_display`.
cat > "$WORK/baremetal.c" <<'BAREMETAL'
/* A freestanding target's half of the contract: no libc, no OS services
   beyond the exit syscall. Nothing here is KFlat-specific. */
typedef unsigned long size_t;

static unsigned char heap[4096];
static size_t used = 0;

void* kf_try_alloc(size_t n)            { if (used + n > sizeof heap) return 0; void* p = heap + used; used += n; return p; }
void* kf_try_realloc(void* p, size_t n) { (void)p; return kf_try_alloc(n); }
void  kf_free(void* p)                  { (void)p; }
void  panic(const char* m)              { (void)m; for (;;) {} }

void* memcpy(void* d, const void* s, size_t n)  { unsigned char* a = d; const unsigned char* b = s; for (size_t i = 0; i < n; i++) a[i] = b[i]; return d; }
void* memmove(void* d, const void* s, size_t n) { unsigned char* a = d; const unsigned char* b = s; if (a < b) { for (size_t i = 0; i < n; i++) a[i] = b[i]; } else { for (size_t i = n; i > 0; i--) a[i-1] = b[i-1]; } return d; }

int main(int argc, char** argv);
void _start(void) {
    int rc = main(0, 0);
    __asm__ volatile("syscall" :: "a"(60L), "D"((long)rc));
    __builtin_unreachable();
}
BAREMETAL

link_rc=0
"${CC:-cc}" -c -ffreestanding -fno-stack-protector -nostdinc -isystem "$FREESTANDING_INCLUDE" \
    -o "$WORK/baremetal.o" "$WORK/baremetal.c" > "$WORK/bare-rt.log" 2>&1 || link_rc=$?
if [ "$link_rc" -eq 0 ]; then
    "${CC:-cc}" -nostdlib -o "$WORK/bare-program" "$WORK/bare.o" "$WORK/baremetal.o" \
        >> "$WORK/bare-rt.log" 2>&1 || link_rc=$?
fi
if [ "$link_rc" -ne 0 ]; then
    echo "  FAIL  the freestanding output does not link without a C library:" >&2
    grep -E "undefined|error" "$WORK/bare-rt.log" | head -8 >&2
    exit 1
fi

# 1+2 + 3+4 = 10.
bare_run=0
"$WORK/bare-program" || bare_run=$?
if [ "$bare_run" -ne 10 ]; then
    echo "  FAIL  the freestanding program ran but answered $bare_run, expected 10" >&2
    exit 1
fi
echo "  PASS  freestanding output compiles, links -nostdlib, and runs"

# The sanitizer gate, in the CLI shard. Nothing else here sees a memory
# defect: a leak changes nothing an assertion observes, and a use-after-free
# usually reads bytes still intact.
phase "asan probes"
sh "$ROOT/scripts/check_asan.sh" "$WORK/komp" "$WORK" || exit 1

fi   # CHECK_CLI

phase "sweep"
failed=""
overbudget=""
notests=""

# Run, then report: runs may fan out while the per-crate lines stay in crate
# order. Each run records its status beside its log.
#
# Each crate is also linted with every warning an error: `komp lint
# --deny-warnings`, at the levels lint.toml and the lints' defaults give. After
# the crate's test, so a warm check loads the interfaces it wrote; per crate,
# since the unity project resolves names without their imports.
#
# A stable scratch root per crate, so ccache sees the same `-I` and `-c`
# paths every run. The checkout and the crate are in the name, keeping a
# worktree gate apart from the main tree and concurrent crates apart from each
# other. Emptied first: nothing cleans an inherited root on exit. The CLI and
# asan phases build under `$WORK` and do not cache.
crate_scratch() {
    echo "${TMPDIR:-/tmp}/komp-gate-$(printf '%s' "$ROOT" | cksum | cut -d' ' -f1)-$(echo "$1" | tr / _)"
}

# Each crate's KFlat artifacts survive CI runs when KFLAT_CACHE_DIR names a
# persistent directory. An artifact is reused only when every source byte, the
# manifest, the flags and the compiler binary match, so a restored directory
# is never wrong. Slots are per compiler binary.
kflat_cache=""
if [ -n "${KFLAT_CACHE_DIR:-}" ] && [ -d "$(dirname "$KFLAT_CACHE_DIR")" ] \
   && mkdir -p "$KFLAT_CACHE_DIR" 2>/dev/null && [ -w "$KFLAT_CACHE_DIR" ]; then
    kflat_cache="$KFLAT_CACHE_DIR/$(cksum < "$WORK/komp" | cut -d' ' -f1)"
    mkdir -p "$kflat_cache" && touch "$kflat_cache"
    find "$KFLAT_CACHE_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +3 -exec rm -rf {} + 2>/dev/null || true
fi

# The directory holding a crate's `target`. The compiler workspace's members
# build into one, compiler/target; every other crate has its own.
kflat_home() {
    case "$1" in
        compiler/*) echo compiler ;;
        *) echo "$1" ;;
    esac
}

kflat_slot() {
    echo "$kflat_cache/$(echo "$1" | tr / _).tar"
}

kflat_state() {
    echo "$WORK/kflat-$(echo "$1" | tr / _)"
}

# Records warm or cold per home, for the PASS lines of its crates.
kflat_restore() {
    echo cold > "$(kflat_state "$1")"
    [ -n "$kflat_cache" ] || return 0
    slot="$(kflat_slot "$1")"
    [ -f "$slot" ] || return 0
    rm -rf "$1/target/kflat"
    mkdir -p "$1/target"
    if tar -xf "$slot" -C "$1/target" 2>/dev/null; then
        echo warm > "$(kflat_state "$1")"
    else
        rm -rf "$1/target/kflat"
    fi
}

# Written beside the slot and renamed over it, so a concurrent reader sees the
# old archive or the new one, never half of either.
kflat_save() {
    [ -n "$kflat_cache" ] && [ -d "$1/target/kflat" ] || return 0
    slot="$(kflat_slot "$1")"
    if tar -cf "$slot.tmp.$$" -C "$1/target" --exclude=kflat/test kflat 2>/dev/null; then
        mv -f "$slot.tmp.$$" "$slot"
    else
        rm -f "$slot.tmp.$$"
    fi
}

# Once per home, not per crate: members share theirs.
KFLAT_HOMES="$(for c in $CRATES; do kflat_home "$c"; done | sort -u)"
for h in $KFLAT_HOMES; do
    kflat_restore "$h"
done

# One crate's test and lint, as a script so `xargs -P` can run it: xargs
# starts the next crate as soon as any slot frees.
cat > "$WORK/sweep_one.sh" <<'SWEEP_ONE'
c="$1"; log="$2"; scratch="$3"; WORK="$4"
rm -rf "$scratch"
mkdir -p "$scratch"
t0="$(date +%s)"
rc=0
KOMP_SCRATCH_ROOT="$scratch" "$WORK/maxrss" "$WORK/komp" -q test "$c" > "$log" 2>&1 || rc=$?
echo "$rc" > "$log.rc"
lrc=0
KOMP_SCRATCH_ROOT="$scratch" "$WORK/komp" lint --deny-warnings "$c" > "$log.lint" 2>&1 || lrc=$?
echo "$lrc" > "$log.lint.rc"
echo "$(( $(date +%s) - t0 ))" > "$log.secs"
SWEEP_ONE

# The slowest crates start first, so the pool does not end on one of them
# alone. The report below keeps CRATES order.
SLOW_FIRST="compiler/kf-integration compiler/kf-typecheck"
started=""
for c in $SLOW_FIRST; do
    case " $(echo $CRATES) " in *" $c "*) started="$started $c" ;; esac
done
for c in $CRATES; do
    case " $started " in *" $c "*) ;; *) started="$started $c" ;; esac
done
for c in $started; do
    printf '%s\0%s\0%s\0%s\0' "$c" "$WORK/$(echo "$c" | tr / _).log" "$(crate_scratch "$c")" "$WORK"
done | xargs -0 -n 4 -P "$SWEEP_JOBS" sh "$WORK/sweep_one.sh"
for h in $KFLAT_HOMES; do
    kflat_save "$h"
done

lintfailed=""
for c in $CRATES; do
    log="$WORK/$(echo "$c" | tr / _).log"
    if [ "$(cat "$log.lint.rc" 2>/dev/null || echo 1)" != "0" ]; then
        lintfailed="$lintfailed $c"
    fi
    if [ "$(cat "$log.rc" 2>/dev/null || echo 1)" = "0" ]; then
        # On the PASS line, so a crate creeping towards the ceiling shows in
        # every log.
        rss_kb="$(sed -n 's/^KF_MAXRSS_KB \([0-9]*\)$/\1/p' "$log" | tail -1)"
        rss_mb=$(( ${rss_kb:-0} / 1024 ))
        passed="$(grep -oE '[0-9]+ passed' "$log" | tail -1)"
        secs="$(cat "$log.secs" 2>/dev/null || echo '?')"
        kflat="$(cat "$(kflat_state "$(kflat_home "$c")")" 2>/dev/null || echo cold)"
        echo "  PASS  $c  $passed  peak ${rss_mb}MB  ${secs}s  kflat=$kflat"
        # Zero tests is a failure: it hides "cannot run anything".
        case "$passed" in
            "0 passed"|"") notests="$notests $c" ;;
        esac
        if [ "$rss_mb" -gt "$MEM_BUDGET_MB" ]; then
            overbudget="$overbudget $c=${rss_mb}MB"
        fi
    else
        echo "  FAIL  $c"
        # Named here too, so the summary alone says what broke.
        sed -n '/^failures:$/,/^$/p' "$log" | sed '1d;/^$/d' | sed 's/^/       /'
        # The case walker is one test over many fixtures, so its failures sit
        # far above the tail printed below.
        grep -E '\.\.\. FAILED' "$log" | awk '!seen[$0]++' | head -20 | sed 's/^ *//; s/^/       /'
        # A case builds in a child process, so its causes are in this log
        # among the negative cases' expected errors; scope them to the failed
        # cases' target/case_tmp/<name>.
        for cs in $(grep -E 'case tests/cases/.*\.\.\. FAILED' "$log" \
                    | sed -E 's|.*tests/cases/([A-Za-z0-9_]+)\.kf.*|\1|' | awk '!s[$0]++'); do
            grep -E "case_tmp/$cs/" "$log" | grep -E '(error|fatal error):' \
                | awk '!s[$0]++' | head -5 | sed 's/^ *//; s/^/       > /'
        done
        failed="$failed $c"
    fi
done

# Only reached when every crate's tests passed, so this failed for a reason
# the tests did not have: usually the lints. Say so when it is not.
if [ -n "$lintfailed" ] && [ -z "$failed" ]; then
    other=""
    for c in $lintfailed; do
        lintlog="$WORK/$(echo "$c" | tr / _).log.lint"
        echo ""
        if grep -qE "^lint: " "$lintlog"; then
            echo "--- $c: lints ---"
            grep -E "error: |^lint: |^  [a-z_]+ +[0-9]+$" "$lintlog" | head -30 | sed 's/^/       /'
        else
            echo "--- $c: \`komp lint\` failed before it could lint ---"
            tail -20 "$lintlog" | sed 's/^/       /'
            other="$other $c"
        fi
    done
    echo ""
    if [ -n "$other" ]; then
        echo "FAIL: \`komp lint\` failed for:$other" >&2
        exit 1
    fi
    echo "FAIL: lints to fix in:$lintfailed" >&2
    echo "      \`komp lint <crate>\` names each one, and \`komp check --fix\` carries the repairs" >&2
    echo "      it can; \`@allow(<lint>)\` on the declaration keeps one on purpose." >&2
    exit 1
fi

if [ -n "$overbudget" ] && [ -z "$failed" ]; then
    echo ""
    echo "  over the ${MEM_BUDGET_MB}MB budget:$overbudget"
    echo "FAIL: peak memory over budget:$overbudget" >&2
    exit 1
fi

if [ -n "$notests" ] && [ -z "$failed" ]; then
    echo "FAIL: no tests ran for:$notests" >&2
    echo "      A crate with no tests and a crate that cannot build its tests" >&2
    echo "      report the same PASS line. Every crate in the sweep has tests." >&2
    exit 1
fi

if [ -n "$failed" ]; then
    for c in $failed; do
        echo ""
        echo "--- $c ---"
        # The failures block is the last thing the harness prints, so a tail
        # always carries it.
        tail -40 "$WORK/$(echo "$c" | tr / _).log"
    done
    echo ""
    echo "FAIL:$failed" >&2
    exit 1
fi

# Name what ran, so a shard does not read as a whole-tree pass.
summary="crates: $(echo $CRATES | wc -w)"
if [ "$CHECK_CLI" = "1" ]; then summary="CLI checks + asan probes + $summary"; fi
if [ "$run_fixpoint" -eq 1 ]; then summary="fixpoint + $summary"; fi
echo "OK: $summary"
report_times
