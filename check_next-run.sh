#!/bin/bash
#
# Usage: check_next-run.sh [--tests] [--healthchecks] [node-pattern]
#
# When the fleet next does something. Each node is placed in a bucket by how
# long it is until its next benchmark submission and its next health check --
# "soon", then one bucket per hour -- and nodes sharing a bucket are grouped
# into one compressed node list by clubak.
#
#   -t, --tests          the benchmark section only
#   -H, --healthchecks   the health check section only
#                        With neither, both sections are printed.
#
#   --no-cache           judge every node from its files, ignoring
#                        results/.result_cache.*, exactly as report_job-status.sh
#                        means it.
#
#   pattern              node filter, same rules as report_job-status.sh: a bare
#                        string matches by prefix, globs are honored as
#                        written.
#
# Read-only, and derived: it submits nothing and changes nothing. The times are
# the arithmetic the gates on the node do, over the same files, so a node that
# reads "soon" here is one whose next cycle acts.
#
# Three answers are not times, and each is its own group:
#
#   not cycling   the heartbeat is stale, so nothing on that node reaches a
#                 cadence gate at all and no time below it means anything
#   waiting       a job of ours is already out, and the node submits nothing
#                 more until it finishes
#   nothing due   every benchmark passes, or the health cadence is switched off
#
# See docs/how-to/see-what-fires-next.md.
# --- end of --help text; tests/help-text-test.sh keeps the -h range in step ---

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$home/settings.sh"
source "$home/fanout.sh"
results_dir="$RESULTS_DIR"
logs_dir="$HEALTH_LOG_DIR"

want_tests=0
want_health=0
args=()
while (($#)); do
    case "$1" in
        -t|--tests)                want_tests=1; shift ;;
        -H|--healthchecks|--health) want_health=1; shift ;;
        --no-cache)                export SCAN_CACHE=0; shift ;;
        -h|--help) sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        -*) echo "ERROR: unrecognised option '$1'" >&2; exit 2 ;;
        *)  args+=("$1"); shift ;;
    esac
done
if [[ "$want_tests" -eq 0 && "$want_health" -eq 0 ]]; then
    want_tests=1
    want_health=1
fi

pattern="${args[0]}"
if [[ -z "$pattern" ]]; then
    pattern='*'
elif [[ "$pattern" != *[\*\?\[]* ]]; then
    pattern="${pattern}*"
fi

## Not a tab, for the reason verdict-scan.sh gives: `read` eats empty fields
## split on whitespace, and a label here is allowed to be empty.
ROW_FS=$'\037'

declare -a nodes excluded
for node_dir in "$results_dir"/$pattern/; do
    [[ -d "$node_dir" ]] || continue
    node_dir="${node_dir%/}"
    node="${node_dir##*/}"
    ## See docs/reference/settings.md#hosts-that-are-not-compute-nodes.
    node_out_of_reporting "$results_dir" "$node" && { excluded+=("$node"); continue; }
    nodes+=("$node")
done
if [[ ${#excluded[@]} -gt 0 ]]; then
    echo "NOTE: left out, not compute nodes: ${excluded[*]}" >&2
fi
if [[ ${#nodes[@]} -eq 0 ]]; then
    echo "No nodes under $results_dir match '${args[0]:-*}'" >&2
    exit 1
fi

## ── Buckets ───────────────────────────────────────────────────────────────
##
## The key sorts the groups and the label is what the reader gets, so two nodes
## due at 11 and at 51 minutes share a key and print once.
## See docs/how-to/see-what-fires-next.md#how-the-buckets-are-chosen.
KEY_STALE=-3
KEY_WAITING=-2
KEY_NEVER=999999999

## A cadence gate that has already expired is not "in a minute": the node acts
## on its next tick, and the tick is a calendar timer plus its spread.
SOON=$(( AGENT_INTERVAL_MINUTES * 90 ))

bucket_key() {
    local s="$1"
    if [[ "$s" -le "$SOON" ]]; then printf '0'; else printf '%s' $(( ((s + 3599) / 3600) * 3600 )); fi
}
bucket_when() {
    local s="$1"
    if [[ "$s" -le "$SOON" ]]; then printf 'soon'; else printf 'within %dh' $(( (s + 3599) / 3600 )); fi
}

## clubak groups identical lines but orders its blocks by nodeset, and soonest
## first is the whole point here -- so it is fed one bucket at a time.
## See docs/reference/scripts.md#grouping-identical-rows.
GROUPED=1
bak_resolve || GROUPED=0
group() { if [[ "$GROUPED" -eq 1 ]]; then bak; else cat; fi; }
if [[ "$GROUPED" -eq 0 ]]; then
    echo "NOTE: neither clubak (ships with clush) nor dshbak (ships with pdsh)" >&2
    echo "      is on PATH -- printing one line per node instead of grouping" >&2
    echo "      the nodes that fire together. Install ClusterShell to group." >&2
fi

## $1 the section title, $2 a file of <key><FS><node>: <label> rows.
print_buckets() {
    local k
    printf '%s\n\n' "$1"
    while read -r k; do
        awk -F"$ROW_FS" -v k="$k" '$1 == k { print $2 }' "$2" | sort | group
    done < <(cut -d"$ROW_FS" -f1 "$2" | sort -un)
    printf '\n'
}

row() { printf '%s%s%s: %s\n' "$1" "$ROW_FS" "$2" "$3"; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
now=$(date +%s)

## ── When each node next submits a benchmark ───────────────────────────────

## The window launch_job.sh would apply to one result file, given the number of
## .failN archives beside it. Into RETRY_WINDOW rather than onto stdout: this
## runs once per cell, and a subshell per cell is a fork per cell.
## See docs/explanation/sequencing.md#backing-off-a-job-that-keeps-failing.
RETRY_WINDOW=0
retry_window() {
    local cap
    RETRY_WINDOW=$(( RETRY_INTERVAL_HOURS * 3600 ))
    setting_enabled "$RETRY_BACKOFF" || return 0
    cap=0
    [[ "$RETRY_BACKOFF_MAX_HOURS" =~ ^[0-9]+$ ]] && cap=$(( RETRY_BACKOFF_MAX_HOURS * 3600 ))
    [[ "$cap" -lt "$RETRY_WINDOW" ]] && return 0
    RETRY_WINDOW=$(( RETRY_WINDOW + $1 * 3600 ))
    [[ "$RETRY_WINDOW" -gt "$cap" ]] && RETRY_WINDOW="$cap"
    return 0
}

tests_section() {
    local active job sbatch totalRuns r col node key file st due best bestcol show_burnin
    local -a columns=()
    local -A cell=() mtime=() fails=()
    : > "$tmp/tests"

    ## BURNIN never expands into per-run columns here -- see
    ## docs/reference/settings.md#burn-in. show_burnin is a separate,
    ## unnamed-job "burn-in due" row per node, appended below.
    active="$BENCHMARKS"
    show_burnin=0
    setting_enabled "$RUN_BURNIN" && [[ -n "${BURNIN// /}" ]] && show_burnin=1

    for job in $active; do
        ## See docs/explanation/sequencing.md#host-launched-jobs.
        sbatch="$JOBS_DIR/$job.sbatch"
        [[ -f "$sbatch" ]] || sbatch="$JOBS_DIR/$job.sh"
        [[ -f "$sbatch" ]] || continue
        totalRuns=1
        if grep -Fq "totalRuns" "$sbatch"; then
            totalRuns=$(grep -F totalRuns "$sbatch" | head -1 | awk -F= '{print $2}' | tr -d '[:space:]')
        fi
        [[ "$totalRuns" =~ ^[0-9]+$ ]] && [[ "$totalRuns" -gt 0 ]] || totalRuns=1
        if [[ "$totalRuns" -eq 1 ]]; then
            columns+=("$job")
        else
            for ((r = 1; r <= totalRuns; r++)); do columns+=("${job}-run${r}"); done
        fi
    done
    if [[ ${#columns[@]} -eq 0 && "$show_burnin" -eq 0 ]]; then
        echo "NOTE: no active benchmark has a job file under $JOBS_DIR -- nothing can fire." >&2
        return
    fi
    if [[ ! -f "$PARSERS_DIR/verdict.sh" ]]; then
        echo "ERROR: $PARSERS_DIR/verdict.sh is missing, so no result can be judged" >&2
        echo "       and 'passing' cannot be told from 'due now'. PARSERS=$PARSERS." >&2
        return
    fi
    source "$PARSERS_DIR/verdict.sh"
    # shellcheck source=/dev/null
    source "$home/verdict-scan.sh"

    export SCAN_RESULTS_DIR="$results_dir"
    export SCAN_COLUMNS="${columns[*]}"
    export SCAN_RUNNING_FILE=""
    export SCAN_ARCHIVES=0   # a re-queued column and NOT_RUN are one answer here
    export SCAN_METRICS=0
    while IFS="$SCAN_FS" read -r node col st _; do
        cell["$node/$col"]="$st"
    done < <(scan_fleet "${nodes[@]}")

    ## One sweep for the fleet rather than a stat per cell: the current file's
    ## age is the cadence, and the .failN count beside it is the backoff.
    ## See docs/explanation/sequencing.md#backing-off-a-job-that-keeps-failing.
    local p t base
    while IFS="$ROW_FS" read -r p t; do
        base="${p%.txt}"
        if [[ "$base" =~ \.fail[0-9]+$ ]]; then
            (( fails["${base%.fail*}"]++ ))
        else
            mtime["$base"]="${t%.*}"
        fi
    done < <(find "$results_dir" -mindepth 2 -maxdepth 2 -name '*.txt' \
                  -printf "%P$ROW_FS%T@\n" 2>/dev/null)

    if setting_disabled "$RUN_JOBS"; then
        echo "NOTE: RUN_JOBS=$RUN_JOBS in ${SETTINGS_FILE##*/} -- nothing is being" >&2
        echo "      submitted, so the benchmark times below are when each node WOULD" >&2
        echo "      have fired, not when it will." >&2
    fi

    for node in "${nodes[@]}"; do
        if heartbeat_stale "$results_dir" "$node"; then
            row "$KEY_STALE" "$node" "not cycling — no gate here is reached, so nothing fires" >> "$tmp/tests"
            continue
        fi
        if [[ -f "$results_dir/$node/.in-flight" ]]; then
            ## The job id is deliberately not in the line: it differs per node,
            ## and a group of one is not a group.
            local ijob irun iepoch
            IFS=$'\t' read -r _ ijob irun _ iepoch < "$results_dir/$node/.in-flight"
            [[ "$iepoch" =~ ^[0-9]+$ ]] || iepoch="$now"
            row "$KEY_WAITING" "$node" \
                "waiting on $ijob run $irun, out for $(( (now - iepoch) / 60 ))m" >> "$tmp/tests"
            continue
        fi

        best=""; bestcol=""
        for col in "${columns[@]}"; do
            [[ "${cell["$node/$col"]:-NOT_RUN}" == "DONE" ]] && continue
            file="$node/$col"
            if [[ -z "${mtime[$file]:-}" ]]; then
                due=0
            else
                retry_window "${fails[$file]:-0}"
                due=$(( mtime[$file] + RETRY_WINDOW - now ))
                [[ "$due" -lt 0 ]] && due=0
            fi
            if [[ -z "$bestcol" || "$due" -lt "$best" ]]; then best="$due"; bestcol="$col"; fi
        done

        if [[ -z "$bestcol" ]]; then
            row "$KEY_NEVER" "$node" "nothing due — every benchmark passes here" >> "$tmp/tests"
        else
            key=$(bucket_key "$best")
            row "$key" "$node" "$(bucket_when "$best") — $bestcol" >> "$tmp/tests"
        fi

        ## Earliest due-time across any still-eligible BURNIN job -- not which
        ## job the round-robin would actually pick next, which is a fairness
        ## computation this deliberately does not re-derive a third time. See
        ## actions/launch_job.sh's burnin_order() and
        ## docs/explanation/sequencing.md#burn-in.
        if [[ "$show_burnin" -eq 1 ]]; then
            local bjob blaunch btotal br bfile bdue bbest=""
            for bjob in $BURNIN; do
                blaunch=$(_scan_job_launcher "$bjob") || continue
                btotal=$(_scan_job_total_runs "$blaunch")
                for ((br = 1; br <= btotal; br++)); do
                    if [[ "$btotal" -eq 1 ]]; then
                        bfile="$node/$bjob"
                    else
                        bfile="$node/$bjob-run${br}"
                    fi
                    verdict "$bjob" "$results_dir/$bfile.txt"
                    [[ "$VERDICT_STATUS" == "DONE" ]] && continue
                    if [[ -z "${mtime[$bfile]:-}" ]]; then
                        bdue=0
                    else
                        retry_window "${fails[$bfile]:-0}"
                        bdue=$(( mtime[$bfile] + RETRY_WINDOW - now ))
                        [[ "$bdue" -lt 0 ]] && bdue=0
                    fi
                    [[ -z "$bbest" || "$bdue" -lt "$bbest" ]] && bbest="$bdue"
                    break
                done
            done
            if [[ -n "$bbest" ]]; then
                key=$(bucket_key "$bbest")
                row "$key" "$node" "$(bucket_when "$bbest") — burn-in ($(burnin_hours_cell "$node"))" >> "$tmp/tests"
            fi
        fi
    done

    print_buckets "TESTS — when each node next submits a benchmark" "$tmp/tests"
}

## ── When each node next runs its health checks ────────────────────────────

health_section() {
    local node stamp epoch status interval due key
    : > "$tmp/health"

    if setting_disabled "$RUN_HEALTH_CHECKS"; then
        echo "NOTE: RUN_HEALTH_CHECKS=$RUN_HEALTH_CHECKS in ${SETTINGS_FILE##*/} -- no" >&2
        echo "      checks run, so the times below are when each node WOULD have run." >&2
    fi

    for node in "${nodes[@]}"; do
        if heartbeat_stale "$results_dir" "$node"; then
            row "$KEY_STALE" "$node" "not cycling — no gate here is reached, so nothing fires" >> "$tmp/health"
            continue
        fi
        if [[ -f "$logs_dir/$node/refresh" ]]; then
            row 0 "$node" "soon — a refresh is queued here by hand" >> "$tmp/health"
            continue
        fi
        stamp="$logs_dir/$node/.last-check"
        epoch=0; status=""
        [[ -f "$stamp" ]] && IFS=$'\t' read -r epoch status < "$stamp"
        [[ "$epoch" =~ ^[0-9]+$ ]] || { epoch=0; status=""; }
        if [[ "$epoch" -eq 0 ]]; then
            row 0 "$node" "soon — the checks have never run here" >> "$tmp/health"
            continue
        fi
        ## The stamp carries the outcome because it picks the interval.
        ## See docs/explanation/health-cadence.md#the-stamp-file.
        if [[ "$status" == "failed" ]]; then
            interval="$HEALTH_RETRY_INTERVAL_HOURS"
        else
            interval="$HEALTH_INTERVAL_HOURS"
        fi
        [[ "$interval" =~ ^[0-9]+$ ]] || interval=0
        if [[ "$interval" -eq 0 ]]; then
            row "$KEY_NEVER" "$node" \
                "nothing due — the cadence is off, so only 'report_health.sh --refresh' re-runs them" >> "$tmp/health"
            continue
        fi
        due=$(( epoch + interval * 3600 - now ))
        [[ "$due" -lt 0 ]] && due=0
        key=$(bucket_key "$due")
        row "$key" "$node" "$(bucket_when "$due") — last run ${status:-unknown}, on the ${interval}h interval" >> "$tmp/health"
    done

    print_buckets "HEALTH CHECKS — when each node next runs its check set" "$tmp/health"
}

[[ "$want_tests"  -eq 1 ]] && tests_section
[[ "$want_health" -eq 1 ]] && health_section
exit 0
