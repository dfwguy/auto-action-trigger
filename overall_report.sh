#!/bin/bash
#
# Usage: overall_report.sh [--full] [--no-cache] [-o file] [pattern]
#
# Everything that is not working, with everything known about it, in one pass.
# A node that passes is left out -- this report is the exception list, so an
# empty one is the good outcome and says so in as many words.
#
#   --full            print every group, every node block and every reason. The
#                     default elides the tail of each so the report stays a
#                     fixed size as the cluster grows.
#   --no-cache        judge every node from its files, ignoring
#                     results/.result_cache.*. See
#                     docs/explanation/verdicts-and-the-cache.md#the-verdict-cache.
#   -o, --output <f>  also write the report to <f>, exactly as printed.
#   pattern           optional node-name filter, read the same way as
#                     status-check.sh's: a bare string matches every node whose
#                     name starts with it, so a rack prefix covers the whole
#                     rack, while a shell glob (dh01-rack0[12]*, *node05) is
#                     honored as written.
#
# Four sections, in the order they are usually needed:
#
#   BENCHMARKS  per column, the nodes with no passing result, grouped by the
#               verdict and the reason for it, largest group first. A column
#               every node passes is named on one line and not expanded.
#   HEALTH      per check, the nodes whose logs/<node>/<check> does not match
#               valid-config/default. Read from those files rather than from the
#               Slurm drain reason, so it is complete whether or not
#               DRAIN_AFTER_FAILED_HEALTH_CHECK is on.
#   NODES       one block per node with an outstanding column, worst first,
#               carrying every other thing known about it: Slurm state and drain
#               reason, the check that failed a prolog, our job in the queue,
#               failing health checks, and the last line of its own trace.
#   WHAT TO RUN NEXT
#               the commands that answer the questions this report raises.
#
# Slurm is asked three times for the whole fleet, never once per node: sinfo for
# state and drain reason, squeue for the queue, and scontrol to compress node
# lists and to expand another user's job.
#
# Read-only apart from -o. It submits nothing, drains nothing, resumes nothing.
# --- end of --help text; tests/help-text-test.sh keeps the -h range in step ---

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$home/settings.sh"
results_dir="$home/results"
logs_dir="$home/logs"
# shellcheck disable=SC2034  # read by health-scan.sh, which nothing follows at lint time
valid_dir="$home/valid-config/default"
jobs_dir="$JOBS_DIR"

full=0
report_file=""
args=()
while (($#)); do
    case "$1" in
        --full|-f)    full=1; shift ;;
        --no-cache)   export SCAN_CACHE=0; shift ;;
        -o|--output)
            [[ -n "$2" ]] || { echo "ERROR: $1 needs a file to write" >&2; exit 1; }
            report_file="$2"; shift 2 ;;
        -h|--help)    sed -n '2,42p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        -*)           echo "ERROR: unknown argument $1" >&2; exit 1 ;;
        *)            args+=("$1"); shift ;;
    esac
done

if [[ ${#args[@]} -gt 1 ]]; then
    echo "ERROR: only one node pattern is accepted, got: ${args[*]}" >&2
    exit 1
fi

pattern="${args[0]}"
if [[ -z "$pattern" ]]; then
    pattern='*'
elif [[ "$pattern" != *[\*\?\[]* ]]; then
    pattern="${pattern}*"
fi

# How much of each list is shown before it collapses to a count.
max_groups=6
max_blocks=12
max_checks=10
if [[ "$full" -eq 1 ]]; then
    max_groups=100000; max_blocks=100000; max_checks=100000
fi

for lib in report-format.sh verdict-scan.sh; do
    if [[ ! -f "$home/$lib" ]]; then
        echo "ERROR: $home/$lib is missing -- this report is assembled through it." >&2
        exit 1
    fi
done
# shellcheck disable=SC2034  # read by report-format.sh, sourced on the next line
REPORT_FULL="$full"
source "$home/report-format.sh"

if [[ ! -f "$PARSERS_DIR/verdict.sh" ]]; then
    echo "ERROR: $PARSERS_DIR/verdict.sh is missing -- it carries the pass/fail rule" >&2
    echo "       for every job, and without it nothing can be judged." >&2
    echo "       PARSERS=$PARSERS, from ${SETTINGS_FILE:-<no settings file found>}." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$PARSERS_DIR/verdict.sh"
# shellcheck source=/dev/null
source "$home/verdict-scan.sh"

# The slurm tools live behind a module and are absent from cron/ssh/trigger
# shells. Nothing here is fatal -- the files alone still carry a report, and
# every section that loses an answer says which one it lost.
if ! command -v sinfo >/dev/null 2>&1 && [[ -r /etc/profile.d/modules.sh ]]; then
    source /etc/profile.d/modules.sh >/dev/null 2>&1
    command -v module >/dev/null 2>&1 && module load slurm >/dev/null 2>&1
fi

declare -a notes   # printed under the title, before anything is judged
note() { notes+=("$1"); }

## ── Columns ───────────────────────────────────────────────────────────────
## Burn-in columns only while the phase is on, or they read NOT_RUN forever.

active_benchmarks="$BENCHMARKS"
setting_enabled "$RUN_BURNIN" && active_benchmarks="$BENCHMARKS $BURNIN"

declare -a columns
for job in $active_benchmarks; do
    ## See docs/explanation/sequencing.md#host-launched-jobs.
    sbatch="$jobs_dir/$job.sbatch"
    [[ -f "$sbatch" ]] || sbatch="$jobs_dir/$job.sh"
    if [[ ! -f "$sbatch" ]]; then
        note "'$job' is in BENCHMARKS but $jobs_dir has no $job.sbatch or $job.sh -- it is not reported below and nothing submits it."
        continue
    fi
    if grep -Fq "totalRuns" "$sbatch"; then
        totalRuns=$(grep -F totalRuns "$sbatch" | awk -F= '{print $2}' | tr -d '[:space:]')
    else
        totalRuns=1
    fi
    if [[ "$totalRuns" -eq 1 ]]; then
        columns+=("$job")
    else
        for ((r = 1; r <= totalRuns; r++)); do columns+=("${job}-run${r}"); done
    fi
done

if [[ ${#columns[@]} -eq 0 ]]; then
    echo "No active benchmark has a job file under $jobs_dir" >&2
    exit 1
fi

## ── Nodes ─────────────────────────────────────────────────────────────────

declare -a nodes excluded
for node_dir in "$results_dir"/$pattern/; do
    [[ -d "$node_dir" ]] || continue
    node_dir="${node_dir%/}"
    node="${node_dir##*/}"
    ## See docs/reference/settings.md#hosts-that-are-not-compute-nodes.
    node_out_of_reporting "$results_dir" "$node" && { excluded+=("$node"); continue; }
    nodes+=("$node")
done
if [[ ${#nodes[@]} -eq 0 ]]; then
    echo "No nodes under $results_dir match '${args[0]:-*}'" >&2
    exit 1
fi
[[ ${#excluded[@]} -gt 0 ]] &&
    note "Left out, not compute nodes: ${excluded[*]}"

## ── Slurm, once for the fleet ─────────────────────────────────────────────
## Reason last in the format string: a Slurm reason is free text with spaces
## and pipes are what separates the rest.

declare -A slurm_state slurm_setter slurm_when slurm_reason
slurm_default="unknown"
if command -v sinfo >/dev/null 2>&1; then
    while IFS='|' read -r n state setter when reason; do
        [[ -z "$n" || -n "${slurm_state[$n]}" ]] && continue
        slurm_state["$n"]="$state"
        slurm_setter["$n"]="$setter"
        slurm_when["$n"]="$when"
        [[ "$reason" == "none" || "$reason" == "(null)" ]] && reason=""
        slurm_reason["$n"]="$reason"
    done < <(sinfo -N -h -o '%N|%T|%u|%H|%E' 2>/dev/null)
    [[ ${#slurm_state[@]} -eq 0 ]] && {
        note "sinfo returned no nodes -- no state, no drain reason and no prolog verdict below."
        slurm_default="no-slurm"
    }
else
    note "sinfo is not on PATH even after 'module load slurm' -- no state, no drain reason and no prolog verdict below."
    slurm_default="no-slurm"
fi

# Ours are named bringup-<node> / burnin-<node>, so they map to a node without
# expanding a hostlist. Anyone else's needs scontrol, and there are few of them.
declare -A our_job foreign_job
have_queue=0
if command -v squeue >/dev/null 2>&1; then
    have_queue=1
    while IFS='|' read -r id state name user reason used nodelist; do
        [[ -z "$id" ]] && continue
        case "$name" in
            bringup-*|burnin-*)
                n="${name#bringup-}"; n="${n#burnin-}"
                if [[ "$state" == "RUNNING" ]]; then
                    our_job["$n"]="job $id RUNNING for $used"
                else
                    our_job["$n"]="job $id $state${reason:+ ($reason)} for $used"
                fi
                ;;
            *)
                [[ "$state" == "RUNNING" && -n "$nodelist" ]] || continue
                while IFS= read -r n; do
                    [[ -n "$n" ]] &&
                        foreign_job["$n"]="job $id ($name, $user) RUNNING for $used"
                done < <(scontrol show hostnames "$nodelist" 2>/dev/null)
                ;;
        esac
    done < <(squeue -h -o '%i|%T|%j|%u|%r|%M|%N' 2>/dev/null)
else
    note "squeue is not on PATH even after 'module load slurm' -- a running job cannot be told from a dead one, so both read INCOMPLETE, and nothing below says what is queued."
fi

# Which nodes have one of our batches executing now, so a mid-run partial file
# is not judged. A file, not a variable: the scan runs in workers.
running_file=$(mktemp) || exit 1
trap 'rm -f "$running_file"' EXIT
for n in "${!our_job[@]}"; do
    [[ "${our_job[$n]}" == *RUNNING* ]] && printf '%s\n' "$n"
done > "$running_file"

## ── Health checks, from the files rather than from Slurm ──────────────────
## Shared with health-check.sh, so the two cannot disagree about which nodes
## are failing. See docs/explanation/reading-the-whole-fleet.md#health-read-from-the-files.
if [[ ! -f "$home/health-scan.sh" ]]; then
    echo "ERROR: $home/health-scan.sh is missing -- it carries the health verdict" >&2
    echo "       this report's HEALTH section is built from." >&2
    exit 1
fi
## Declared here as well as in the library: nothing follows a `source` at lint
## time, so these would read as undefined at every use below.
declare -A health_fail_count health_fail_list
declare -a health_scan_notes
have_baseline=0
source "$home/health-scan.sh"
health_scan "$pattern"
for line in "${health_scan_notes[@]}"; do note "$line"; done

# A node with no logs/<node> at all has not been checked, which is not the same
# as passing. Builtins only -- this runs over the whole fleet.
declare -A never_checked
if [[ "$have_baseline" -eq 1 ]]; then
    for node in "${nodes[@]}"; do
        [[ -d "$logs_dir/$node" ]] || never_checked["$node"]=1
    done
fi

## ── What the node wrote down about itself ─────────────────────────────────
## One grep for the fleet, not one per node. The prolog line is the whole
## reason this report reads the trace at all: Slurm records `Prolog error` and
## no more, and the check that failed is named only here.
## See docs/explanation/reading-the-whole-fleet.md#a-prolog-drain-does-not-say-why.

declare -A trace_exit trace_exit_when prolog_why prolog_when trace_held trace_skipped
if compgen -G "$results_dir/*/trigger.log" >/dev/null 2>&1; then
    while IFS='|' read -r node kind when text; do
        case "$kind" in
            exit)    trace_exit["$node"]="$text"; trace_exit_when["$node"]="$when" ;;
            prolog)  prolog_why["$node"]="$text";  prolog_when["$node"]="$when"    ;;
            held)    trace_held["$node"]="$text" ;;
            skipped) trace_skipped["$node"]="$text" ;;
        esac
    done < <(
        grep -HE 'EXIT:|recover note: the pre-job check|recover held:|recover skipped:' \
             "$results_dir"/*/trigger.log 2>/dev/null |
        awk '
            { i = index($0, "/trigger.log:") }
            i == 0 { next }
            {
                path = substr($0, 1, i - 1)
                line = substr($0, i + 13)
                n = split(path, p, "/"); node = p[n]
                when = substr(line, 1, 19); text = substr(line, 21)
                kind = ""
                if (text ~ /recover note: the pre-job check/) {
                    kind = "prolog"
                    if (match(text, /\[[^]]*\]/))
                        text = substr(text, RSTART + 1, RLENGTH - 2)
                }
                else if (text ~ /recover held:/)    kind = "held"
                else if (text ~ /recover skipped:/) kind = "skipped"
                else if (text ~ /EXIT:/) { kind = "exit"; sub(/^.*EXIT: /, "", text) }
                if (kind != "") print node "|" kind "|" when "|" text
            }')
fi

# Drains cleared per node inside the recovery window, and what the last one was
# for. One awk over every recover.log; the format is in slurm-recovery.sh.
declare -A drains_recent drain_last
if compgen -G "$results_dir/*/recover.log" >/dev/null 2>&1; then
    while IFS='|' read -r node n last; do
        drains_recent["$node"]="$n"
        drain_last["$node"]="$last"
    done < <(
        awk -F'\t' -v cutoff="$(( $(date +%s) - ${RECOVER_WINDOW_HOURS:-24} * 3600 ))" '
            FNR == 1 { n = split(FILENAME, p, "/"); node = p[n - 1] }
            $1 ~ /^[0-9]+$/ && $1 >= cutoff { c[node]++; last[node] = $3 " drain, " $4 ", " $6 }
            END { for (x in c) print x "|" c[x] "|" last[x] }
        ' "$results_dir"/*/recover.log 2>/dev/null)
fi

## ── Judge every cell ──────────────────────────────────────────────────────
## Archives on, so a column between a rejected attempt and its retry reads
## RETRY rather than "never attempted"; metrics on, so a FAIL can say how far
## off it was. See docs/explanation/verdicts-and-the-cache.md#how-a-report-is-produced.

export SCAN_RESULTS_DIR="$results_dir"
export SCAN_COLUMNS="${columns[*]}"
export SCAN_RUNNING_FILE="$running_file"
export SCAN_ARCHIVES=1
export SCAN_METRICS=1

declare -A group_nodes group_metrics col_missing
declare -A node_outstanding node_cells scanned
while IFS="$SCAN_FS" read -r node col status reason metric; do
    scanned["$node,$col"]=1
    [[ "$status" == "DONE" ]] && continue

    (( col_missing["$col"]++ ))
    key="$col|$status|$reason"
    group_nodes["$key"]+="${group_nodes[$key]:+,}$node"
    ## Accumulated, not compared here: the range is one awk per printed group
    ## rather than one per cell, and only the printed groups pay for it.
    [[ "$metric" =~ ^-?[0-9]+([.][0-9]+)?$ ]] && group_metrics["$key"]+="$metric "

    node_outstanding["$node"]=1
    node_cells["$node"]+="${node_cells[$node]:+, }$col ($status)"
done < <(scan_fleet "${nodes[@]}")

# A cell with no row means a scan worker died, not a node that passed. Named,
# because a missing row and a pass look identical in a report that drops it.
for node in "${nodes[@]}"; do
    for col in "${columns[@]}"; do
        [[ -n "${scanned[$node,$col]}" ]] && continue
        (( col_missing["$col"]++ ))
        key="$col|NO_SCAN|the scan produced no row for this cell -- a worker died"
        group_nodes["$key"]+="${group_nodes[$key]:+,}$node"
        node_outstanding["$node"]=1
        node_cells["$node"]+="${node_cells[$node]:+, }$col (NO_SCAN)"
    done
done

## ── Rank the node blocks ──────────────────────────────────────────────────
## Worst first, so an elided report keeps the nodes nothing else will explain.
## See docs/explanation/reading-the-whole-fleet.md#the-order-node-blocks-come-in.

## Sets NODE_RANK rather than printing it -- $(node_rank ...) is a fork per
## node, and this runs over every node with a column outstanding.
NODE_RANK=0
node_rank() {
    local node="$1"
    local state="${slurm_state[$node]:-$slurm_default}"
    case "${state,,}" in
        *down*|*fail*|*unk*)          NODE_RANK=6; return ;;
        *drain*|*maint*|*reserv*)     NODE_RANK=5; return ;;
    esac
    [[ -n "${health_fail_count[$node]}" ]] && { NODE_RANK=4; return; }
    [[ -n "${our_job[$node]}" ]]       && { NODE_RANK=1; return; }
    [[ -n "${foreign_job[$node]}" ]]   && { NODE_RANK=2; return; }
    ## Nothing wrong with it, nothing running on it, and work outstanding.
    NODE_RANK=3
}

declare -a blocks ranked
for node in "${!node_outstanding[@]}"; do
    node_rank "$node"
    ranked+=("$NODE_RANK|$node")
done
## Guarded: `printf '%s\n'` with nothing to print still emits one empty line,
## which would become a block for a node named "".
if [[ ${#ranked[@]} -gt 0 ]]; then
    mapfile -t blocks < <(printf '%s\n' "${ranked[@]}" | sort -t'|' -k1,1nr -k2,2)
fi

## ── Emit ──────────────────────────────────────────────────────────────────

# "  [measured 590..641]" for a group's metrics, or nothing. The figures are
# whatever the column's own extract_metric() returned, so they carry the units
# named in daily-report.sh's metric block and none are printed here.
metric_range() {
    awk '{ for (i = 1; i <= NF; i++) {
               n++
               if (n == 1 || $i + 0 < lo + 0) lo = $i
               if (n == 1 || $i + 0 > hi + 0) hi = $i } }
         END { if (!n) exit
               if (lo == hi) printf "  [measured %s]", lo
               else          printf "  [measured %s..%s]", lo, hi }' <<< "$1"
}

emit_report() {
    local n_out=${#node_outstanding[@]}
    printf 'OVERALL REPORT — %d %s, %d benchmark %s, %s\n' \
        "${#nodes[@]}" "$(plural "${#nodes[@]}")" "${#columns[@]}" \
        "$([[ ${#columns[@]} -eq 1 ]] && echo column || echo columns)" \
        "$(date '+%F %T')"
    printf '%s, settings from %s\n' "$home" "${SETTINGS_FILE:-<none found>}"
    echo

    setting_enabled "$PAUSE_JOBS" &&
        note "PAUSE_JOBS=$PAUSE_JOBS in ${SETTINGS_FILE##*/} -- no benchmarks are being submitted, so nothing under BENCHMARKS will change until it is set to no."
    setting_enabled "$PAUSE_HEALTH_CHECKS" &&
        note "PAUSE_HEALTH_CHECKS=$PAUSE_HEALTH_CHECKS in ${SETTINGS_FILE##*/} -- node_health.sh is not running anywhere, so HEALTH below is a snapshot of whatever was true when the pause went on."

    if [[ ${#notes[@]} -gt 0 ]]; then
        for line in "${notes[@]}"; do print_wrapped "NOTE: " "$line"; done
        echo
    fi

    ## ── BENCHMARKS ──
    local clean="" col n key status reason shown hidden list count entry node line
    printf '── BENCHMARKS ──────────────────────────────────────────────\n'
    printf 'Nodes with no passing result, per column.\n\n'
    for col in "${columns[@]}"; do
        n=${col_missing[$col]:-0}
        if [[ "$n" -eq 0 ]]; then
            clean+="${clean:+, }$col"
            continue
        fi
        printf '%s — %d of %d %s\n' "$col" "$n" "${#nodes[@]}" "$(plural "${#nodes[@]}")"
        shown=0; hidden=0
        while IFS='|' read -r _ status reason; do
            key="$col|$status|$reason"
            list="${group_nodes[$key]}"
            count=$(count_list "$list")
            if [[ "$shown" -ge "$max_groups" ]]; then
                (( hidden += count )); continue
            fi
            ((shown++))
            printf '    %-11s %3d %s  %s' "$status" "$count" "$(plural "$count")" "${reason:-<no reason recorded>}"
            [[ -n "${group_metrics[$key]}" ]] && printf '%s' "$(metric_range "${group_metrics[$key]}")"
            printf '\n'
            print_wrapped "      " "$(compress "$(sort_list "$list")")" 3
        done < <(
            for key in "${!group_nodes[@]}"; do
                [[ "$key" == "$col|"* ]] || continue
                printf '%s|%s\n' "$(count_list "${group_nodes[$key]}")" "${key#*|}"
            done | sort -t'|' -k1,1nr -k2,2)
        [[ "$hidden" -gt 0 ]] &&
            printf '    ... %d more %s — rerun with --full\n' "$hidden" "$(plural "$hidden")"
        echo
    done
    if [[ -n "$clean" ]]; then
        print_wrapped "Every node passes: " "${clean// /}"
        echo
    fi

    ## ── HEALTH ──
    ## Rendered by health-scan.sh; `health-check.sh --summary` prints it too.
    health_section "$max_checks" \
        "$(printf '%s\n' "${!never_checked[@]}" | sort | paste -sd',' -)"

    ## ── NODES ──
    printf '── NODES ───────────────────────────────────────────────────\n'
    if [[ "$n_out" -eq 0 ]]; then
        printf 'Every node reported here passes every column. Nothing outstanding.\n\n'
    else
        printf '%d %s with an outstanding column, worst first.\n\n' \
            "$n_out" "$(plural "$n_out")"
        shown=0
        for entry in "${blocks[@]}"; do
            node="${entry#*|}"
            if [[ "$shown" -ge "$max_blocks" ]]; then continue; fi
            ((shown++))
            node_block "$node"
        done
        if [[ "$shown" -lt "$n_out" ]]; then
            printf '... %d more %s — rerun with --full\n\n' \
                "$(( n_out - shown ))" "$(plural "$(( n_out - shown ))")"
        fi
    fi

    ## ── WHAT TO RUN NEXT ──
    printf '── WHAT TO RUN NEXT ────────────────────────────────────────\n'
    printf '  bash trigger-log.sh                 why nothing is being submitted\n'
    printf '  bash health-check.sh --diff <node>  the health diff behind a check name above\n'
    printf '  bash status-check.sh -t <benchmark> one column, every node, pass included\n'
    printf '  bash daily-report.sh                the numbers behind every pass\n'
    printf '  sinfo -R                            every drained node, from Slurm itself\n'
}

# One node, everything known about it. Every line is "<label> <value>", so a
# block is grep-able and a missing line means that source had nothing to say.
node_block() {
    local node="$1"
    local state="${slurm_state[$node]:-$slurm_default}" reason="${slurm_reason[$node]}"
    printf '%s\n' "$node"
    printf '    slurm    %s' "$state"
    [[ -n "$reason" ]] && printf " — '%s'" "$reason"
    [[ -n "${slurm_setter[$node]}" && "${slurm_setter[$node]}" != "none" &&
       "${slurm_setter[$node]}" != "Unknown" ]] &&
        printf ' set by %s' "${slurm_setter[$node]}"
    [[ -n "${slurm_when[$node]}" && "${slurm_when[$node]}" != "Unknown" ]] &&
        printf ' at %s' "${slurm_when[$node]}"
    printf '\n'

    ## The one thing Slurm will not tell you. See
    ## docs/explanation/reading-the-whole-fleet.md#a-prolog-drain-does-not-say-why.
    if [[ "${reason,,}" =~ (prolog|epilog|rogue[[:space:]]?process) ]]; then
        if [[ -n "${prolog_why[$node]}" ]]; then
            printf '    prolog   the pre-job check failed on [%s], %s (results/%s/trigger.log)\n' \
                "${prolog_why[$node]}" "${prolog_when[$node]}" "$node"
        else
            printf '    prolog   nothing in results/%s/trigger.log names the check that failed.\n' "$node"
            if [[ -n "$RECOVER_PREJOB_LOGS" ]]; then
                printf '             Its log is node-local:  clush -w %s '"'"'grep FAIL $(ls -t %s/job.*.log | head -1)'"'"'\n' \
                    "$node" "$RECOVER_PREJOB_LOGS"
            else
                printf '             RECOVER_PREJOB_LOGS is empty, so nothing reads it. See docs/explanation/drain-recovery.md.\n'
            fi
        fi
    fi

    [[ -n "${trace_held[$node]}" ]]    && print_wrapped "    held     " "${trace_held[$node]}"
    [[ -n "${trace_skipped[$node]}" ]] && print_wrapped "    skipped  " "${trace_skipped[$node]}"
    [[ -n "${drains_recent[$node]}" ]] &&
        printf '    drains   %s cleared in the last %sh; last was a %s\n' \
            "${drains_recent[$node]}" "${RECOVER_WINDOW_HOURS:-24}" "${drain_last[$node]}"

    if [[ -n "${our_job[$node]}" ]]; then
        printf '    queue    %s\n' "${our_job[$node]}"
    elif [[ -n "${foreign_job[$node]}" ]]; then
        printf '    queue    not ours: %s\n' "${foreign_job[$node]}"
    elif [[ "$have_queue" -eq 1 ]]; then
        printf '    queue    nothing of ours queued or running here\n'
    fi

    if [[ -n "${health_fail_count[$node]}" ]]; then
        print_wrapped "    health   ${health_fail_count[$node]} failing: " \
            "$(elide "${health_fail_list[$node]}" "$max_checks")"
    elif [[ -n "${never_checked[$node]}" ]]; then
        printf '    health   never checked — no logs/%s\n' "$node"
    fi

    print_wrapped "    missing  " "${node_cells[$node]}" 3
    [[ -n "${trace_exit[$node]}" ]] &&
        print_wrapped "    trace    " "${trace_exit_when[$node]} EXIT: ${trace_exit[$node]}"
    echo
}

if [[ -n "$report_file" ]]; then
    mkdir -p "$(dirname "$report_file")" || exit 1
    emit_report | tee "$report_file"
    printf '\nWritten to: %s\n' "$report_file"
else
    emit_report
fi
