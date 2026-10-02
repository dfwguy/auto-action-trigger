#!/bin/bash
#
# Shared presentation helpers for the fleet reports: node-list compression,
# unwrapped copyable node lists, prose wrapping, elision and pluralisation. Sourced by
# report_health.sh and report_overall.sh -- never executed.
#
# One copy, because the two drifting apart is how a node list stops pasting
# into scontrol. See docs/reference/scripts.md.
#
# Callers set REPORT_FULL=1 for their own --full; nothing elides while it is 1.

: "${REPORT_FULL:=0}"

# tput's terminfo default off a tty is what a redirect into a file wants.
REPORT_WIDTH="${COLUMNS:-}"
[[ -z "$REPORT_WIDTH" ]] && REPORT_WIDTH=$(tput cols 2>/dev/null)
[[ -z "$REPORT_WIDTH" || "$REPORT_WIDTH" -lt 60 ]] && REPORT_WIDTH=100

# Ranges rather than a bare comma list, for pasting into scontrol/clush -w. The
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

# The node filter a report takes: names, Slurm nodelists and globs in one
# argument list, expanded to plain patterns once so every mode matches names.
# See docs/explanation/reading-the-whole-fleet.md#three-spellings-of-a-node-list.
declare -a NODE_PATTERNS=('*') NODE_PATTERN_SRC=('*') NODE_PATTERN_HIT=(1)

node_filter_add() {
    NODE_PATTERNS+=("$1"); NODE_PATTERN_SRC+=("$2"); NODE_PATTERN_HIT+=(0)
}

node_filter_set() {
    local arg name
    NODE_PATTERNS=(); NODE_PATTERN_SRC=(); NODE_PATTERN_HIT=()
    for arg in "$@"; do
        [[ -z "$arg" ]] && continue
        if [[ "$arg" == *[\*\?]* ]]; then
            node_filter_add "$arg" "$arg"
        elif [[ "$arg" == *[\[,]* ]]; then
            ## A bracket or a comma is a nodelist, not a glob: a glob carries a
            ## `*` or a `?`. Expanded here, so a missing node is named below.
            while IFS= read -r name; do
                [[ -n "$name" ]] && node_filter_add "$name" "$name"
            done < <(scontrol show hostnames "$arg" 2>/dev/null || printf '%s\n' "$arg")
        else
            node_filter_add "${arg}*" "$arg"
        fi
    done
    [[ "${#NODE_PATTERNS[@]}" -eq 0 ]] && node_filter_glob '*'
    return 0
}

# One already-built glob, for a report whose own node walk is a path expansion
# of the same string and so cannot read a nodelist differently from this.
node_filter_glob() {
    NODE_PATTERNS=("$1"); NODE_PATTERN_SRC=("$1"); NODE_PATTERN_HIT=(1)
}

node_selected() {
    local node="$1" i
    for ((i = 0; i < ${#NODE_PATTERNS[@]}; i++)); do
        # shellcheck disable=SC2053  # NODE_PATTERNS holds the caller's globs
        if [[ "$node" == ${NODE_PATTERNS[i]} ]]; then
            NODE_PATTERN_HIT[i]=1
            return 0
        fi
    done
    return 1
}

# What the filter asked for and nothing answered. A typo and a node that has
# never reported are the same string here, and both read as a clean report.
node_filter_unmatched() {
    local i out=""
    for ((i = 0; i < ${#NODE_PATTERNS[@]}; i++)); do
        [[ "${NODE_PATTERN_HIT[i]}" -eq 1 ]] && continue
        [[ ",$out," == *",${NODE_PATTERN_SRC[i]},"* ]] && continue
        out+="${out:+,}${NODE_PATTERN_SRC[i]}"
    done
    printf '%s' "$out"
}

# Break a comma-separated list into chunks no wider than $2, into WRAP_LINES.
# Splits only at top-level commas: a break inside a [14,29,34] range yields two
# lists neither scontrol nor a copy-paste will take.
#
# Into an array rather than onto stdout, and in bash rather than in awk,
# because every caller is inside a per-node loop: a report printing 576 node
# blocks called this ~1700 times, and an awk plus the process substitution to
# read it back is two forks a call. tests/report-format-test.sh holds this
# equivalent to the awk it replaced.
declare -a WRAP_LINES
wrap_list() {
    local text="$1" avail="$2" piece line="" head rest acc="" opens closes
    (( avail < 20 )) && avail=20
    WRAP_LINES=()

    ## Split at every comma first -- finding them by pattern rather than
    ## walking each character, which in bash is quadratic.
    local -a parts=()
    rest="$text"
    while [[ "$rest" == *,* ]]; do
        head="${rest%%,*}"
        rest="${rest#*,}"
        parts+=("$head,")
    done
    parts+=("$rest")

    ## Then stitch back together any piece whose brackets are still open, so a
    ## split only ever lands at a top-level comma.
    local -a merged=()
    for piece in "${parts[@]}"; do
        acc+="$piece"
        opens="${acc//[^\[]/}"; closes="${acc//[^\]]/}"
        if (( ${#opens} == ${#closes} )); then merged+=("$acc"); acc=""; fi
    done
    [[ -n "$acc" ]] && merged+=("$acc")

    for piece in "${merged[@]}"; do
        if [[ -n "$line" ]] && (( ${#line} + ${#piece} > avail )); then
            WRAP_LINES+=("$line"); line=""
        fi
        [[ -z "$line" ]] && while [[ "$piece" == " "* ]]; do piece="${piece# }"; done
        line+="$piece"
    done
    [[ -n "$line" ]] && WRAP_LINES+=("$line")
    return 0
}

# Print "<label><text>" wrapped, continuation lines indented to match. $3 caps
# the line count for the informational sections; REPORT_FULL prints it all.
# This is for prose and check names. Node lists use print_node_list below:
# inserting a newline into one turns a copyable Slurm argument into several
# shell commands.
print_wrapped() {
    local label="$1" text="$2" max_lines="${3:-0}" cont first=1 chunk n=0
    [[ "$REPORT_FULL" -eq 1 ]] && max_lines=0
    ## Already one line: wrap_list would return it unchanged, so this is the
    ## same output without the awk -- which is otherwise a fork per call, and
    ## report_overall.sh --full makes three per node. Guarded on a leading
    ## space because that is the one thing wrap_list would have stripped.
    if (( ${#label} + ${#text} <= REPORT_WIDTH )) && [[ "$text" != " "* ]]; then
        printf '%s%s\n' "$label" "$text"
        return
    fi
    printf -v cont '%*s' "${#label}" ''
    wrap_list "$text" $(( REPORT_WIDTH - ${#label} ))
    for chunk in "${WRAP_LINES[@]}"; do
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
    done
}

# Print one compressed node list as one physical line. These lists are meant
# to be copied into scontrol, clush, or report_health.sh --refresh, so terminal
# width must never insert a newline into one. The terminal can scroll; a shell
# cannot infer that an indented continuation belongs to the preceding argument.
print_node_list() {
    printf '%s%s\n' "$1" "$2"
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
