#!/bin/bash
# Sourced library: the health verdict, read from logs/<node>/<check> against the
# baseline rather than from the Slurm drain reason. Shared by overall_report.sh
# and health-check.sh so the two cannot disagree about which nodes are failing.
# See docs/explanation/reading-the-whole-fleet.md#health-read-from-the-files.
#
# Reads $logs_dir, $valid_dir and $HEALTHCHECKS_DIR; call health_scan once, then
# read: have_baseline, gated_check, health_fail_count/health_fail_list per node,
# check_fail_nodes per check, no_baseline_checks, and health_scan_notes.
#
# health_section prints the HEALTH block both reports show. It needs
# report-format.sh sourced for compress, print_wrapped, plural and sort_list.

# shellcheck disable=SC2154  # logs_dir and valid_dir belong to the sourcing
# report, which is the only thing that knows where its tree is.
# shellcheck disable=SC2034  # health_fail_list is read by the sourcing report

declare -A gated_check base_hash check_fail_nodes
declare -A health_fail_list health_fail_count
declare -a no_baseline_checks health_scan_notes
have_baseline=0

health_scan_note() { health_scan_notes+=("$1"); }

## One awk for the set, not three processes per check file. The FNR window is
## node_health.sh's own: a whole-file match would catch a check that greps for
## the same words. See docs/reference/health-checks.md#the-check-file-format.
health_scan_checks() {
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
        gated_check["$name"]=1
    done

    local dangling h
    if [[ ${#gated_check[@]} -eq 0 ]]; then
        health_scan_note "No check files under $HEALTHCHECKS_DIR -- there is nothing to compare, so no health failure can be reported."
    elif [[ ! -d "$valid_dir" ]]; then
        dangling=""
        [[ -L "$valid_dir" ]] && dangling=" (the symlink points at $(readlink "$valid_dir"), which does not exist)"
        health_scan_note "No baseline: $valid_dir does not resolve$dangling. Every check would diff against a missing file, so the health verdict would be an artifact of the baseline rather than a description of the cluster, and is left out. Fix it first: rm -f $valid_dir && bash set-valid-default.sh <validated-node>"
    else
        have_baseline=1
        while read -r h f; do base_hash["${f##*/}"]="$h"; done < <(md5sum "$valid_dir"/* 2>/dev/null)
        for name in "${!gated_check[@]}"; do
            [[ -n "${base_hash[$name]}" ]] || no_baseline_checks+=("$name")
        done
    fi
}

# Every failing (node, check) pair, aggregated both ways, in one awk.
#
# The comparison is over one checksum per log file -- 21,888 of them on a
# 576-node fleet -- and a `while read` around that is the single most expensive
# thing a report can do: bash reads a pipe a byte at a time, which cost 5.3s of
# an 8.5s overall_report.sh run before this was moved out. awk returns the two
# aggregates already built, so bash only ever reads the failures, which are few.
# See docs/explanation/reading-the-whole-fleet.md#health-read-from-the-files.
## $1 is an optional node glob. Dropping non-matching nodes here rather than at
## each printing site is what keeps a report's node filter honest: the scan
## walks the whole of logs/ either way, because a per-check tally has to be
## built before it can be narrowed.
health_scan_filter() {
    local pat="$1" node chk n out
    [[ -z "$pat" || "$pat" == '*' ]] && return 0
    for node in "${!health_fail_count[@]}"; do
        # shellcheck disable=SC2053  # $pat is the caller's node glob
        [[ "$node" == $pat ]] && continue
        unset "health_fail_count[$node]" "health_fail_list[$node]"
    done
    for chk in "${!check_fail_nodes[@]}"; do
        out=""
        for n in ${check_fail_nodes[$chk]//,/ }; do
            # shellcheck disable=SC2053  # $pat is the caller's node glob
            [[ "$n" == $pat ]] && out+="${out:+,}$n"
        done
        if [[ -n "$out" ]]; then
            check_fail_nodes["$chk"]="$out"
        else
            unset "check_fail_nodes[$chk]"
        fi
    done
}

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
    health_scan_filter "$1"
}

# The HEALTH block, per check rather than per node: 60 nodes failing `bios` is
# one out-of-spec image, and one line. $1 caps how many checks are named before
# the tail collapses, $2 is the comma-separated never-checked list, $3 the flag
# that would print the rest.
# See docs/explanation/reading-the-whole-fleet.md#health-read-from-the-files.
health_section() {
    local cap="$1" never="$2" more="${3:---full}"
    local n_nodes_failing=${#health_fail_count[@]} n_checks=${#check_fail_nodes[@]}
    local shown hidden count name n_never

    [[ "$have_baseline" -eq 1 ]] || return 0
    printf '── HEALTH CHECKS ───────────────────────────────────────────\n'
    if [[ "$n_checks" -eq 0 ]]; then
        printf 'No check differs from the baseline on any node reported here.\n\n'
    else
        printf '%d %s failing on %d %s (logs/<node> against valid-config/default)\n\n' \
            "$n_checks" "$([[ "$n_checks" -eq 1 ]] && echo check || echo checks)" \
            "$n_nodes_failing" "$(plural "$n_nodes_failing")"
        shown=0; hidden=0
        while IFS='|' read -r count name; do
            if [[ "$shown" -ge "$cap" ]]; then
                ((hidden++)); continue
            fi
            ((shown++))
            printf '    %-24s %3d %s\n' "$name" "$count" "$(plural "$count")"
            print_wrapped "      " "$(compress "$(sort_list "${check_fail_nodes[$name]}")")" 2
        done < <(
            for name in "${!check_fail_nodes[@]}"; do
                printf '%s|%s\n' "$(count_list "${check_fail_nodes[$name]}")" "$name"
            done | sort -t'|' -k1,1nr -k2,2)
        [[ "$hidden" -gt 0 ]] &&
            printf '    ... %d more %s — rerun with %s\n' \
                "$hidden" "$([[ "$hidden" -eq 1 ]] && echo check || echo checks)" "$more"
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
        print_wrapped "    " "$(compress "$never")" 2
        echo
    fi
}
