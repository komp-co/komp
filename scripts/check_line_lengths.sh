#!/usr/bin/env sh
# A ratchet on OVER-LONG LINES, the row-wise twin of check_file_sizes.sh.
#
# Not a cap. The tree is already 95% within 88 columns, but 1510 lines are
# over 120 and fixing them all is days of work, most of it low value. So this
# freezes the count per file: a file may not gain a long line, and a file with
# none may not grow one. Shrinking is always allowed.
#
# Why 120 rather than 80: wrapping is legal in kf (a binary operator at the end
# of a line continues it; parameter and argument lists may span lines), but a
# diagnostic message built with interpolation reads best on one line, and those
# land in the 90-120 band. 120 keeps them and still catches the 200+ character
# lines that are genuinely unreadable.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BASELINE="scripts/line_length_baseline.txt"
LIMIT=120

counts() {
    find src -name '*.kf' -type f | sort | while read -r f; do
        n=$(awk -v lim="$LIMIT" 'length > lim { c++ } END { print c+0 }' "$f")
        if [ "$n" -gt 0 ]; then printf '%s %s\n' "$n" "$f"; fi
    done
}

if [ "${1:-}" = "--update" ]; then
    {
        echo "# Lines over $LIMIT columns, and the count each file is frozen at."
        echo "# Regenerate with scripts/check_line_lengths.sh --update."
        echo "#"
        echo "# A line here is not permission to write another one — it is a record"
        echo "# of what was already there when the ratchet went in. Shrinking is"
        echo "# always allowed; growing needs this file updated in the same commit,"
        echo "# which is the point at which someone has to look."
        counts
    } > "$BASELINE"
    echo "wrote $BASELINE ($(grep -cv '^#' "$BASELINE") files with a line over $LIMIT)"
    exit 0
fi

if [ ! -f "$BASELINE" ]; then
    echo "FAIL: $BASELINE is missing; run scripts/check_line_lengths.sh --update" >&2
    exit 1
fi

# The counter crosses the loop's subshell through a file, so clear any left by
# an interrupted run — a stale one fails the next check for a reason that is
# not in the tree.
rm -f "$BASELINE.fail"

counts | while read -r n f; do
    was=$(awk -v f="$f" '$2 == f { print $1 }' "$BASELINE")
    if [ -z "$was" ]; then was=0; fi
    if [ "$n" -gt "$was" ]; then
        echo "  LONGER  $f: $was -> $n lines over $LIMIT" >&2
        awk -v lim="$LIMIT" -v f="$f" 'length > lim { c++; if (c <= 5) printf "          %s:%d is %d columns\n", f, NR, length } END { if (c > 5) printf "          ... and %d more\n", c - 5 }' "$f" >&2
        echo x >> "$BASELINE.fail"
    fi
done

if [ -f "$BASELINE.fail" ]; then
    fails=$(wc -l < "$BASELINE.fail" | tr -d ' ')
    rm -f "$BASELINE.fail"
    echo "FAIL: $fails file(s) gained a line over $LIMIT columns." >&2
    echo "      Wrap it — a trailing binary operator continues a line, and parameter" >&2
    echo "      and argument lists may span lines — or run" >&2
    echo "      scripts/check_line_lengths.sh --update and say why in the commit." >&2
    exit 1
fi

echo "OK: no .kf file gained a line over $LIMIT columns"
