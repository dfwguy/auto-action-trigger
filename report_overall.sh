#!/bin/bash
#
# Usage: report_overall.sh [--details [--full]] [--no-cache] [-o file] [pattern]
#
# One line per node -- whether it is cycling, what Slurm calls it, then PASS or
# the names of what is not passing under each half -- grouped so that every node
# saying the same thing is one entry with one node list:
#
#   ---------------
#   ink50-dh01-h20-[03-07,11] (6)
#   ---------------
#   UP **** MIXED **** tests - allreduce hpl **** healthchecks - bios kernel-params
#   ---------------
#   ink50-dh01-h20-19 (1)
#   ---------------
#   DOWN **** DRAINED **** tests - PASS **** healthchecks - bios
#   ---------------
#   ink50-dh01-h20-[01-02,08-10,12-18] (12)
#   ---------------
#   UP **** IDLE **** tests - PASS **** healthchecks - PASS
#
# The first two fields are the node rather than the work on it. UP or DOWN is
# its own heartbeat and not a probe: DOWN means nothing has written
# results/<node>/.heartbeat in HEARTBEAT_STALE_MINUTES, so everything after it
# on the line is the last thing written rather than what is true now. The second
# is sinfo's state for the node, uppercased -- UNKNOWN when sinfo has no row for
# it, NO-SLURM when sinfo itself did not answer, neither of which is a state.
#
# Names, nothing else. Not why a benchmark has no pass and not how it failed --
# whether it was rejected, never attempted or is being retried is a question for
# --details, and putting it here would split one group of sixty into six of ten.
# All four fields are always spelled out, PASS under a half with nothing
# outstanding, so every line has one shape and no field is ever empty.
#
# A node that passes is still on the report, so this covers the whole fleet
# rather than only its exceptions, and the size of a group is the size of the
# incident. One line rather than two, so the grouping is over the whole verdict:
# a node failing hpl with clean checks and one failing hpl with a bad BIOS are
# two faults and must not fold together.
#
# A column that never ran and a column that was rejected read the same, because
# neither is passing. So do the checks on a node that has never been checked and
# on any node at all when there is no valid-config/default to compare against:
# nothing passed, so every gated check is named.
#
#   --details         the long report instead: per column, per check and per
#                     node, carrying the reason for every verdict, the Slurm
#                     state and drain, the check that failed a prolog, our job
#                     in the queue, and the last line of each node's own trace.
#   --full            with --details, print every group, every node block and
#                     every reason; the default elides the tail of each so the
#                     report stays a fixed size as the cluster grows. Implies
#                     --details.
#   --csv             one comma-separated line per node instead -- hostname,
#                     UP/DOWN, Slurm state, tests, healthchecks -- with the
#                     nodes that are UP, IDLE or ALLOCATED and passing both
#                     halves left out. No grouping, no legend and no notes:
#                     only the fields, in a form a spreadsheet takes.
#   --no-cache        judge every node from its files, ignoring
#                     results/.result_cache.*. See
#                     docs/explanation/verdicts-and-the-cache.md#the-verdict-cache.
#   -o, --output <f>  also write the report to <f>, exactly as printed. The
#                     directory has to exist; naming a path is a statement
#                     about where the report goes, and this creates nothing.
#   pattern           optional node-name filter, read the same way as
#                     report_job-status.sh's: a bare string matches every node whose
#                     name starts with it, so a rack prefix covers the whole
#                     rack, while a shell glob (dh01-rack0[12]*, *node05) is
#                     honored as written.
#
# The grouping is clubak (ClusterShell) or dshbak (pdsh), the pair
# report_job-status.sh already prints through. With neither installed the lines are
# printed one per node and the report says so.
#
# --details has four sections, in the order they are usually needed:
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
# Slurm is asked for the whole fleet, never once per node: sinfo for state and
# drain reason, squeue for the queue, and with --details also scontrol to
# compress node lists and expand another user's job.
#
# Read-only apart from -o. It submits nothing, drains nothing, resumes nothing.
# --- end of --help text; tests/help-text-test.sh keeps the -h range in step ---

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$home/settings.sh"
source "$home/fanout.sh"
results_dir="$RESULTS_DIR"
logs_dir="$HEALTH_LOG_DIR"
# shellcheck disable=SC2034  # read by health-scan.sh, which nothing follows at lint time
valid_dir="$VALID_CONFIG_DIR/default"
jobs_dir="$JOBS_DIR"

full=0
details=0
csv=0
report_file=""
args=()
while (($#)); do
    case "$1" in
        ## Nothing in the one-line report elides, so --full only means
        ## something with --details, and asking for it is asking for that.
        --full|-f)     full=1; details=1; shift ;;
        --details|-d)  details=1; shift ;;
        --csv)         csv=1; shift ;;
        --no-cache)    export SCAN_CACHE=0; shift ;;
        -o|--output)
            [[ -n "$2" ]] || { echo "ERROR: $1 needs a file to write" >&2; exit 1; }
            report_file="$2"; shift 2 ;;
        -h|--help)    sed -n '2,95p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        -*)           echo "ERROR: unknown argument $1" >&2; exit 1 ;;
        *)            args+=("$1"); shift ;;
    esac
done

if [[ "$csv" -eq 1 && "$details" -eq 1 ]]; then
    echo "ERROR: --csv is the one-line report as fields; --details is the long one." >&2
    echo "       Ask for one of them." >&2
    exit 1
fi

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

## Checked here rather than at the write at the end: this report is a scan of
## the whole fleet, and one that cannot be written has wasted it. Nothing is
## created -- see docs/how-to/export-a-report.md.
if [[ -n "$report_file" ]]; then
    report_dir=$(dirname "$report_file")
    if [[ ! -d "$report_dir" ]]; then
        echo "ERROR: $report_dir does not exist, so -o $report_file cannot be written." >&2
        echo "       Create it, or name a path that exists. Nothing was scanned." >&2
        exit 1
    fi
    if [[ ! -w "$report_dir" ]]; then
        echo "ERROR: $report_dir is not writable by $(id -un), so -o $report_file" >&2
        echo "       cannot be written. Nothing was scanned." >&2
        exit 1
    fi
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
## BURNIN never expands into per-run columns here -- it is reported as one
## accumulated-hours line instead. See docs/reference/settings.md#burn-in.

active_benchmarks="$BENCHMARKS"
show_burnin=0
setting_enabled "$RUN_BURNIN" && [[ -n "${BURNIN// /}" ]] && show_burnin=1

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

if [[ ${#columns[@]} -eq 0 && "$show_burnin" -eq 0 ]]; then
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

## The first field of every one-line entry, and only that report prints it.
## See docs/explanation/the-agent-and-the-watchdog.md#what-the-heartbeat-means.
declare -A node_down
if [[ "$details" -eq 0 ]]; then
    for node in "${nodes[@]}"; do
        heartbeat_stale "$results_dir" "$node" && node_down["$node"]=1
    done
    [[ ${#node_down[@]} -gt 0 ]] &&
        note "${#node_down[@]} of ${#nodes[@]} node(s) have written no heartbeat in ${HEARTBEAT_STALE_MINUTES}m and read DOWN below -- everything after that field on their line is the last thing written rather than what is true now. ./check_trigger-log.sh section 0 is why."
fi

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
        note "sinfo returned no nodes -- every Slurm state below reads NO-SLURM, with no drain reason and no prolog verdict behind it."
        slurm_default="no-slurm"
    }
else
    note "sinfo is not on PATH even after 'module load slurm' -- every Slurm state below reads NO-SLURM, with no drain reason and no prolog verdict behind it."
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
    note "squeue is not on PATH even after 'module load slurm' -- a running job cannot be told from a dead one, so both read INCOMPLETE, and no line below says what is queued."
fi

# Which nodes have one of our batches executing now, so a mid-run partial file
# is not judged. A file, not a variable: the scan runs in workers.
running_file=$(mktemp) || exit 1
trap 'rm -f "$running_file"' EXIT
for n in "${!our_job[@]}"; do
    [[ "${our_job[$n]}" == *RUNNING* ]] && printf '%s\n' "$n"
done > "$running_file"

## ── Health checks, from the files rather than from Slurm ──────────────────
## Shared with report_health.sh, so the two cannot disagree about which nodes
## are failing. See docs/explanation/reading-the-whole-fleet.md#health-read-from-the-files.
if [[ ! -f "$home/health-scan.sh" ]]; then
    echo "ERROR: $home/health-scan.sh is missing -- it carries the health verdict" >&2
    echo "       this report's HEALTH section is built from." >&2
    exit 1
fi
## Declared here as well as in the library: nothing follows a `source` at lint
## time, so these would read as undefined at every use below.
declare -A health_fail_count health_fail_list gated_check
declare -a health_scan_notes
have_baseline=0
source "$home/health-scan.sh"
node_filter_glob "$pattern"
health_scan
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
if [[ "$details" -eq 1 ]] && compgen -G "$results_dir/*/trigger.log" >/dev/null 2>&1; then
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

# Drains cleared per node inside the recovery window, what the last one was
# for, and the last named pre-job failure.  trigger.log is the live trace, but
# it rotates; field 7 in recover.log deliberately preserves the same cause.
# One awk over every recover.log; the format is in slurm-recovery.sh.
declare -A drains_recent drain_last recover_prolog_why
if [[ "$details" -eq 1 ]] && compgen -G "$results_dir/*/recover.log" >/dev/null 2>&1; then
    while IFS='|' read -r node n last cause; do
        drains_recent["$node"]="$n"
        drain_last["$node"]="$last"
        [[ -n "$cause" ]] && recover_prolog_why["$node"]="$cause"
    done < <(
        awk -F'\t' -v cutoff="$(( $(date +%s) - ${RECOVER_WINDOW_HOURS:-24} * 3600 ))" '
            FNR == 1 { n = split(FILENAME, p, "/"); node = p[n - 1] }
            $1 ~ /^[0-9]+$/ {
                if ($1 >= cutoff) { c[node]++; last[node] = $3 " drain, " $4 ", " $6 }
                ## Only a named failed pre-job check is useful here.  The
                ## "unnamed:" value records why recovery could not identify
                ## it and must not turn into a fictitious check name.
                if (tolower($6) ~ /(prolog|epilog|rogue[[:space:]]?process)/ &&
                    $7 != "" && $7 !~ /^unnamed:/)
                    cause[node] = $7
            }
            END { for (x in c) print x "|" c[x] "|" last[x] "|" cause[x] }
        ' "$results_dir"/*/recover.log 2>/dev/null)
fi

## ── Judge every cell ──────────────────────────────────────────────────────
## Archives on, so a column between a rejected attempt and its retry still reads
## FAIL rather than "never attempted"; metrics on, so a FAIL can say how far
## off it was. See docs/explanation/verdicts-and-the-cache.md#how-a-report-is-produced.

export SCAN_RESULTS_DIR="$results_dir"
export SCAN_COLUMNS="${columns[*]}"
export SCAN_RUNNING_FILE="$running_file"
export SCAN_ARCHIVES=1
## Only --details prints a [measured ..] range, and the flag is part of the
## cache key -- off, the default shares report_job-status.sh's cache file.
export SCAN_METRICS="$details"

declare -A group_nodes group_metrics col_missing
declare -A node_outstanding node_cells node_not_passing scanned
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
    ## Column order, which is the order one worker emits a node's rows in.
    node_not_passing["$node"]+="${node_not_passing[$node]:+ }$col"
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
        node_not_passing["$node"]+="${node_not_passing[$node]:+ }$col"
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
    [[ "$details" -eq 1 ]] || break
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
# named in report_benchmarks.sh's metric block and none are printed here.
metric_range() {
    awk '{ for (i = 1; i <= NF; i++) {
               n++
               if (n == 1 || $i + 0 < lo + 0) lo = $i
               if (n == 1 || $i + 0 > hi + 0) hi = $i } }
         END { if (!n) exit
               if (lo == hi) printf "  [measured %s]", lo
               else          printf "  [measured %s..%s]", lo, hi }' <<< "$1"
}

## ── The one-line report ───────────────────────────────────────────────────
## See docs/explanation/reading-the-whole-fleet.md#one-line-per-node.

## Guarded because a missing clubak empties stdout while the pipeline still
## exits 0 -- silently identical to "no nodes match".
brief_group() { cat; }
if [[ "$details" -eq 0 && "$csv" -eq 0 ]]; then
    if bak_resolve; then
        brief_group() { bak; }
    else
        note "neither clubak (ships with clush) nor dshbak (ships with pdsh) is on PATH -- printing one line per node instead of grouping the nodes that say the same thing. Install ClusterShell for the grouped form."
    fi
fi

## Sets BRIEF_LINE rather than printing it: $(...) here is two forks per node,
## and this runs over every node in the fleet rather than only the failing ones.
## Worst status first, in the order report_job-status.sh ranks them.
## Every gated check, for a node that has none of them passing.
brief_all_checks=""
if [[ ${#gated_check[@]} -gt 0 ]]; then
    brief_all_checks=$(printf '%s\n' "${!gated_check[@]}" | sort | paste -sd' ' -)
fi

BRIEF_LINE=""
BRIEF_REACH=""; BRIEF_STATE=""; BRIEF_TESTS=""; BRIEF_HEALTH=""
brief_line() {
    local node="$1"
    local tests="${node_not_passing[$node]}" health reach=UP
    local state="${slurm_state[$node]:-$slurm_default}"

    [[ -n "${node_down[$node]}" ]] && reach=DOWN

    if [[ "$have_baseline" -ne 1 || -n "${never_checked[$node]}" ]]; then
        ## Nothing was compared here, so nothing passed -- every gated check is
        ## outstanding, by the rule that puts a column nobody ran on the line.
        health="$brief_all_checks"
    else
        health="${health_fail_list[$node]//,/ }"
    fi

    BRIEF_REACH="$reach"
    BRIEF_STATE="${state^^}"
    BRIEF_TESTS="${tests:-PASS}"
    BRIEF_HEALTH="${health:-PASS}"
    BRIEF_LINE="$BRIEF_REACH **** $BRIEF_STATE **** tests - $BRIEF_TESTS **** healthchecks - $BRIEF_HEALTH"
}

## One line per node: "<node>: <N>H/<BURNIN_HOURS>H". Not part of the
## outstanding-cells grouping above -- a burn-in job mid-campaign is not a
## failure, so it has no place among reasons a column is not passing.
## See docs/explanation/burn-in-waveform.md.
print_burnin_section() {
    local node
    echo "BURN-IN"
    burnin_prepare
    for node in "${nodes[@]}"; do
        printf '%s: %s\n' "$node" "$(burnin_hours_cell "$node")"
    done
    echo
}

emit_brief() {
    local node line n_out=${#node_outstanding[@]}
    printf 'OVERALL — %d %s, %d benchmark %s, %s\n' \
        "${#nodes[@]}" "$(plural "${#nodes[@]}")" "${#columns[@]}" \
        "$([[ ${#columns[@]} -eq 1 ]] && echo column || echo columns)" \
        "$(date '+%F %T')"
    printf '%s, settings from %s\n' "$home" "${SETTINGS_FILE:-<none found>}"
    echo

    setting_disabled "$RUN_JOBS" &&
        note "RUN_JOBS=$RUN_JOBS in ${SETTINGS_FILE##*/} -- no benchmarks are being submitted, so no tests half below will change until it is set to yes."
    setting_disabled "$RUN_HEALTH_CHECKS" &&
        note "RUN_HEALTH_CHECKS=$RUN_HEALTH_CHECKS in ${SETTINGS_FILE##*/} -- node_health.sh is not running anywhere, so the health half is a snapshot of whatever was true when the pause went on."
    for line in "${notes[@]}"; do print_wrapped "NOTE: " "$line"; done
    [[ ${#notes[@]} -gt 0 ]] && echo

    ## The legend, so the line itself does not have to carry the words. Nothing
    ## below it is repeated per node, which is the point of putting it here.
    printf 'One line per node, grouped: the node itself, then what is not passing on it.\n'
    printf '  UP / DOWN - whether the node has written a heartbeat in %sm\n' \
        "$HEARTBEAT_STALE_MINUTES"
    printf "  <state> - sinfo's state for it, or NO-SLURM when sinfo did not answer\n"
    printf '  tests - <benchmark columns with no passing result>\n'
    printf '  healthchecks - <checks whose logs/<node> differs from valid-config/default>\n'
    printf 'Why any of them: bash report_overall.sh --details\n\n'

    for node in "${nodes[@]}"; do
        brief_line "$node"
        printf '%s: %s\n' "$node" "$BRIEF_LINE"
    done | brief_group
    echo

    [[ "$show_burnin" -eq 1 ]] && print_burnin_section

    printf '%d of %d %s %s a benchmark column outstanding.\n' \
        "$n_out" "${#nodes[@]}" "$(plural "${#nodes[@]}")" \
        "$([[ "$n_out" -eq 1 ]] && echo has || echo have)"
    printf '  bash report_overall.sh --details    the reason behind every name above\n'
    printf '  bash report_job-status.sh -t <benchmark> one column, every node, pass included\n'
    printf '  bash report_health.sh --diff <node>  the health diff behind a check name above\n'
    printf '  bash check_trigger-log.sh                 why nothing is being submitted\n'
}

## ── The CSV report ────────────────────────────────────────────────────────
## The same four fields, as columns rather than prose, and only for the nodes
## that are not fully healthy. No field can hold a comma: the state is one
## uppercased token and the two lists are space separated, which is why the
## separator is a comma and nothing here quotes.
emit_csv() {
    local node rows=0
    printf 'node,heartbeat,slurm,tests,healthchecks\n'
    for node in "${nodes[@]}"; do
        brief_line "$node"
        ## Passing on every count, and reachable -- nothing to copy out.
        [[ "$BRIEF_REACH" == UP && "$BRIEF_TESTS" == PASS && "$BRIEF_HEALTH" == PASS ]] &&
            [[ "$BRIEF_STATE" == IDLE || "$BRIEF_STATE" == ALLOCATED ]] && continue
        printf '%s,%s,%s,%s,%s\n' \
            "$node" "$BRIEF_REACH" "$BRIEF_STATE" "$BRIEF_TESTS" "$BRIEF_HEALTH"
        ((rows++))
    done
    ## stderr, so stdout stays paste-able: a header on its own is a result and
    ## has to be told apart from a report that produced nothing.
    [[ "$rows" -eq 0 ]] &&
        echo "All ${#nodes[@]} node(s) are UP, IDLE or ALLOCATED and passing both halves -- no CSV rows." >&2
    return 0
}

emit_report() {
    local n_out=${#node_outstanding[@]}
    printf 'OVERALL REPORT — %d %s, %d benchmark %s, %s\n' \
        "${#nodes[@]}" "$(plural "${#nodes[@]}")" "${#columns[@]}" \
        "$([[ ${#columns[@]} -eq 1 ]] && echo column || echo columns)" \
        "$(date '+%F %T')"
    printf '%s, settings from %s\n' "$home" "${SETTINGS_FILE:-<none found>}"
    echo

    setting_disabled "$RUN_JOBS" &&
        note "RUN_JOBS=$RUN_JOBS in ${SETTINGS_FILE##*/} -- no benchmarks are being submitted, so nothing under BENCHMARKS will change until it is set to yes."
    setting_disabled "$RUN_HEALTH_CHECKS" &&
        note "RUN_HEALTH_CHECKS=$RUN_HEALTH_CHECKS in ${SETTINGS_FILE##*/} -- node_health.sh is not running anywhere, so HEALTH below is a snapshot of whatever was true when the pause went on."

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
            print_node_list "      " "$(compress "$(sort_list "$list")")"
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
    ## Rendered by health-scan.sh; `report_health.sh --summary` prints it too.
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

    [[ "$show_burnin" -eq 1 ]] && print_burnin_section

    ## ── WHAT TO RUN NEXT ──
    printf '── WHAT TO RUN NEXT ────────────────────────────────────────\n'
    printf '  bash check_trigger-log.sh                  why nothing is being submitted\n'
    printf '  bash report_health.sh --diff <node>        the health diff behind a check name above\n'
    printf '  bash report_job-status.sh -t <benchmark>   one column, every node, pass included\n'
    printf '  bash report_benchmarks.sh                  the numbers behind every pass\n'
    printf '  sinfo -R                                   every drained node, from Slurm itself\n'
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
        elif [[ -n "${recover_prolog_why[$node]}" ]]; then
            printf '    prolog   the pre-job check failed on [%s] (results/%s/recover.log)\n' \
                "${recover_prolog_why[$node]}" "$node"
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

emit=emit_brief
[[ "$details" -eq 1 ]] && emit=emit_report
[[ "$csv" -eq 1 ]] && emit=emit_csv

if [[ -n "$report_file" ]]; then
    "$emit" | tee "$report_file"
    printf '\nWritten to: %s\n' "$report_file"
else
    "$emit"
fi
