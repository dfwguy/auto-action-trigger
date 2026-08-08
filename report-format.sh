#!/bin/bash
#
# Shared presentation helpers for the fleet reports: node-list compression,
# wrapping at range boundaries, elision and pluralisation. Sourced by
# health-check.sh and overall_report.sh -- never executed.
#
# One copy, because the two drifting apart is how a wrapped node list stops
# pasting into scontrol. See docs/reference/scripts.md.
#
# Callers set REPORT_FULL=1 for their own --full; nothing elides while it is 1.

: "${REPORT_FULL:=0}"

# tput's terminfo default off a tty is what a redirect into a file wants.
REPORT_WIDTH="${COLUMNS:-}"
[[ -z "$REPORT_WIDTH" ]] && REPORT_WIDTH=$(tput cols 2>/dev/null)
[[ -z "$REPORT_WIDTH" || "$REPORT_WIDTH" -lt 60 ]] && REPORT_WIDTH=100

# Ranges rather than a bare comma list, for pasting into scontrol/pdsh -w. The
# raw list is still valid input to most of the same tools, so falling back is ok.
compress() {
    local out
    out=$(scontrol show hostlistsorted "$1" 2>/dev/null)
    if [[ -n "$out" ]]; then
        printf '%s' "$out"
    else
        printf '%s' "$1"
    fi
}

plural() {
    [[ "$1" -eq 1 ]] && printf 'node' || printf 'nodes'
}

# Node order, for a list accumulated in whatever order it arrived. compress()
# sorts on its own, but only when scontrol answers, and its fallback prints the
# list exactly as built.
sort_list() {
    [[ -z "$1" ]] && return
    tr ',' '\n' <<< "$1" | sort -u | paste -sd',' -
}

count_list() {
    [[ -z "$1" ]] && { printf 0; return; }
    printf '%s' "$(( $(tr -cd ',' <<< "$1" | wc -c) + 1 ))"
}

# Break a comma-separated list into chunks no wider than $2. Splits only at
# top-level commas: a break inside a [14,29,34] range yields two lists neither
# scontrol nor a copy-paste will take. Caller supplies label and indent.
wrap_list() {
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

# Print "<label><list>" wrapped, continuation lines indented to match. $3 caps
# the line count for the informational sections; REPORT_FULL prints it all.
print_wrapped() {
    local label="$1" text="$2" max_lines="${3:-0}" cont first=1 chunk n=0
    [[ "$REPORT_FULL" -eq 1 ]] && max_lines=0
    printf -v cont '%*s' "${#label}" ''
    while IFS= read -r chunk; do
        ((n++))
        if [[ "$max_lines" -gt 0 && "$n" -gt "$max_lines" ]]; then
            printf '%s...\n' "$cont"
            break
        fi
        if [[ "$first" -eq 1 ]]; then
            printf '%s%s\n' "$label" "$chunk"; first=0
        else
            printf '%s%s\n' "$cont" "$chunk"
        fi
    done < <(wrap_list "$text" $(( REPORT_WIDTH - ${#label} )))
}

# Elide a ","-separated list down to $2 entries plus a count.
elide() {
    local list="$1" limit="$2"
    local -a items
    IFS=',' read -r -a items <<< "$list"
    if [[ "${#items[@]}" -le "$limit" ]]; then
        printf '%s' "$list"
        return
    fi
    local shown="" i
    for ((i = 0; i < limit; i++)); do
        shown+="${items[i]#"${items[i]%%[![:space:]]*}"}, "
    done
    printf '%s+%d more' "$shown" "$(( ${#items[@]} - limit ))"
}
