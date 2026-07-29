#!/bin/bash
#
# Checks the five scripts that implement --help by printing their own header
# comment through a HARDCODED line range: `sed -n '2,NNp'`.
#
# That couples runtime behaviour to comment length, which nothing else in this
# tree does. Editing a comment is the one change everybody treats as free, so a
# cleanup that shortens a header truncates --help silently -- and passes a
# "comments only" review, because it is one. Adding prose below the block is the
# same bug the other way: the range starts printing code.
#
# The contract each script carries is a sentinel comment on the line
# immediately after the range:
#
#   # --- end of --help text; tests/help-text-test.sh keeps the -h range in step ---
#
# so the range end and the sentinel are two statements of one fact, and this
# test fails when they stop agreeing. Move the sentinel when you move the text.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$home" || exit 1

SENTINEL='end of --help text'

pass=0
fail=0

ok()   { printf 'ok       %-34s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad()  { printf 'FAIL     %-34s %s\n' "$1" "$2"; fail=$((fail + 1)); }

## Discovered, not listed: a sixth script that picks up the idiom is covered
## the day it does, without anyone remembering to add it here.
mapfile -t scripts < <(grep -lF "sed -n '2," -- *.sh | sort)

if [[ "${#scripts[@]}" -eq 0 ]]; then
    echo "no script uses the sed -n '2,NNp' --help idiom -- has it been replaced?" >&2
    exit 1
fi

for s in "${scripts[@]}"; do
    end=$(grep -oE "sed -n '2,[0-9]+p'" "$s" | grep -oE '[0-9]+' | tail -1)

    if [[ -z "$end" ]]; then
        bad "$s" "could not read the range end out of the -h case"
        continue
    fi

    ## The sentinel exists, exactly once. Two of them means an edit duplicated
    ## the block and the range now points into the wrong copy.
    n=$(grep -cF -- "$SENTINEL" "$s")
    if [[ "$n" -ne 1 ]]; then
        bad "$s: sentinel" "found $n, want exactly 1"
        continue
    fi

    ## The assertion this file exists for.
    line=$(grep -nF -- "$SENTINEL" "$s" | cut -d: -f1)
    if [[ "$line" -eq $((end + 1)) ]]; then
        ok "$s: range ends at sentinel" "2,${end}p"
    else
        bad "$s: range ends at sentinel" \
            "range ends $end so the sentinel belongs on $((end + 1)), found it on $line"
    fi

    ## No code inside the range. Catches the range being extended past the
    ## header, which prints shell source at anyone who typed --help.
    ## Compared as a string, not on exit status: `head` exits 0 on empty input,
    ## so the pipeline succeeds whether or not grep matched anything.
    leaked=$(sed -n "2,${end}p" "$s" | grep -nvE '^[[:space:]]*#|^[[:space:]]*$' | head -1)
    if [[ -n "$leaked" ]]; then
        bad "$s: range is all comment" "line $((${leaked%%:*} + 1)) is code: ${leaked#*:}"
    else
        ok "$s: range is all comment" "lines 2-${end}"
    fi

    ## The help actually renders. Guards the `sed 's/^# \?//'` strip and the
    ## exit status, neither of which the static checks above can see.
    if ! out=$(bash "$s" --help 2>/dev/null); then
        bad "$s: --help runs" "non-zero exit"
    elif [[ "$(wc -l <<<"$out")" -lt 5 ]]; then
        bad "$s: --help runs" "printed $(wc -l <<<"$out") lines, want at least 5"
    elif grep -qE '^#' <<<"$out"; then
        bad "$s: --help runs" "a leading # survived the strip"
    else
        ok "$s: --help runs" "$(wc -l <<<"$out") lines"
    fi
done

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
