#!/bin/bash
# Sourced library: the health verdict, read from logs/<node>/<check> against the
# baseline rather than from the Slurm drain reason. Shared by report_overall.sh
# and report_health.sh so the two cannot disagree about which nodes are failing,
# and by admin_set-baseline.sh (health_check_names) so the baseline holds exactly
# the checks they judge. See docs/explanation/reading-the-whole-fleet.md#health-read-from-the-files.
#
# Reads $logs_dir, $valid_dir and $HEALTHCHECKS_DIR; call health_scan once, then
# read: have_baseline, gated_check, health_fail_count/health_fail_list per node,
# check_fail_nodes per check, no_baseline_checks, and health_scan_notes.
#
# health_section prints the HEALTH block both reports show. It needs
# report-format.sh sourced for compress, print_wrapped, plural and sort_list --
# and so does health_scan, which narrows to that library's node filter.

# shellcheck disable=SC2154  # logs_dir and valid_dir belong to the sourcing
# report, which is the only thing that knows where its tree is.
# shellcheck disable=SC2034  # health_fail_list is read by the sourcing report

declare -A gated_check base_hash check_fail_nodes
declare -A health_fail_list health_fail_count health_node_state
declare -a no_baseline_checks health_scan_notes
have_baseline=0

health_scan_note() { health_scan_notes+=("$1"); }

## The gated checks, one name per line: every check file in $HEALTHCHECKS_DIR
## except the informational ones. This is what a node is judged on, and so what a
## baseline has to hold -- admin_set-baseline.sh keeps exactly these names and
## nothing else, so a log the agent writes beside the check output (service.log)
## never ends up in the baseline. One definition, so the scan and the baseline
## cannot disagree about what a check is.
##
## One awk for the set, not three processes per check file. The FNR window is
## node_health.sh's own: a whole-file match would catch a check that greps for
## the same words. See docs/reference/health-checks.md#the-check-file-format.
health_check_names() {
    local f name
    declare -A informational
    while IFS= read -r f; do
        name="${f##*/}"; name="${name%.sh}"; name="${name#*-}"
        informational["$name"]=1
    done < <(awk 'FNR <= 10 && /^# informational: *yes/ { hit[FILENAME] = 1 }
                  END { for (f in hit) print f }' "$HEALTHCHECKS_DIR"/[0-9]*.sh 2>/dev/null)
    for f in "$HEALTHCHECKS_DIR"/[0-9]*.sh; do
        [[ -f "$f" ]] || continue
        name="${f##*/}"; name="${name%.sh}"; name="${name#*-}"
        ## Recorded and never drained on -- per-rack values cannot match one
        ## cluster-wide baseline. See docs/reference/health-checks.md#informational-checks.
        [[ -n "${informational[$name]}" ]] && continue
        printf '%s\n' "$name"
    done
}

health_scan_checks() {
    local f name
    while IFS= read -r name; do
        gated_check["$name"]=1
    done < <(health_check_names)

    local dangling h
    if [[ ${#gated_check[@]} -eq 0 ]]; then
        health_scan_note "No check files under $HEALTHCHECKS_DIR -- there is nothing to compare, so no health failure can be reported."
    elif [[ ! -d "$valid_dir" ]]; then
        dangling=""
        [[ -L "$valid_dir" ]] && dangling=" (the symlink points at $(readlink "$valid_dir"), which does not exist)"
        health_scan_note "No baseline: $valid_dir does not resolve$dangling. Every check would diff against a missing file, so the health verdict would be an artifact of the baseline rather than a description of the cluster, and is left out. Fix it first: rm -f $valid_dir && bash admin_set-baseline.sh <validated-node>"
    else
        have_baseline=1
        while read -r h f; do base_hash["${f##*/}"]="$h"; done < <(md5sum "$valid_dir"/* 2>/dev/null)
        for name in "${!gated_check[@]}"; do
            [[ -n "${base_hash[$name]}" ]] || no_baseline_checks+=("$name")
        done
    fi
}

## The caller's node filter, from report-format.sh. Dropping non-matching nodes
## here rather than at each printing site is what keeps it honest: the scan
## walks the whole of logs/ either way, because a per-check tally has to be
## built before it can be narrowed.
health_scan_filter() {
    local node chk n out
    [[ "${#NODE_PATTERNS[@]}" -eq 1 && "${NODE_PATTERNS[0]}" == '*' ]] && return 0
    for node in "${!health_fail_count[@]}"; do
        node_selected "$node" && continue
        unset "health_fail_count[$node]" "health_fail_list[$node]"
    done
    for chk in "${!check_fail_nodes[@]}"; do
        out=""
        for n in ${check_fail_nodes[$chk]//,/ }; do
            node_selected "$n" && out+="${out:+,}$n"
        done
        if [[ -n "$out" ]]; then
            check_fail_nodes["$chk"]="$out"
        else
            unset "check_fail_nodes[$chk]"
        fi
    done
}

# Every failing (node, check) pair, aggregated both ways, in one awk.
#
# The comparison is over one checksum per log file -- 21,888 of them on a
# 576-node fleet -- and a `while read` around that is the single most expensive
# thing a report can do: bash reads a pipe a byte at a time, which cost 5.3s of
# an 8.5s report_overall.sh run before this was moved out. awk returns the two
# aggregates already built, so bash only ever reads the failures, which are few.
# See docs/explanation/reading-the-whole-fleet.md#health-read-from-the-files.
health_scan() {
    health_scan_checks
    [[ "$have_baseline" -eq 1 ]] || return 0
    local gatedf basef kind key count list
    gatedf=$(mktemp) || return 0
    basef=$(mktemp) || { rm -f "$gatedf"; return 0; }
    printf '%s\n' "${!gated_check[@]}" > "$gatedf"
    md5sum "$valid_dir"/* 2>/dev/null > "$basef"

    ## Sorted by path, so a node's checks and a check's nodes both come out of
    ## awk in order and neither needs sorting again downstream.
    while IFS=$'\t' read -r kind key count list; do
        case "$kind" in
            N) health_fail_count["$key"]="$count"; health_fail_list["$key"]="$list" ;;
            C) check_fail_nodes["$key"]="$list" ;;
        esac
    done < <(
        find "$logs_dir" -mindepth 2 -maxdepth 2 -type f -print0 2>/dev/null |
        sort -z |
        xargs -0 -r md5sum 2>/dev/null |
        awk -v gatedf="$gatedf" -v basef="$basef" -v logs="$logs_dir/" '
            FILENAME == gatedf { gated[$0] = 1; next }
            FILENAME == basef  { n = substr($0, 35); sub(/.*\//, "", n)
                                 base[n] = substr($0, 1, 32); next }
            ## Fixed offsets, not fields: md5sum prints a 32-char digest, two
            ## spaces, then a path that may contain spaces of its own.
            {
                p = substr($0, 35)
                if (substr(p, 1, length(logs)) != logs) next
                rest = substr(p, length(logs) + 1)
                i = index(rest, "/")
                if (i == 0) next
                node = substr(rest, 1, i - 1); chk = substr(rest, i + 1)
                if (!(chk in gated) || !(chk in base)) next
                if (substr($0, 1, 32) == base[chk]) next
                nfail[node] = nfail[node] (nfail[node] ? "," : "") chk
                ncount[node]++
                cfail[chk] = cfail[chk] (cfail[chk] ? "," : "") node
            }
            END {
                for (n in nfail) printf "N\t%s\t%d\t%s\n", n, ncount[n], nfail[n]
                for (c in cfail) printf "C\t%s\t0\t%s\n", c, cfail[c]
            }' "$gatedf" "$basef" -
    )
    rm -f "$gatedf" "$basef"
    health_scan_filter
}

# One check per line, largest first, node list under each. Reads `count|name|
# nodes` rows on stdin, already sorted, and honours the caller's cap.
health_section_rows() {
    local shown=0 hidden=0 count name list
    while IFS='|' read -r count name list; do
        if [[ "$shown" -ge "$cap" ]]; then
            ((hidden++)); continue
        fi
        ((shown++))
        printf '    %-24s %3d %s\n' "$name" "$count" "$(plural "$count")"
        print_node_list "      " "$(compress "$(sort_list "$list")")"
    done
    [[ "$hidden" -gt 0 ]] &&
        printf '    ... %d more %s — rerun with %s\n' \
            "$hidden" "$([[ "$hidden" -eq 1 ]] && echo check || echo checks)" "$more"
    return 0
}

# The HEALTH block, per check rather than per node: 60 nodes failing `bios` is
# one out-of-spec image, and one line. $1 caps how many checks are named before
# the tail collapses, $2 is the comma-separated never-checked list, $3 the flag
# that would print the rest, $4 splits the block by Slurm state -- for which the
# caller fills health_node_state.
# See docs/explanation/reading-the-whole-fleet.md#health-read-from-the-files.
health_section() {
    local cap="$1" never="$2" more="${3:---full}" by_state="${4:-0}"
    local n_nodes_failing=${#health_fail_count[@]} n_checks=${#check_fail_nodes[@]}
    local name n_never node state key n_state

    [[ "$have_baseline" -eq 1 ]] || return 0
    printf '── HEALTH CHECKS ───────────────────────────────────────────\n'
    if [[ "$n_checks" -eq 0 ]]; then
        printf 'No check differs from the baseline on any node reported here.\n\n'
    elif [[ "$by_state" -eq 1 ]]; then
        ## The same failing check means different things on a node still taking
        ## work and one already out of the queue, and the split says which
        ## nodes a drain would actually cover.
        declare -A state_check state_nodes seen_node
        for name in "${!check_fail_nodes[@]}"; do
            for node in ${check_fail_nodes[$name]//,/ }; do
                state="${health_node_state[$node]:-unknown}"
                state_check["$state|$name"]+="$node,"
                ## Once per node, not once per check it failed, or the block
                ## header counts a node with 38 failures as 38 nodes.
                [[ -n "${seen_node[$node]}" ]] && continue
                seen_node["$node"]=1
                state_nodes["$state"]+="$node,"
            done
        done
        printf '%d %s failing on %d %s, by Slurm state (logs/<node> against valid-config/default)\n' \
            "$n_checks" "$([[ "$n_checks" -eq 1 ]] && echo check || echo checks)" \
            "$n_nodes_failing" "$(plural "$n_nodes_failing")"
        while IFS='|' read -r n_state state; do
            printf '\nSlurm state: %s — %d %s\n' "$state" "$n_state" "$(plural "$n_state")"
            health_section_rows < <(
                for key in "${!state_check[@]}"; do
                    [[ "${key%%|*}" == "$state" ]] || continue
                    printf '%s|%s|%s\n' "$(count_list "${state_check[$key]%,}")" \
                        "${key#*|}" "${state_check[$key]%,}"
                done | sort -t'|' -k1,1nr -k2,2)
        done < <(
            for state in "${!state_nodes[@]}"; do
                printf '%s|%s\n' "$(count_list "${state_nodes[$state]%,}")" "$state"
            done | sort -t'|' -k1,1nr -k2,2)
        echo
    else
        printf '%d %s failing on %d %s (logs/<node> against valid-config/default)\n\n' \
            "$n_checks" "$([[ "$n_checks" -eq 1 ]] && echo check || echo checks)" \
            "$n_nodes_failing" "$(plural "$n_nodes_failing")"
        health_section_rows < <(
            for name in "${!check_fail_nodes[@]}"; do
                printf '%s|%s|%s\n' "$(count_list "${check_fail_nodes[$name]}")" \
                    "$name" "${check_fail_nodes[$name]}"
            done | sort -t'|' -k1,1nr -k2,2)
        echo
    fi
    if [[ ${#no_baseline_checks[@]} -gt 0 ]]; then
        printf 'No entry in %s — %d %s can never pass:\n' "$valid_dir" \
            "${#no_baseline_checks[@]}" \
            "$([[ ${#no_baseline_checks[@]} -eq 1 ]] && echo check || echo checks)"
        print_wrapped "    " "$(printf '%s\n' "${no_baseline_checks[@]}" | sort | paste -sd',' -)"
        echo
    fi
    if [[ -n "$never" ]]; then
        n_never=$(count_list "$never")
        printf 'Never checked — %d %s with no logs/<node> at all:\n' \
            "$n_never" "$(plural "$n_never")"
        print_node_list "    " "$(compress "$never")"
        echo
    fi
}
