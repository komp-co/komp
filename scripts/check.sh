#!/usr/bin/env sh
# komp's gate: the ratchets, komp built with the kflat toolchain its
# workspace pins, kf-tool's tests, and the command-line checks.
#
#   scripts/check.sh            # everything
#   CHECK_TESTS=0 scripts/check.sh   # without kf-tool's tests, as CI's cli job
#   CHECK_CLI=0 scripts/check.sh     # without the command-line checks
#
# The toolchain is the one `kflatc` on PATH belongs to, or KFLAT_TOOLCHAIN,
# a directory holding `bin/kflatc` and `libs/`. compiler/kf.toml's `kflat`
# pin names the release CI installs.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CHECK_TESTS="${CHECK_TESTS:-1}"
CHECK_CLI="${CHECK_CLI:-1}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

phase() {
    echo "==> $1"
}

if [ -n "${KFLAT_TOOLCHAIN:-}" ]; then
    TOOLCHAIN="$KFLAT_TOOLCHAIN"
else
    kflatc_on_path="$(command -v kflatc)" || { echo "FAIL: no kflatc on PATH; install a kflat toolchain" >&2; exit 1; }
    TOOLCHAIN="$(cd "$(dirname "$(readlink -f "$kflatc_on_path")")/.." && pwd)"
fi
[ -x "$TOOLCHAIN/bin/kflatc" ] && [ -d "$TOOLCHAIN/libs" ] || {
    echo "FAIL: $TOOLCHAIN holds no bin/kflatc and libs/" >&2
    exit 1
}
echo "toolchain: $TOOLCHAIN ($("$TOOLCHAIN/bin/kflatc" version | head -1))"

phase "ratchets"
sh scripts/check_file_sizes.sh
sh scripts/check_line_lengths.sh

phase "build"
KFLATC="$TOOLCHAIN/bin/kflatc" "$TOOLCHAIN/bin/komp" build compiler
# komp runs the kflatc beside it and finds the libraries at ../libs from
# there, so the new komp gets a toolchain's shape: $WORK/tc/bin and
# $WORK/tc/libs. $WORK/komp links to it; komp resolves its own path.
mkdir -p "$WORK/tc/bin"
cp compiler/target/kflat/komp "$WORK/tc/bin/komp"
cp "$TOOLCHAIN/bin/kflatc" "$WORK/tc/bin/kflatc"
ln -s "$TOOLCHAIN/libs" "$WORK/tc/libs"
ln -s "$WORK/tc/bin/komp" "$WORK/komp"
ln -s "$WORK/tc/bin/kflatc" "$WORK/kflatc"
"$WORK/komp" --version

if [ "$CHECK_TESTS" = "1" ]; then
phase "kf-tool's tests"
"$WORK/komp" test compiler/kf-tool
fi

if [ "$CHECK_CLI" = "1" ]; then

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
# toolchain's libraries beside it: the walk up from a crate root finds libs/.
[ -e "$WORK/libs" ] || ln -s "$TOOLCHAIN/libs" "$WORK/libs"

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

# A command's directory may follow its flags.
case "$("$WORK/komp" metadata --offline "$WORK/cwd-project" 2>&1)" in
    *'"crates"'*) ;;
    *) echo "FAIL: \`komp metadata --offline <dir>\` did not read <dir>" >&2; exit 1 ;;
esac

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

fi   # CHECK_CLI

echo "OK: komp's gate passed"
