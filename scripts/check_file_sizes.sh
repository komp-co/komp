#!/usr/bin/env sh
# A growth ratchet on .kf file length, counted in lines of code. Not a cap.
#
#   scripts/check_file_sizes.sh            # check (what check.sh runs)
#   scripts/check_file_sizes.sh --update   # rewrite the baseline from the tree
#
# AGENTS.md asks for one concept per file and says explicitly that a
# file which is genuinely one concept may be long. That rule cannot be
# scripted. What can be scripted is "do not make it worse", which is the
# failure mode a cap was reaching for: drift is silent and gradual, and nobody
# notices a file going from 398 to 418 lines.
#
# So this fails on two things and nothing else:
#
#   * a file in the baseline that has GROWN past its recorded count;
#   * a file NOT in the baseline that has crossed 350 lines.
#
# A line counts unless it is an import or holds only a `//` comment. Neither
# says anything about how many concepts the file holds: a module move rewrites
# imports everywhere, and counting comments would make deleting one the
# cheapest way under the limit.
#
# Shrinking is always allowed and never needs the baseline updated first;
# --update rewrites it downward and is run as part of any commit that splits a
# file.
#
# 350 reappears here doing a different job than the cap it replaced. It
# forbids nothing: crossing it fails the build until someone either splits the
# file or adds a baseline line that says "this file is one concept and it is
# 640 lines". Both are fine — what the gate buys is that the choice gets MADE
# rather than drifted into, which is why the number being arbitrary stopped
# mattering. A trigger only has to fire often enough to prompt a look and
# rarely enough not to be noise.
#
# Test files are included. They are long for a different reason (many
# independent @test functions rather than one tangled concept), but there is
# no reason to let them grow unboundedly either.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BASELINE="scripts/file_size_baseline.txt"
TRIGGER=350

sizes() {
    find src -name '*.kf' -type f | sort | while read -r f; do
        printf '%s %s\n' "$(grep -cvE '^[[:space:]]*//|^import ' "$f")" "$f"
    done
}

if [ "${1:-}" = "--update" ]; then
    {
        echo "# Files over $TRIGGER lines of code, and the count each is frozen at."
        echo "# Imports and comment-only lines are not counted."
        echo "# Regenerate with scripts/check_file_sizes.sh --update."
        echo "#"
        echo "# A line here is not an exemption from the one-concept rule — it is a"
        echo "# claim that the file is one concept at that length. Shrinking is"
        echo "# always allowed; growing needs this file updated in the same commit,"
        echo "# which is the point at which someone has to look."
        sizes | awk -v t="$TRIGGER" '$1 > t'
    } > "$BASELINE"
    echo "wrote $BASELINE ($(grep -cv '^#' "$BASELINE") files over $TRIGGER)"
    exit 0
fi

if [ ! -f "$BASELINE" ]; then
    echo "FAIL: $BASELINE is missing; run scripts/check_file_sizes.sh --update" >&2
    exit 1
fi

# The counter comes back from the loop's subshell through a file, so clear
# any left by an interrupted run — a stale one fails the next check for a
# reason that is not in the tree.
rm -f "$BASELINE.fail"

sizes | while read -r n f; do
    was=$(awk -v f="$f" '$2 == f { print $1 }' "$BASELINE")
    if [ -n "$was" ]; then
        if [ "$n" -gt "$was" ]; then
            echo "  GREW  $f: $was -> $n lines" >&2
            echo x >> "$BASELINE.fail"
        fi
    elif [ "$n" -gt "$TRIGGER" ]; then
        echo "  OVER  $f: $n lines, over $TRIGGER and not in the baseline" >&2
        echo x >> "$BASELINE.fail"
    fi
done

if [ -f "$BASELINE.fail" ]; then
    fails=$(wc -l < "$BASELINE.fail" | tr -d ' ')
    rm -f "$BASELINE.fail"
    echo "FAIL: $fails file(s) grew or crossed $TRIGGER lines." >&2
    echo "      Split it, or run scripts/check_file_sizes.sh --update and say why in the commit." >&2
    exit 1
fi

echo "OK: no .kf file grew past its baseline, and none crossed $TRIGGER"
