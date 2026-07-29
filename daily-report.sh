#!/bin/bash
#
# Usage: daily-report.sh [-c] [-o file]
#
# Reports per-node benchmark status and performance metrics.
# Rows: nodes  |  Columns: slurm state, then per-job status + extracted metric
# (per run).
#
#   -c, --csv         comma separated instead of tab separated.
#   -o, --output <f>  also write the rows to <f>. Without it nothing is
#                     written to disk -- a report is only ever produced
#                     because someone asked for one.
#
# The table goes to stdout, and a summary follows on stderr -- how many nodes
# are in each slurm state, how many cells hold each status, min/median/mean/max
# per job for the cells that hold a number, and last a pass/fail count per job,
# which is the only summary a job like dcgm gets: it has no number to take a
# median of, and pooled status counts do not say which job failed. The summary
# is on stderr and not in the rows on purpose: the file written by -o and a
# redirect of stdout both have to stay machine-readable.
#
# The two halves are laid out the same way, always. One rule decides it for the
# whole report:
#
#   TSV at a terminal    column-aligned on one shared grid -- see the note on
#                        the grid below -- for reading on screen.
#   anything else        the raw separated rows. A pipe, a redirect, -o, or -c.
#
# So -c gives comma separated rows for the table AND the summary, which is the
# form to use for a spreadsheet: paste it and split on the delimiter. Aligned
# text is for reading, not for importing -- a fixed-width import has to guess
# where the columns are, and it guesses from whatever was selected, so pasting
# part of a report gets different break points than pasting all of it. Nothing
# about the layout can fix that. Splitting on a separator has nothing to guess.
#
# `daily-report.sh | cat` is the same thing with tabs, which a spreadsheet
# splits on paste without a dialog at all.
#
# Read-only apart from -o. It submits nothing and drains nothing.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$home/settings.sh"
results_dir="$home/results"
jobs_dir="$JOBS_DIR"

sep=$'\t'
report_file=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--csv)
            sep=','; shift ;;
        -o|--output)
            [[ -n "$2" ]] || { echo "ERROR: $1 needs a file to write" >&2; exit 1; }
            report_file="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,39p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *)  echo "ERROR: unknown argument $1" >&2; exit 1 ;;
    esac
done

if [[ -n "$report_file" ]]; then
    mkdir -p "$(dirname "$report_file")" || exit 1
fi

## Without this an operator shell that never loaded the slurm module reads
## no-slurm for the whole column on a healthy cluster.
if ! command -v sinfo >/dev/null 2>&1 && [[ -r /etc/profile.d/modules.sh ]]; then
    source /etc/profile.d/modules.sh >/dev/null 2>&1
    command -v module >/dev/null 2>&1 && module load slurm >/dev/null 2>&1
fi

# ── Metric extraction ─────────────────────────────────────────────────────────
# Returns a single numeric value (or empty) for a completed result file.

extract_metric() {
    local job="$1" file="$2"
    case "$job" in
        hpl)
            # WC summary line: T/V N NB P Q Time Gflops (per_GPU)
            grep -E '^WC' "$file" 2>/dev/null | awk '{print $7}' | head -1
            ;;
        allreduce|alltoall|allreduce-nonvlink|alltoall-nonvlink|allreduce-forcesharp)
            # Out-of-place busbw at the largest message size actually run --
            # the same number verdict.sh's _v_min_peak_bw judges against
            # VERDICT_MIN_PEAK_BW_*, so this column can be read against those
            # floors directly. Change one and change the other.
            awk '$1 ~ /^[0-9]+$/ {print}' "$file" 2>/dev/null | sort -k1,1n | tail -1 | awk '{print $8}'
            ;;
        nvbandwidth)
            # Lowest SUM across the requested test cases -- the weakest path
            grep -E '^SUM ' "$file" 2>/dev/null | awk '{print $NF}' | sort -n | head -1
            ;;
        stream)
            # Triad best rate, MB/s
            awk '/^Triad:/ {print $2}' "$file" 2>/dev/null | head -1
            ;;
        fio)
            # Highest aggregate bandwidth reported across the four passes
            grep -oE 'bw=[0-9.]+[KMG]?i?B/s' "$file" 2>/dev/null | sed 's/bw=//' | sort -h | tail -1
            ;;
    esac
}

metric_label() {
    case "$1" in
        hpl)                echo "gflops"      ;;
        allreduce|alltoall|allreduce-nonvlink|alltoall-nonvlink|allreduce-forcesharp)
                            echo "busbw_GBs"   ;;
        nvbandwidth)        echo "min_GBs"     ;;
        stream)             echo "triad_MBs"   ;;
        fio)                echo "bw"          ;;
    esac
}

# ── Discover active jobs from the BENCHMARKS setting ──────────────────────────

declare -a job_order
declare -A job_total_runs

# Burn-in columns only when the phase is enabled -- see status-check.sh.
active_benchmarks="$BENCHMARKS"
setting_enabled "$RUN_BURNIN" && active_benchmarks="$BENCHMARKS $BURNIN"

for job in $active_benchmarks; do
    sbatch="$jobs_dir/$job.sbatch"
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

nodes=$(ls -1 "$results_dir" 2>/dev/null | sort)
if [[ -z "$nodes" ]]; then
    echo "No results found in $results_dir"
    exit 0
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

## Status is derived from the log on every report, never read from a marker, so
## an older gate's pass is re-judged. See docs/benchmarks.md#where-a-pass-is-decided.
if [[ ! -f "$PARSERS_DIR/verdict.sh" ]]; then
    echo "ERROR: $PARSERS_DIR/verdict.sh is missing -- it carries the pass/fail rule" >&2
    echo "       for every job, and without it nothing can be judged." >&2
    echo "       PARSERS=$PARSERS, from ${SETTINGS_FILE:-<no settings file found>}." >&2
    exit 1
fi
source "$PARSERS_DIR/verdict.sh"

# ── Build the table ───────────────────────────────────────────────────────────
# Assembled once, tab separated, separator swapped in at the end. Screen and
# file come from this one array, so they cannot disagree.

declare -a rows

header="node"$'\t'"slurm"
for job in "${job_order[@]}"; do
    runs=${job_total_runs[$job]}
    if [[ "$runs" -eq 1 ]]; then
        header+=$'\t'"${job}"
    else
        for ((r=1; r<=runs; r++)); do
            header+=$'\t'"${job}_run${r}"
        done
    fi
done
rows+=("$header")

## Tallied from the same values that land in the cells, so the summary can
## never describe a different table than the one printed.
declare -A slurm_count cell_count job_values job_status_count status_seen
node_count=0

for node in $nodes; do
    state="${slurm_state[$node]:-$slurm_default}"
    (( slurm_count["$state"]++ ))
    (( node_count++ ))
    row="$node"$'\t'"$state"
    for job in "${job_order[@]}"; do
        runs=${job_total_runs[$job]}
        mlabel=$(metric_label "$job")
        if [[ "$runs" -eq 1 ]]; then
            files=("$results_dir/$node/$job.txt")
        else
            files=()
            for ((r=1; r<=runs; r++)); do
                files+=("$results_dir/$node/$job-run${r}.txt")
            done
        fi
        for file in "${files[@]}"; do
            # Not $(...) -- a subshell would lose the reason. See verdict().
            verdict "$job" "$file"
            status="$VERDICT_STATUS"
            ## A number whenever the run produced one, FAIL included; the status
            ## word is what a cell says when there is no figure. See
            ## docs/operations.md#status-and-reporting.
            ##
            ## DONE and FAIL only: an INCOMPLETE log still carries parseable
            ## rows, and its largest message size is whichever one it reached.
            if [[ -n "$mlabel" && ( "$status" == "DONE" || "$status" == "FAIL" ) ]]; then
                metric=$(extract_metric "$job" "$file")
                cell="${metric:-$status}"
            else
                cell="$status"
            fi
            row+=$'\t'"$cell"

            ## From the status, not the cell: a cell holding a metric says
            ## nothing about pass or fail.
            (( job_status_count["$job,$status"]++ ))
            status_seen["$status"]=1

            ## Tested, not inferred from the status: a DONE whose metric did not
            ## parse (fio's "1.2GiB/s") is a word, and averaging it would lie.
            if [[ "$cell" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
                job_values["$job"]+="$cell"$'\n'
            else
                (( cell_count["$cell"]++ ))
            fi
        done
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

## Sorted first so awk can index for the median. The five statistics come back
## as separate fields, not "min=..." text, because they are columns now.
stats_row() {
    sort -g | awk '
        { v[NR] = $1; sum += $1 }
        END {
            if (NR == 0) exit
            mid = int((NR + 1) / 2)
            med = (NR % 2) ? v[mid] : (v[mid] + v[mid + 1]) / 2
            printf "%d\t%.6g\t%.6g\t%.6g\t%.6g\n", NR, v[1], med, sum / NR, v[NR]
        }'
}

## Every block is rows and nothing else -- named by the first cell of its own
## header row, never a title line above it. See
## docs/operations.md#getting-it-into-a-spreadsheet.
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
## on the cluster. See docs/operations.md#status-and-reporting.
if [[ ${#job_values[@]} -gt 0 ]]; then
    for job in "${job_order[@]}"; do
        [[ -n "${job_values[$job]}" ]] || continue
        stats=$(printf '%s' "${job_values[$job]}" | stats_row)
        [[ -n "$stats" ]] || continue
        metric_rows+=("$job ($(metric_label "$job"))"$'\t'"$stats")
    done
    if [[ ${#metric_rows[@]} -gt 0 ]]; then
        metric_rows=("job (metric)"$'\t'"n"$'\t'"min"$'\t'"median"$'\t'"mean"$'\t'"max"
                     "${metric_rows[@]}")
    fi
fi

## The only summary a job with no metric gets. See
## docs/operations.md#status-and-reporting.
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
# row. See docs/operations.md#getting-it-into-a-spreadsheet.

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

## Table and summary alike: the grid is for reading TSV at a terminal, anything
## else gets raw separated rows. See docs/operations.md#status-and-reporting.
##
## Decided once for the whole report, not per stream -- the summary is on stderr
## and the table on stdout, so testing each would put an aligned block under a
## raw table whenever only stdout was redirected.
aligned=0; [[ "$sep" == $'\t' && -t 1 ]] && aligned=1

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

emit_rows "$aligned" "${rows[@]}"

{
    echo
    emit_rows "$aligned" "${total_rows[@]}"

    if [[ ${#slurm_rows[@]} -gt 0 ]]; then
        echo
        emit_rows "$aligned" "${slurm_rows[@]}"
    fi

    if [[ ${#status_rows[@]} -gt 0 ]]; then
        echo
        emit_rows "$aligned" "${status_rows[@]}"
    fi

    if [[ ${#metric_rows[@]} -gt 0 ]]; then
        echo
        emit_rows "$aligned" "${metric_rows[@]}"
    fi

    if [[ ${#passfail_rows[@]} -gt 0 ]]; then
        echo
        emit_rows "$aligned" "${passfail_rows[@]}"
    fi

    ## Last, so everything between the first row and the last stays on the grid
    ## and the whole report selects in one sweep. No column is sized for a path.
    if [[ -n "$report_file" ]]; then
        echo
        echo "Written to: $report_file"
    fi
} >&2
