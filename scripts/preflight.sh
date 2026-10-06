#!/usr/bin/env sh
# The gates that need no freshly bootstrapped compiler: the ratchets,
# formatting, and the lints of the crates this change touches. Seconds to a
# couple of minutes, against the full gate's quarter hour, so what they catch
# is caught before the fixpoint and the sweep are paid for.
#
#   scripts/preflight.sh             # ratchets, formatting, lints of changed crates
#   scripts/preflight.sh --ratchets  # the ratchets alone
#   scripts/preflight.sh --lint      # the lints of changed crates alone
#   scripts/preflight.sh --staged    # the pre-commit hook: staged files only
#
# KOMP names the komp that lints; without it, `bin/komp` (a scratch compiler
# built from this tree) and then `komp` on the PATH. A komp older than the tree
# lints with its own lints, so a scratch build is the honest one. With none,
# the lints are skipped and the line says so.
#
# "Changed" is measured from KF_BASE (default `origin/development`, then
# `development`) to the working tree, untracked files included.
#
# Exit is non-zero if any gate run failed.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

mode="${1:-all}"
case "$mode" in
    all|--ratchets|--lint|--staged) ;;
    *) echo "usage: $0 [--ratchets|--lint|--staged]" >&2; exit 2 ;;
esac

failed=""

ratchets() {
    for gate in file_sizes line_lengths; do
        sh "scripts/check_$gate.sh" || failed="$failed $gate"
    done
}

# The .kf files to judge, one per line: staged ones for the hook, otherwise
# every one changed since the base.
changed_files() {
    if [ "$mode" = "--staged" ]; then
        git diff --cached --name-only --diff-filter=ACM -- 'compiler/*.kf' 'libs/*.kf' 'tools/*.kf'
        return
    fi
    base="${KF_BASE:-}"
    if [ -z "$base" ]; then
        for candidate in origin/development development; do
            if git rev-parse --verify -q "$candidate" > /dev/null; then base="$candidate"; break; fi
        done
    fi
    {
        if [ -n "$base" ]; then
            git diff --name-only --diff-filter=ACMR "$(git merge-base HEAD "$base")" -- 'compiler/*.kf' 'libs/*.kf' 'tools/*.kf'
        fi
        git diff --name-only --diff-filter=ACMR HEAD -- 'compiler/*.kf' 'libs/*.kf' 'tools/*.kf'
        git ls-files --others --exclude-standard -- 'compiler/*.kf' 'libs/*.kf' 'tools/*.kf'
    } | sort -u
}

# A crate is the directory holding kf.toml: compiler/<crate>, libs/<crate> or
# tools/<crate>.
changed_crates() {
    changed_files | while read -r file; do
        crate="$(echo "$file" | cut -d/ -f1-2)"
        [ -f "$crate/kf.toml" ] && echo "$crate"
    done | sort -u
}

formatting() {
    fmt="${KFLAT_HOME:-$HOME/.kflat}/bin/komp-fmt"
    if [ ! -x "$fmt" ]; then
        echo "  SKIP  formatting: komp-fmt is not installed (\`komp tool install komp_fmt\`)"
        return
    fi
    files="$(changed_files)"
    if [ -z "$files" ]; then
        echo "  PASS  formatting: no .kf file changed"
        return
    fi
    # shellcheck disable=SC2086
    if unformatted=$("$fmt" --check $files); then
        echo "  PASS  formatting"
    else
        echo "$unformatted" | sed 's/^/        /'
        echo "  FAIL  formatting: run \`komp fmt\` on these files"
        failed="$failed formatting"
    fi
}

find_komp() {
    if [ -n "${KOMP:-}" ]; then echo "$KOMP"; return; fi
    if [ -x "$ROOT/bin/komp" ] && [ -x "$ROOT/bin/kflatc" ]; then echo "$ROOT/bin/komp"; return; fi
    command -v komp 2>/dev/null || true
}

lints() {
    komp="$(find_komp)"
    if [ -z "$komp" ]; then
        echo "  SKIP  lints: no komp (set KOMP, build bin/komp, or put komp on the PATH)"
        return
    fi
    crates="$(changed_crates)"
    if [ -z "$crates" ]; then
        echo "  PASS  lints: no crate changed"
        return
    fi
    logs="$(mktemp -d)"
    jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
    [ "$jobs" -le 4 ] 2>/dev/null || jobs=4
    for crate in $crates; do
        printf '%s\0%s\0' "$crate" "$logs/$(echo "$crate" | tr / _)"
    done | xargs -0 -n 2 -P "$jobs" sh -c \
        '"$0" lint --deny-warnings "$1" > "$2.log" 2>&1; echo $? > "$2.rc"' "$komp"
    for crate in $crates; do
        log="$logs/$(echo "$crate" | tr / _)"
        if [ "$(cat "$log.rc")" = "0" ]; then
            echo "  PASS  lints: $crate"
        else
            grep -E "error: |warning: |^lint: " "$log.log" | head -20 | sed 's/^/        /'
            echo "  FAIL  lints: $crate"
            failed="$failed lints:$crate"
        fi
    done
    rm -rf "$logs"
    echo "        (linted with $komp)"
}

case "$mode" in
    --ratchets) ratchets ;;
    --lint) lints ;;
    --staged) formatting; lints ;;
    all) ratchets; formatting; lints ;;
esac

if [ -n "$failed" ]; then
    echo "FAIL:$failed" >&2
    exit 1
fi
echo "OK: preflight"
