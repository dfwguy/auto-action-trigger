#!/bin/bash
#
# Usage: tests/report-format-test.sh
#
# Holds report-format.sh's wrap_list equivalent to the awk it replaced.
#
# wrap_list decides where a node list breaks, and the rule it enforces is that
# a break never lands inside a [14,29,34] range -- because half a range is a
# string neither scontrol nor a paste into `pdsh -w` will take, and it looks
# exactly like a whole one. It was one awk per call until a 576-node
# overall_report.sh --full made that ~1700 forks, and it is now bash.
#
# A rewrite of a formatting primitive is the kind of change that passes review
# by inspection and is wrong in one case nobody typed. So the awk is kept here,
# verbatim, as the reference: the suite runs both over generated and hand-picked
# inputs and fails on any difference. Delete the reference and this test is
# worth nothing.
#
# Builds nothing and needs no cluster.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0
fail=0
ok()  { printf 'ok       %-46s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL     %-46s %s\n' "$1" "$2"; fail=$((fail + 1)); }

# shellcheck source=/dev/null
source "$home/report-format.sh"

## The implementation report-format.sh carried before the rewrite, unchanged.
wrap_reference() {
    awk -v text="$1" -v avail="$2" '
    BEGIN {
        if (avail < 20) avail = 20
        n = length(text); depth = 0; start = 1; line = ""
        for (i = 1; i <= n; i++) {
            c = substr(text, i, 1)
            if (c == "[") depth++
            else if (c == "]") depth--
            else if (c == "," && depth == 0) {
                emit(substr(text, start, i - start + 1))
                start = i + 1
            }
        }
        emit(substr(text, start, n - start + 1))
        if (line != "") print line
    }
    function emit(piece) {
        if (line != "" && length(line) + length(piece) > avail) {
            print line; line = ""
        }
        if (line == "") sub(/^ +/, "", piece)
        line = line piece
    }'
}

compare() {
    local text="$1" avail="$2" want got
    want=$(wrap_reference "$text" "$avail")
    wrap_list "$text" "$avail"
    got=$(printf '%s\n' "${WRAP_LINES[@]}")
    ## Both empty is a match: printf of an empty array still emits one line.
    [[ -z "$want" && "${#WRAP_LINES[@]}" -eq 0 ]] && return 0
    [[ "$want" == "$got" ]] && return 0
    printf '    text  [%s]\n    avail [%s]\n    awk   [%s]\n    bash  [%s]\n' \
        "$text" "$avail" "$want" "$got" >&2
    return 1
}

# ── The cases that carry the rule ─────────────────────────────────────────────
# Named rather than generated, because a failure here says which property broke.

declare -a widths=(5 10 20 25 33 47 80 100)

declare -a cases=(
    ""                                        # nothing to wrap
    "a"                                       # one entry, no comma
    ","                                       # a separator and no entries
    ",,"
    "a,,b"                                    # an empty entry between two real ones
    "a,"
    ",a"
    "n01,n02,n03"
    "n[1-3],m[4,5],o"                         # the whole point: commas inside ranges
    "a[1,2]"
    "a[1,2"                                   # never closed
    "a]1,2["                                  # closed before it opens
    "["
    "]"
    "x[a[b,c]d],y"                            # nested
    "   leading,   spaces,   here"            # stripped at a line start, kept mid-line
    "verylongsinglenodenamethatexceedsthewidthallbyitself-0123456789"
    "a,verylongsinglenodenamethatexceedsthewidthallbyitself-0123456789,b"
    "ink50-dh01-h01-[01-32],ink50-dh01-h02-[01-32],ink50-dh01-h03-[01-32]"
)

n=0
bad_cases=0
for text in "${cases[@]}"; do
    for avail in "${widths[@]}"; do
        n=$((n + 1))
        compare "$text" "$avail" || bad_cases=$((bad_cases + 1))
    done
done
if [[ "$bad_cases" -eq 0 ]]; then
    ok "named cases match the awk" "$n comparisons"
else
    bad "named cases match the awk" "$bad_cases of $n differ"
fi

# ── Generated, for the shapes nobody thinks to type ───────────────────────────
# Seeded, so a failure is reproducible rather than a flake somebody reruns.

if ! command -v python3 >/dev/null 2>&1; then
    ok "generated cases skipped" "python3 not on PATH"
else
    n=0
    bad_cases=0
    while IFS= read -r text; do
        for avail in 10 20 33 47 80 100; do
            n=$((n + 1))
            compare "$text" "$avail" || bad_cases=$((bad_cases + 1))
        done
    done < <(python3 -c '
import random
for seed in range(200):
    random.seed(seed)
    toks = []
    for _ in range(random.randint(1, 25)):
        r = random.random()
        if r < 0.3:
            toks.append("n%02d[%s]" % (random.randint(1, 99),
                        ",".join(str(random.randint(1, 40)) for _ in range(random.randint(1, 4)))))
        elif r < 0.4:
            toks.append("")
        else:
            toks.append("node-%s" % "".join(random.choice("abcdef0123456789")
                        for _ in range(random.randint(1, 12))))
    print(",".join(toks))')
    if [[ "$bad_cases" -eq 0 ]]; then
        ok "generated cases match the awk" "$n comparisons"
    else
        bad "generated cases match the awk" "$bad_cases of $n differ"
    fi
fi

# ── The fast path in print_wrapped ────────────────────────────────────────────
# It skips wrap_list entirely when the text already fits, so it has to produce
# the same line the slow path would.

# shellcheck disable=SC2034  # read by print_wrapped, from report-format.sh
REPORT_WIDTH=80
got=$(print_wrapped "label  " "short,list")
[[ "$got" == "label  short,list" ]] &&
    ok "print_wrapped one-line fast path" "$got" ||
    bad "print_wrapped one-line fast path" "got [$got]"

## Exactly at the width, and one over it: the boundary the fast path tests.
long=$(printf 'a%.0s' $(seq 1 73))
got=$(print_wrapped "label  " "$long")
[[ "$(printf '%s' "$got" | wc -l)" -eq 0 ]] &&
    ok "fast path takes a line that just fits" "80 columns exactly" ||
    bad "fast path takes a line that just fits" "wrapped when it should not"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
