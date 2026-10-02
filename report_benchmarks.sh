#!/bin/bash
#
# Usage: report_benchmarks.sh [-c] [-o file] [pattern]
#
# Reports per-node benchmark status and performance metrics.
# Rows: nodes  |  Columns: slurm state, then per-job status + extracted metric
# (per run).
#
#   -c, --csv         comma separated instead of tab separated.
#   -o, --output <f>  also write the rows to <f>. Without it nothing is
#                     written to disk -- a report is only ever produced
#                     because someone asked for one. The directory has to
#                     exist; naming a path is a statement about where the
#                     report goes, and this creates nothing.
#   --no-cache        judge every node from its files, ignoring
#                     results/.result_cache.*. A cached report is the report you
#                     would have got anyway; reach for this when you suspect the
#                     cache rather than the gate.
#                     See docs/explanation/verdicts-and-the-cache.md#the-verdict-cache.
#
#   pattern           optional node-name filter, read the same way as
#                     report_job-status.sh's: a bare string matches every node whose
#                     name starts with it, so a rack prefix (dh01-rack01) covers
#                     the whole rack, while a shell glob (dh01-rack0[12]*,
#                     *node05) is honored as written and can match anywhere in
#                     the name. With no pattern, every node under results/ is
#                     reported.
#
#                     The summary describes the nodes that matched and nothing
#                     else, so a filtered report's median is the median of that
#                     subset -- the node count in the first summary block is
#                     what says how many nodes it was taken over.
#
# The table goes to stdout, and a summary follows on stderr -- how many nodes
# are in each slurm state, how many cells hold each status, min/median/mean/max
# and cov per job for the cells that hold a number, and last a pass/fail count per job,
# which is the only summary a job like dcgmi-r3 gets: it has no number to take a
# median of, and pooled status counts do not say which job failed. The summary
# is on stderr and not in the rows on purpose: the file written by -o and a
# redirect of stdout both have to stay machine-readable.
#
# One layout rule, asked of each stream, since the two have separate
# destinations:
#
#   TSV at a terminal    column-aligned on one shared grid -- see the note on
#                        the grid below -- for reading on screen.
#   anything else        the raw separated rows. A pipe, a redirect, -o, or -c.
#
# So `report_benchmarks.sh > /dev/null` still reads aligned -- the table went to the
# redirect, the summary is still at a terminal -- and -c gives comma separated
# rows for the table AND the summary, the form to use for a spreadsheet: paste
# it and split on the delimiter. Aligned text is for reading, not importing --
# a fixed-width import has to guess where the columns are, and it guesses from
# whatever was selected, so pasting part of a report gets different break
# points than pasting all of it. Splitting on a separator has nothing to guess.
#
# `report_benchmarks.sh | cat` is the table with tabs, which a spreadsheet splits.
#
# Read-only apart from -o. It submits nothing and drains nothing.
# --- end of --help text; tests/help-text-test.sh keeps the -h range in step ---

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$home/settings.sh"
results_dir="$RESULTS_DIR"
jobs_dir="$JOBS_DIR"

sep=$'\t'
report_file=""
args=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--csv)
            sep=','; shift ;;
        -o|--output)
            [[ -n "$2" ]] || { echo "ERROR: $1 needs a file to write" >&2; exit 1; }
            report_file="$2"; shift 2 ;;
        --no-cache)
            export SCAN_CACHE=0; shift ;;
        -h|--help)
            sed -n '2,59p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        -*) echo "ERROR: unknown argument $1" >&2; exit 1 ;;
        *)  args+=("$1"); shift ;;
    esac
done

## A second pattern would silently report on the first alone; say so instead.
if [[ ${#args[@]} -gt 1 ]]; then
    echo "ERROR: only one node pattern is accepted, got: ${args[*]}" >&2
    exit 1
fi

## Same rule as report_job-status.sh: a bare string is a prefix, anything with glob
## characters is used as written.
pattern="${args[0]}"
if [[ -z "$pattern" ]]; then
    pattern='*'
elif [[ "$pattern" != *[\*\?\[]* ]]; then
    pattern="${pattern}*"
fi

## Checked here rather than at the write below: this report takes a scan of the
## whole fleet to build, and one that cannot be written has wasted it. Nothing
## is created -- see docs/how-to/export-a-report.md.
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

## Without this an operator shell that never loaded the slurm module reads
## no-slurm for the whole column on a healthy cluster.
if ! command -v sinfo >/dev/null 2>&1 && [[ -r /etc/profile.d/modules.sh ]]; then
    source /etc/profile.d/modules.sh >/dev/null 2>&1
    command -v module >/dev/null 2>&1 && module load slurm >/dev/null 2>&1
fi

# ── Discover active jobs from the BENCHMARKS setting ──────────────────────────

declare -a job_order
declare -A job_total_runs

# BURNIN never expands into per-run columns here -- it is one accumulated-
# hours column instead. See docs/reference/settings.md#burn-in.
active_benchmarks="$BENCHMARKS"
show_burnin=0
setting_enabled "$RUN_BURNIN" && [[ -n "${BURNIN// /}" ]] && show_burnin=1

for job in $active_benchmarks; do
    ## See docs/explanation/sequencing.md#host-launched-jobs.
    sbatch="$jobs_dir/$job.sbatch"
    [[ -f "$sbatch" ]] || sbatch="$jobs_dir/$job.sh"
    [[ -f "$sbatch" ]] || continue
    if grep -Fq "totalRuns" "$sbatch"; then
        runs=$(grep -F totalRuns "$sbatch" | awk -F= '{print $2}' | tr -d '[:space:]')
    else
        runs=1
    fi
    job_order+=("$job")
    job_total_runs["$job"]=$runs
done

# ── Discover nodes ────────────────────────────────────────────────────────────

## An array, not a word-split string: the row order is the node order and the
## scan is handed this list verbatim.
declare -a nodes excluded
for node_dir in "$results_dir"/$pattern/; do
    [[ -d "$node_dir" ]] || continue
    node_dir="${node_dir%/}"
    ## Not basename: that is a fork per node for what expansion does free.
    node="${node_dir##*/}"
    ## See docs/reference/settings.md#hosts-that-are-not-compute-nodes.
    node_out_of_reporting "$results_dir" "$node" && { excluded+=("$node"); continue; }
    nodes+=("$node")
done
## On stderr with the rest of the summary, so the rows stay machine-readable.
if [[ ${#excluded[@]} -gt 0 ]]; then
    echo "NOTE: left out, not compute nodes: ${excluded[*]}" >&2
fi
## A node that has stopped cycling still has rows, and they are the last thing
## written rather than what is true now.
## See docs/explanation/the-agent-and-the-watchdog.md#what-the-heartbeat-means.
declare -a silent
for node in "${nodes[@]}"; do
    heartbeat_stale "$results_dir" "$node" && silent+=("$node")
done
if [[ ${#silent[@]} -gt 0 ]]; then
    echo "NOTE: ${#silent[@]} node(s) have not cycled in ${HEARTBEAT_STALE_MINUTES}m, so their rows are the last thing written rather than what is true now: ${silent[*]}" >&2
    echo "      Their timers are not firing. ./check_trigger-log.sh section 0 is the fleet view;" >&2
    echo "      results/<node>/arm.log is what the watchdog heard back from each." >&2
fi

if [[ ${#nodes[@]} -eq 0 ]]; then
    # args[0], not $1 -- $1 is whichever flag came first once -c/-o are in play.
    echo "No nodes under $results_dir match '${args[0]:-*}'" >&2
    exit 1
fi

# ── Slurm state per node ──────────────────────────────────────────────────────
# Read once for the whole fleet: a `sinfo -n` per row is 200+ round trips to
# slurmctld. Every node gets a value, and the three ways it can be missing say
# different things -- a blank would flatten them into one silence.

declare -A slurm_state

if command -v sinfo >/dev/null 2>&1; then
    while IFS='|' read -r n state; do
        [[ -z "$n" ]] && continue
        # sinfo -N lists a node once per partition, but the state is the
        # node's, so the first line is the answer.
        [[ -n "${slurm_state[$n]}" ]] && continue
        slurm_state["$n"]="$state"
    done < <(sinfo -N -h -o '%N|%T' 2>/dev/null)
    if [[ ${#slurm_state[@]} -eq 0 ]]; then
        echo "WARNING: sinfo returned no nodes -- slurm column will read no-slurm" >&2
        slurm_default="no-slurm"
    else
        ## Known to results/, not to this cluster's slurm.
        slurm_default="unknown"
    fi
else
    echo "WARNING: sinfo not on PATH, and 'module load slurm' did not put it there" >&2
    echo "         -- slurm column will read no-slurm" >&2
    slurm_default="no-slurm"
fi

# ── Helper functions ──────────────────────────────────────────────────────────

## Derived from the log on every report, never read from a marker, so an older
## gate's pass is re-judged. See
## docs/explanation/judging-benchmarks.md#where-a-pass-is-decided.
if [[ ! -f "$PARSERS_DIR/verdict.sh" ]]; then
    echo "ERROR: $PARSERS_DIR/verdict.sh is missing -- it carries the pass/fail rule" >&2
    echo "       for every job, and without it nothing can be judged." >&2
    echo "       PARSERS=$PARSERS, from ${SETTINGS_FILE:-<no settings file found>}." >&2
    exit 1
fi
source "$PARSERS_DIR/verdict.sh"

# Judges every cell in parallel workers, extracting the metric while the file is
# open. See docs/explanation/verdicts-and-the-cache.md#how-a-report-is-produced.
# shellcheck source=/dev/null
source "$home/verdict-scan.sh"

# ── Build the table ───────────────────────────────────────────────────────────
# Assembled once, tab separated, separator swapped in at the end. Screen and
# file come from this one array, so they cannot disagree.

declare -a rows

## Built together so a column cannot be judged in one order and printed in
## another. Two spellings: the header says `job_runN`, the file is `job-runN`.
declare -a columns
header="node"$'\t'"slurm"
for job in "${job_order[@]}"; do
    runs=${job_total_runs[$job]}
    if [[ "$runs" -eq 1 ]]; then
        header+=$'\t'"${job}"
        columns+=("$job")
    else
        for ((r=1; r<=runs; r++)); do
            header+=$'\t'"${job}_run${r}"
            columns+=("${job}-run${r}")
        done
    fi
done
if [[ "$show_burnin" -eq 1 ]]; then
    header+=$'\t'"burnin_hours"
    columns+=("burnin_hours")
fi
rows+=("$header")

## Once per job, not per node per job: the answer never varies by node.
declare -A mlabel_of
for job in "${job_order[@]}"; do
    mlabel_of["$job"]=$(metric_label "$job")
done

# No RUNNING and no RERUNNING here: this report reads sinfo, not squeue, so it
# cannot tell a live job from a dead one, and an archived column reads NOT_RUN.
export SCAN_RESULTS_DIR="$results_dir"
export SCAN_COLUMNS="${columns[*]}"
export SCAN_RUNNING_FILE=""
export SCAN_ARCHIVES=0
export SCAN_METRICS=1

## Tallied from the same values that land in the cells, so the summary can
## never describe a different table than the one printed.
declare -A slurm_count cell_count job_values job_status_count status_seen
declare -A cells       # "<node>,<column>" -> what that cell prints
node_count=0

## Rows arrive in worker-completion order, so cells are collected here and laid
## out in node order below; the tallies are order-independent.
## SCAN_FS, never a tab -- a tab would blank the metric. See verdict-scan.sh.
while IFS="$SCAN_FS" read -r node col status _reason metric; do
    job="${col%-run[0-9]*}"
    ## A number whenever the run produced one, FAIL included; the status word is
    ## what a cell says when there is no figure. See
    ## docs/reference/scripts.md.
    if [[ -n "${mlabel_of[$job]}" && ( "$status" == "DONE" || "$status" == "FAIL" ) ]]; then
        cell="${metric:-$status}"
    else
        cell="$status"
    fi
    cells["$node,$col"]="$cell"

    ## From the status, not the cell: a cell holding a metric says nothing about
    ## pass or fail.
    (( job_status_count["$job,$status"]++ ))
    status_seen["$status"]=1

    ## Tested, not inferred from the status: a DONE whose metric did not parse
    ## (fio's "1.2GiB/s") is a word, and averaging it would lie.
    if [[ "$cell" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
        job_values["$job"]+="$cell"$'\n'
    else
        (( cell_count["$cell"]++ ))
    fi
done < <(scan_fleet "${nodes[@]}")

## Not through scan_fleet -- burnin_hours_cell sums across every BURNIN job
## and every run of each, which is not one column's verdict, and the campaign
## target it is judged against means it must not be cached either.
## See docs/explanation/burn-in-waveform.md.
if [[ "$show_burnin" -eq 1 ]]; then
    for node in "${nodes[@]}"; do
        cells["$node,burnin_hours"]=$(burnin_hours_cell "$node")
    done
fi

for node in "${nodes[@]}"; do
    state="${slurm_state[$node]:-$slurm_default}"
    (( slurm_count["$state"]++ ))
    (( node_count++ ))
    row="$node"$'\t'"$state"
    for col in "${columns[@]}"; do
        ## No scan row means a worker died, not a node that passed. Named, so
        ## it shows up in the status block rather than as a blank in an export.
        if [[ -v "cells[$node,$col]" ]]; then
            row+=$'\t'"${cells[$node,$col]}"
        else
            row+=$'\t'"NO_SCAN"
            (( cell_count["NO_SCAN"]++ ))
        fi
    done
    rows+=("$row")
done

# ── Summary rows ──────────────────────────────────────────────────────────────
# Built before anything prints: the summary shares column positions with the
# node table, so neither can be laid out until both are known. It goes to
# stderr so -o and a stdout redirect stay machine-readable.

## "<count><tab><label>" in, "<label><tab><count>" out, largest first, ties
## broken by name so two runs of the same cluster agree. Padding comes later --
## the widths are shared with every other row in the report.
count_rows() {
    local n key
    sort -k1,1nr -k2,2 | while IFS=$'\t' read -r n key; do
        printf '%s\t%s\n' "$key" "$n"
    done
}

## Sorted first so awk can index for the median. The six statistics come back
## as separate fields, not "min=..." text, because they are columns now.
## See docs/explanation/reading-the-whole-fleet.md#the-spread-column for cov.
stats_row() {
    sort -g | awk '
        { v[NR] = $1; sum += $1 }
        END {
            if (NR == 0) exit
            mid = int((NR + 1) / 2)
            med = (NR % 2) ? v[mid] : (v[mid] + v[mid + 1]) / 2
            mean = sum / NR
            for (i = 1; i <= NR; i++) sq += (v[i] - mean) ^ 2
            cov = (mean != 0) ? sqrt(sq / NR) / mean : 0
            printf "%d\t%.6g\t%.6g\t%.6g\t%.6g\t%.4f\n", NR, v[1], med, mean, v[NR], cov
        }'
}

## Every block is rows and nothing else -- named by the first cell of its own
## header row, never a title line above it. See
## docs/how-to/export-a-report.md.
declare -a total_rows slurm_rows status_rows metric_rows passfail_rows

total_rows=("summary"$'\t'"count"
            "nodes"$'\t'"$node_count"
            "jobs"$'\t'"${#job_order[@]}")

if [[ ${#slurm_count[@]} -gt 0 ]]; then
    slurm_rows=("slurm state"$'\t'"nodes")
    mapfile -t -O 1 slurm_rows < <(
        for key in "${!slurm_count[@]}"; do
            printf '%d\t%s\n' "${slurm_count[$key]}" "$key"
        done | count_rows)
fi

if [[ ${#cell_count[@]} -gt 0 ]]; then
    status_rows=("status"$'\t'"cells")
    mapfile -t -O 1 status_rows < <(
        for key in "${!cell_count[@]}"; do
            printf '%d\t%s\n' "${cell_count[$key]}" "$key"
        done | count_rows)
fi

## Per job, not pooled, and failing cells included so the min is the worst node
## on the cluster. See docs/reference/scripts.md.
if [[ ${#job_values[@]} -gt 0 ]]; then
    for job in "${job_order[@]}"; do
        [[ -n "${job_values[$job]}" ]] || continue
        stats=$(printf '%s' "${job_values[$job]}" | stats_row)
        [[ -n "$stats" ]] || continue
        metric_rows+=("$job ($(metric_label "$job"))"$'\t'"$stats")
    done
    if [[ ${#metric_rows[@]} -gt 0 ]]; then
        metric_rows=("job (metric)"$'\t'"n"$'\t'"min"$'\t'"median"$'\t'"mean"$'\t'"max"$'\t'"cov"
                     "${metric_rows[@]}")
    fi
fi

## The only summary a job with no metric gets. See
## docs/reference/scripts.md.
##
## Columns are the statuses actually seen, not a fixed four, so a status
## verdict() grows later gets its own column instead of vanishing. DONE and FAIL
## lead, the rest follow in a fixed order so two runs line up.
if [[ ${#job_status_count[@]} -gt 0 ]]; then
    declare -a status_cols
    for st in DONE FAIL INCOMPLETE NOT_RUN; do
        [[ -n "${status_seen[$st]}" ]] && { status_cols+=("$st"); unset "status_seen[$st]"; }
    done
    if [[ ${#status_seen[@]} -gt 0 ]]; then
        mapfile -t -O ${#status_cols[@]} status_cols < <(printf '%s\n' "${!status_seen[@]}" | sort)
    fi

    header="job (pass/fail)"$'\t'"cells"
    for st in "${status_cols[@]}"; do header+=$'\t'"$st"; done
    passfail_rows=("$header")

    for job in "${job_order[@]}"; do
        cells=0
        row=""
        for st in "${status_cols[@]}"; do
            n=${job_status_count["$job,$st"]:-0}
            (( cells += n ))
            row+=$'\t'"$n"
        done
        ## A row even when every cell is NOT_RUN: a job in BENCHMARKS that has
        ## produced nothing anywhere is worth saying out loud.
        passfail_rows+=("$job"$'\t'"$cells$row")
    done
fi

# ── The grid ──────────────────────────────────────────────────────────────────
# One set of column positions for the whole report -- widths measured across
# every row of every block before anything prints, no indentation, every line a
# row. See docs/how-to/export-a-report.md.

declare -a col_width

measure_row() {
    local -a f
    IFS=$'\t' read -r -a f <<< "$1"
    local i
    for ((i = 0; i < ${#f[@]}; i++)); do
        (( ${#f[i]} > ${col_width[i]:-0} )) && col_width[i]=${#f[i]}
    done
}

## Label left, the rest right, two spaces between, so a column boundary is
## always a run of at least two spaces.
##
## printf -v, not $(printf ...): command substitution strips the trailing spaces
## off the label's padding and shifts every column left.
print_row() {
    local -a f
    IFS=$'\t' read -r -a f <<< "$1"
    local i out piece
    printf -v out '%-*s' "${col_width[0]}" "${f[0]}"
    for ((i = 1; i < ${#f[@]}; i++)); do
        printf -v piece '  %*s' "${col_width[i]}" "${f[i]}"
        out+="$piece"
    done
    printf '%s\n' "$out"
}

for row in "${rows[@]}" "${total_rows[@]}" "${slurm_rows[@]}" \
           "${status_rows[@]}" "${metric_rows[@]}" "${passfail_rows[@]}"; do
    measure_row "$row"
done

# ── Emit ──────────────────────────────────────────────────────────────────────

if [[ -n "$report_file" ]]; then
    printf '%s\n' "${rows[@]}" | tr '\t' "$sep" > "$report_file" || exit 1
fi

## The grid is for reading TSV at a terminal, anything else gets raw separated
## rows -- asked of each stream, because they have separate destinations.
## See docs/reference/scripts.md.
table_aligned=0;   [[ "$sep" == $'\t' && -t 1 ]] && table_aligned=1
summary_aligned=0; [[ "$sep" == $'\t' && -t 2 ]] && summary_aligned=1

## Guarded on the argument count: `printf '%s\n'` with nothing to print still
## emits one empty line, which is an empty record in a separated stream.
emit_rows() {
    local aligned="$1" row; shift
    (( $# )) || return 0
    if [[ "$aligned" == 1 ]]; then
        for row in "$@"; do print_row "$row"; done
    else
        printf '%s\n' "$@" | tr '\t' "$sep"
    fi
}

emit_rows "$table_aligned" "${rows[@]}"

{
    echo
    emit_rows "$summary_aligned" "${total_rows[@]}"

    if [[ ${#slurm_rows[@]} -gt 0 ]]; then
        echo
        emit_rows "$summary_aligned" "${slurm_rows[@]}"
    fi

    if [[ ${#status_rows[@]} -gt 0 ]]; then
        echo
        emit_rows "$summary_aligned" "${status_rows[@]}"
    fi

    if [[ ${#metric_rows[@]} -gt 0 ]]; then
        echo
        emit_rows "$summary_aligned" "${metric_rows[@]}"
    fi

    if [[ ${#passfail_rows[@]} -gt 0 ]]; then
        echo
        emit_rows "$summary_aligned" "${passfail_rows[@]}"
    fi

    ## Last, so everything between the first row and the last stays on the grid
    ## and the whole report selects in one sweep. No column is sized for a path.
    if [[ -n "$report_file" ]]; then
        echo
        echo "Written to: $report_file"
    fi
} >&2
