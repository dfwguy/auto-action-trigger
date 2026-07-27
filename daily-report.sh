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
# A "Summary:" block follows on stderr -- how many nodes are in each slurm
# state, how many cells hold each status, and min/median/mean/max per job for
# the cells that hold a number. It is on stderr and not in the rows on purpose:
# the file written by -o and a redirect of stdout both have to stay
# machine-readable.
#
# Every block in the summary is a fixed-width table sharing one set of column
# positions, so the whole thing can be pasted into a spreadsheet and split with
# text-to-columns in fixed-width mode. That holds under -c too: the separator
# governs the rows on stdout, not the human block on stderr, which a comma
# would only make harder to read.
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
            sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
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

# ── Emit ──────────────────────────────────────────────────────────────────────

if [[ -n "$report_file" ]]; then
    printf '%s\n' "${rows[@]}" | tr '\t' "$sep" > "$report_file" || exit 1
fi

## Aligned only for a human reading TSV at a terminal. Anything else -- a pipe,
## a redirect, -c -- gets the raw rows, because that is what a caller asking for
## separated values wants back.
if [[ "$sep" == $'\t' && -t 1 ]] && command -v column >/dev/null 2>&1; then
    printf '%s\n' "${rows[@]}" | column -t -s $'\t'
else
    printf '%s\n' "${rows[@]}" | tr '\t' "$sep"
fi

if [[ -n "$report_file" ]]; then
    echo >&2
    echo "Written to: $report_file" >&2
fi

# ── Summary ───────────────────────────────────────────────────────────────────
# On stderr, never in the rows. The file written by -o and a redirect of stdout
# both have to stay machine-readable; a trailing prose block in a CSV is the
# kind of thing that silently poisons whatever reads it next.

## Reads "<count><tab><label>" lines and returns "<label><tab><count>" rows,
## largest population first, ties broken by name so two runs of the same cluster
## produce the same block. Padding is not applied here: the widths are shared
## with the other blocks and cannot be known until every row exists.
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

## Column widths are shared by every block in the summary, so they are measured
## across all the rows before any row prints. Measuring per block would leave
## each block internally tidy and none of them lining up with the next, which is
## exactly what a fixed-width paste cannot cope with.
declare -a col_width

measure_row() {
    local -a f
    IFS=$'\t' read -r -a f <<< "$1"
    local i
    for ((i = 0; i < ${#f[@]}; i++)); do
        (( ${#f[i]} > ${col_width[i]:-0} )) && col_width[i]=${#f[i]}
    done
}

## Label left, numbers right, two spaces between. A column boundary is then
## always a run of at least two spaces, which is what makes the split points
## unambiguous to a human dragging them in a text-to-columns dialog.
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
    printf '    %s\n' "$out"
}

## Each block carries its own header row: once the statistics are bare columns,
## the header is the only thing saying which one is the median.
declare -a slurm_rows status_rows metric_rows

if [[ ${#slurm_count[@]} -gt 0 ]]; then
    slurm_rows=("state"$'\t'"nodes")
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

for row in "${slurm_rows[@]}" "${status_rows[@]}" "${metric_rows[@]}"; do
    measure_row "$row"
done

{
    echo
    echo "Summary:"
    echo "  $node_count nodes, ${#job_order[@]} jobs"

    if [[ ${#slurm_rows[@]} -gt 0 ]]; then
        echo
        echo "  slurm state"
        for row in "${slurm_rows[@]}"; do print_row "$row"; done
    fi

    if [[ ${#status_rows[@]} -gt 0 ]]; then
        echo
        echo "  status"
        for row in "${status_rows[@]}"; do print_row "$row"; done
    fi

    if [[ ${#metric_rows[@]} -gt 0 ]]; then
        echo
        echo "  metrics"
        for row in "${metric_rows[@]}"; do print_row "$row"; done
    fi
} >&2
