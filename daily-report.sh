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
# The table goes to stdout as TSV. When stdout is a terminal and the format is
# TSV it is column-aligned for reading; redirected, piped, or written with -o
# it is the raw separated rows, so the screen and the file carry the same
# fields and a pipeline gets something parseable.
#
# A summary follows on stderr -- how many nodes are in each slurm state, how
# many cells hold each status, and min/median/mean/max per job for the cells
# that hold a number. It is on stderr and not in the rows on purpose: the file
# written by -o and a redirect of stdout both have to stay machine-readable.
#
# Everything printed at a terminal -- the node table and every summary block --
# is laid out on ONE grid: no indentation, one set of column positions, and
# every line a row rather than a title or a sentence. The whole screen can then
# be selected in one sweep, pasted into a spreadsheet, and split with
# text-to-columns in fixed-width mode, because there is a single set of break
# points that fits all of it. Blocks aligned only within themselves cannot
# survive that import -- see the note on the grid below.
#
# -c does not change the summary. The separator governs the rows on stdout, not
# the human block on stderr, and a spreadsheet opening the .csv or .tsv written
# by -o splits on the delimiter and needs none of this.
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
            sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *)  echo "ERROR: unknown argument $1" >&2; exit 1 ;;
    esac
done

if [[ -n "$report_file" ]]; then
    mkdir -p "$(dirname "$report_file")" || exit 1
fi

## An operator shell that has not loaded the slurm module has no sinfo, and the
## whole slurm column would read no-slurm on a cluster that is perfectly fine.
## Guarded both ways: a site without environment-modules at all still gets a
## working report, just without the column.
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
        allreduce|alltoall|allreduce-nonvlink|alltoall-nonvlink)
            # Find largest message size actually run, return out-of-place busbw.
            # verdict.sh's _v_min_peak_bw extracts this same number and holds the
            # floor it is judged against (VERDICT_MIN_PEAK_BW_*). Change one and
            # change the other, or this column prints a figure the gate did not
            # look at.
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
        allreduce|alltoall|allreduce-nonvlink|alltoall-nonvlink)
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
# Read once for the whole fleet rather than per node: a `sinfo -n` per row is
# 200+ round trips to slurmctld to answer a question one call already answered.
#
# Every node gets a value in this column, and each of the three ways it can be
# missing says something different. A blank would flatten all three into "the
# report is broken somehow", which is exactly the silence this tree exists to
# avoid.

declare -A slurm_state

if command -v sinfo >/dev/null 2>&1; then
    while IFS='|' read -r n state; do
        [[ -z "$n" ]] && continue
        # sinfo -N lists a node once per partition it belongs to; the state is
        # the node's, not the partition's, so the first line is the answer.
        [[ -n "${slurm_state[$n]}" ]] && continue
        slurm_state["$n"]="$state"
    done < <(sinfo -N -h -o '%N|%T' 2>/dev/null)
    if [[ ${#slurm_state[@]} -eq 0 ]]; then
        echo "WARNING: sinfo returned no nodes -- slurm column will read no-slurm" >&2
        slurm_default="no-slurm"
    else
        ## In sinfo, but not among the nodes it listed: known to results/ and
        ## not to this cluster's slurm.
        slurm_default="unknown"
    fi
else
    echo "WARNING: sinfo not on PATH, and 'module load slurm' did not put it there" >&2
    echo "         -- slurm column will read no-slurm" >&2
    slurm_default="no-slurm"
fi

# ── Helper functions ──────────────────────────────────────────────────────────

## Status comes from the parser, derived from the log on every report rather
## than read from a marker the sbatch wrote at run time. A result that passed an
## older, looser gate is re-judged here, so a report reflects what the current
## gate makes of the cluster rather than a mix of every gate ever deployed.
if [[ ! -f "$PARSERS_DIR/verdict.sh" ]]; then
    echo "ERROR: $PARSERS_DIR/verdict.sh is missing -- it carries the pass/fail rule" >&2
    echo "       for every job, and without it nothing can be judged." >&2
    echo "       PARSERS=$PARSERS, from ${SETTINGS_FILE:-<no settings file found>}." >&2
    exit 1
fi
source "$PARSERS_DIR/verdict.sh"

# ── Build the table ───────────────────────────────────────────────────────────
# Rows are assembled once, tab separated, and the separator is swapped in at the
# very end. Screen and file are emitted from this one array, so they can never
# disagree.

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

## Tallied as the table is built, from the same values that land in the cells,
## so the summary can never describe a table other than the one printed.
declare -A slurm_count cell_count job_values
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
            if [[ "$status" == "DONE" && -n "$mlabel" ]]; then
                metric=$(extract_metric "$job" "$file")
                cell="${metric:-$status}"
            else
                cell="$status"
            fi
            row+=$'\t'"$cell"

            ## A cell is either a number to take statistics over or a word to
            ## count. Tested rather than inferred from the status, because a
            ## DONE whose metric did not parse (fio's "1.2GiB/s", a format that
            ## changed under us) is a word, and averaging it would be a lie.
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
# Built before anything prints, because the summary shares its column positions
# with the node table and neither can be laid out until both are known.
#
# The summary goes to stderr, never into the rows. The file written by -o and a
# redirect of stdout both have to stay machine-readable; a trailing prose block
# in a CSV is the kind of thing that silently poisons whatever reads it next.

## Reads "<count><tab><label>" lines and returns "<label><tab><count>" rows,
## largest population first, ties broken by name so two runs of the same cluster
## produce the same block. Padding is not applied here: the widths are shared
## with every other row in the report and cannot be known until all of them
## exist.
count_rows() {
    local n key
    sort -k1,1nr -k2,2 | while IFS=$'\t' read -r n key; do
        printf '%s\t%s\n' "$key" "$n"
    done
}

## Median needs the values in order, so sort first and let awk index them.
##
## The five statistics come back as separate tab separated fields rather than as
## "min=... median=..." text, because they are columns now. What each number is
## comes from the header row instead of from a prefix glued to the number, which
## is what let them drift out of line with each other.
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

## Every block is rows and nothing else -- no title line, no prose. A block is
## named by the first cell of its own header row instead, so that every line in
## the report has its content inside a column. A free-form line like
## "254 nodes, 4 jobs" sitting above the rows puts words at offsets no column
## boundary passes through, and that is what a fixed-width import cuts in half.
declare -a total_rows slurm_rows status_rows metric_rows

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

## Per job, not pooled: Gflops and GB/s and MB/s share a table but not a scale,
## and one mean across all of them would be a number with no meaning.
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

# ── The grid ──────────────────────────────────────────────────────────────────
# One set of column positions for the whole report -- the node table and every
# summary block. Column 3 starts at the same character on a metrics row as it
# does on a node row.
#
# This is what "fixed width" has to mean to be worth anything. A spreadsheet's
# fixed-width import picks ONE set of break points and applies them to the whole
# paste. Blocks that are each internally tidy but disagree on where a column
# starts cannot all survive that: whichever set of boundaries is chosen slices
# through the middle of every other block's text. So the widths are measured
# across every row of every block first, and nothing prints until they are all
# known.
#
# Two rules follow from it and are not negotiable per block:
#
#   - No indentation. A leading indent is an offset into the first column that
#     only some lines carry, which is the same problem one level down.
#   - Every line is a row. See the note on block titles above.

declare -a col_width

measure_row() {
    local -a f
    IFS=$'\t' read -r -a f <<< "$1"
    local i
    for ((i = 0; i < ${#f[@]}; i++)); do
        (( ${#f[i]} > ${col_width[i]:-0} )) && col_width[i]=${#f[i]}
    done
}

## Label left, every column after it right, two spaces between. A column
## boundary is then always a run of at least two spaces, which is what lets the
## import find the split points on its own rather than guessing them.
##
## printf -v rather than $(printf ...): command substitution strips the trailing
## spaces off the label's padding, and every column after it shifts left.
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
           "${status_rows[@]}" "${metric_rows[@]}"; do
    measure_row "$row"
done

# ── Emit ──────────────────────────────────────────────────────────────────────

if [[ -n "$report_file" ]]; then
    printf '%s\n' "${rows[@]}" | tr '\t' "$sep" > "$report_file" || exit 1
fi

## Aligned only for a human reading TSV at a terminal -- which is the case where
## the report is about to be selected and pasted somewhere. Anything else -- a
## pipe, a redirect, -c -- gets the raw rows, because that is what a caller
## asking for separated values wants back, and a spreadsheet opening a .tsv or a
## .csv splits on the delimiter without needing any of this.
if [[ "$sep" == $'\t' && -t 1 ]]; then
    for row in "${rows[@]}"; do print_row "$row"; done
else
    printf '%s\n' "${rows[@]}" | tr '\t' "$sep"
fi

{
    echo
    for row in "${total_rows[@]}"; do print_row "$row"; done

    if [[ ${#slurm_rows[@]} -gt 0 ]]; then
        echo
        for row in "${slurm_rows[@]}"; do print_row "$row"; done
    fi

    if [[ ${#status_rows[@]} -gt 0 ]]; then
        echo
        for row in "${status_rows[@]}"; do print_row "$row"; done
    fi

    if [[ ${#metric_rows[@]} -gt 0 ]]; then
        echo
        for row in "${metric_rows[@]}"; do print_row "$row"; done
    fi

    ## Last, not between the table and the summary: everything between the first
    ## row and the last is on the grid, so the whole report can be selected in
    ## one sweep. A path is the one string here that no column is sized for.
    if [[ -n "$report_file" ]]; then
        echo
        echo "Written to: $report_file"
    fi
} >&2
