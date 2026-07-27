#!/bin/bash
#
# Shared pass/fail rule for a benchmark result file. Sourced by
# actions/launch_job.sh, status-check.sh and daily-report.sh.
#
# This exists for the same reason reason-map.sh does. The rule used to live
# inside each jobs/*.sbatch -- four near-identical copies for the NCCL jobs
# alone -- and they drifted: ab9121d tightened the two -nonvlink jobs and left
# allreduce.sbatch and alltoall.sbatch on the old rule.
#
# The property that matters here is that a verdict is DERIVED, never stored.
# An sbatch writes only:
#
#   FAIL      it could not run at all, or srun exited non-zero
#   PENDING   it ran to completion and srun exited 0
#
# DONE is computed here, from the contents of the log, on every read. Nothing
# writes it to disk. That is the one thing the old design could not do: a
# socket-speed run that wrote DONE before the gate existed was never re-judged,
# because launch_job.sh skips any file ending in DONE. Twenty-five nodes sat
# that way holding 1.17 GB/s results, and the fix written for them could not
# reach them. Now tightening a gate re-judges every result already on disk.
#
# Files ending in DONE are legacy, from before this split. They are re-judged
# here rather than trusted, which is what retires them without a purge script.

## Bandwidth floors, GB/s, read from the `# Avg bus bandwidth` summary line.
##
## 10 matches the threshold already in use by purge-bad-results.sh. It is set
## to catch a transport that is obviously wrong -- a socket run averages ~1.2
## and peaks ~2.3 -- not to assert the fabric is performing to spec.
##
## A healthy NVLink-scope allreduce on GB300 measures 220.837 here, so that
## floor has enormous headroom and is doing almost nothing for those two jobs.
## The tighter NVLink gate is the peak floor below rather than a raise here --
## it is stated against the figure the daily report already shows, which is what
## anyone reading a slow node compares against.
##
## Read `# Avg bus bandwidth`, which is an average across every message size,
## not the largest-size row. The two differ by roughly 2x on the same run
## (1.17 vs 2.23 on the h01-14 socket run), and daily-report.sh's
## extract_metric reports the largest-size row. Same file, two numbers -- do
## not compare a floor set here against a figure from that report.
VERDICT_MIN_BW_NVLINK=10
VERDICT_MIN_BW_NONVLINK=10

## Floors on the LARGEST-MESSAGE-SIZE out-of-place busbw, GB/s -- a different
## number from the ones above, read from a different place in the same file.
## These are the figures daily-report.sh prints in its allreduce and
## alltoall columns (see extract_metric there), so a value in the report can be
## compared against the floor here directly. The `# Avg bus bandwidth` floors
## above cannot be compared that way: they average every message size and come
## out roughly 2x lower on the same run.
##
## Set per job because alltoall and allreduce bus bandwidth are not comparable
## -- that is the trap the note above warns about, and it is why there are two
## constants here rather than one. Both are NVLink-scope figures; the -nonvlink
## pair has no peak floor yet and is left on the avg-bandwidth floor alone,
## since no known-good IB-scope run has been read to set one from.
VERDICT_MIN_PEAK_BW_ALLREDUCE=683
VERDICT_MIN_PEAK_BW_ALLTOALL=623

## Floors for the non-NCCL jobs. These used to live in the sbatch that ran the
## workload, which meant they were applied once, at run time, and a result that
## passed a too-low floor could never be re-judged when the floor was raised.
## They are here for the same reason the NCCL floors are -- see the header.
##
## A floor of 0 is a floor that has not been established for this platform yet.
## The gate reads that as "skip this check" rather than as "everything passes",
## and says so in a comment at the point of use, so that raising it later is a
## one-line change that re-judges every result already on disk.
VERDICT_MIN_TRIAD_MBS=400000        ## STREAM Triad, MB/s
VERDICT_MIN_TFLOPS_GEMM=0           ## cublasmatmul per-GPU TFLOPS -- not set
VERDICT_MIN_TFLOPS_READINGS=1       ## one TFLOPS figure per GPU is expected

## nvbandwidth run-to-run instability, from MOP section 6.2. Read off the
## COEFFICIENT_OF_VARIATION line each test prints after its matrix.
##
## Set above the MOP's 0.02. Several tests -- the one_to_all and host_to_all
## families in particular -- routinely print 0.01-0.04 on healthy nodes, because
## they measure a handful of links whose spread is real topology rather than
## instability, and one of them tripping the gate failed nodes that were fine.
##
## 0.08 clears that band with room to spare while staying tight enough to be
## worth acting on: what this gate is for is a link varying enough run to run to
## drag down a benchmark, on a node that is a candidate for RMA. A looser bar
## would let that through.
VERDICT_MAX_COV_NVBANDWIDTH=0.08

## fio runs four passes (read, write, randread, randwrite) and each prints one
## IOPS summary, so fewer than four means a pass did not report.
VERDICT_MIN_FIO_PASSES=4

## Failure signatures common to every job. A summary line can print in full and
## a rank still die on the way out, so this is checked independently of whether
## the expected output is present.
##
## The last two are how a job that ran out of time arrives here, and there are
## two of them because there are two ways to bound one:
##
##   CANCELLED AT   Slurm's own line for a step that hit the `--time` every job
##                  passes to srun -- `*** STEP <id> ON <node> CANCELLED AT
##                  <time> DUE TO TIME LIMIT ***`. The `JOB` form of the same
##                  line is the job walltime, which the step limit exists to
##                  pre-empt.
##   timeout:       written by the dcgm jobs, which have no step to bound --
##                  dcgmi runs in the batch body, so they wrap it in `timeout`
##                  instead. Same meaning, different mechanism.
##
## Either way the overrun arrives already explained and is reported as a run
## error, rather than as whatever output the job failed to produce before it
## was cut off. See the deadline section of example.sbatch.
VERDICT_RUN_ERRORS='NCCL WARN|Test NCCL failure|Test failure|srun: error|Segmentation fault|CANCELLED AT|error: unable to|slurmstepd: error|^timeout: killed after'

## Both set by verdict() on every call, and split for a specific reason.
##
##   VERDICT_REASON   why, in words that are IDENTICAL on every node failing the
##                    same way. No line numbers, no measured values, no node
##                    names. status-check.sh pipes through dshbak, which groups
##                    identical lines -- so a stable phrasing collapses forty
##                    nodes with one fabric problem into one block, and makes
##                    the one node failing differently impossible to miss.
##   VERDICT_DETAIL   the specifics for that node: line number, matched text,
##                    measured value. Never put this anywhere it would be
##                    grouped on.
VERDICT_REASON=""
VERDICT_DETAIL=""

## ── Primitives ────────────────────────────────────────────────────────────

## Pattern must be present, or the result is not a pass.
_v_require() {
    local file="$1" label="$2" re="$3"
    grep -qE "$re" "$file" 2>/dev/null && return 0
    VERDICT_REASON="no $label"
    VERDICT_DETAIL=""
    return 1
}

## Pattern must be absent. The detail carries the line number and the matched
## text, because "which line said so" is the first thing anyone asks.
_v_forbid() {
    local file="$1" label="$2" re="$3" hit
    hit=$(grep -nEm1 "$re" "$file" 2>/dev/null)
    [[ -z "$hit" ]] && return 0
    VERDICT_REASON="$label"
    VERDICT_DETAIL="line ${hit%%:*}: $(printf '%s' "${hit#*:}" | sed 's/^[[:space:]]*//' | cut -c1-90)"
    return 1
}

## Case-insensitive _v_forbid. Only dcgm wants this: its rule is "the word fail,
## warn or error appears anywhere", which is deliberately broad and has to catch
## FAIL, Fail and fail alike. The NCCL patterns are matched case-sensitively on
## purpose -- `NCCL WARN` and `CANCELLED AT` are fixed strings, and matching them
## loosely would start catching ordinary prose in a log.
_v_forbid_i() {
    local file="$1" label="$2" re="$3" hit
    hit=$(grep -niEm1 "$re" "$file" 2>/dev/null)
    [[ -z "$hit" ]] && return 0
    VERDICT_REASON="$label"
    VERDICT_DETAIL="line ${hit%%:*}: $(printf '%s' "${hit#*:}" | sed 's/^[[:space:]]*//' | cut -c1-90)"
    return 1
}

## Floor on the `# Avg bus bandwidth` summary. Kept in awk because bash
## arithmetic is integer-only and every one of these values is a float --
## `[[ 1.17569 -lt 10 ]]` is a syntax error, not a false.
_v_min_bw() {
    local file="$1" min="$2" val
    val=$(grep -E '^# Avg bus bandwidth' "$file" 2>/dev/null \
          | head -1 | awk -F: '{print $2}' | tr -d '[:space:]')
    if [[ -z "$val" ]]; then
        VERDICT_REASON="no bus-bandwidth summary"
        VERDICT_DETAIL=""
        return 1
    fi
    awk -v v="$val" -v m="$min" 'BEGIN { exit !(v + 0 >= m + 0) }' && return 0
    VERDICT_REASON="avg bus bandwidth below floor ${min} GB/s"
    VERDICT_DETAIL="measured ${val} GB/s"
    return 1
}

## Floor on the largest message size actually run, out-of-place busbw (column 8
## of the data rows). The extraction here is deliberately the same as
## daily-report.sh's extract_metric: pick the numeric-first-field rows,
## sort by size, take the last. If one of the two is ever changed the other must
## change with it, or the report will print a number that the gate did not judge.
##
## `sort -k1,1n` rather than "last row in the file" because nccl-tests does not
## guarantee the largest size is printed last -- and taking the tail of the file
## blind would read whatever the final row happens to be.
_v_min_peak_bw() {
    local file="$1" min="$2" val
    val=$(awk '$1 ~ /^[0-9]+$/ {print}' "$file" 2>/dev/null \
          | sort -k1,1n | tail -1 | awk '{print $8}')
    if [[ -z "$val" ]]; then
        VERDICT_REASON="no per-size bandwidth rows"
        VERDICT_DETAIL=""
        return 1
    fi
    awk -v v="$val" -v m="$min" 'BEGIN { exit !(v + 0 >= m + 0) }' && return 0
    VERDICT_REASON="peak busbw below floor ${min} GB/s"
    VERDICT_DETAIL="measured ${val} GB/s at the largest message size"
    return 1
}

## Pattern must appear at least $min times. The count matters where one line
## per pass is the evidence that every pass ran: four fio passes, one TFLOPS
## figure per GPU. `_v_require` alone would accept the first of four.
_v_require_count() {
    local file="$1" label="$2" re="$3" min="$4" n
    n=$(grep -cE "$re" "$file" 2>/dev/null)
    [[ "$n" -ge "$min" ]] && return 0
    VERDICT_REASON="fewer than $min $label"
    VERDICT_DETAIL="found $n"
    return 1
}

## Floor on a single value extracted by an awk program. Same reason as
## _v_min_bw for the awk comparison: every one of these is a float.
##
## $5 is the unit, and is part of the REASON rather than the detail -- "below
## floor 400000 MB/s" is identical on every node failing that way, which is
## what keeps dshbak collapsing them into one block.
_v_min_value() {
    local file="$1" label="$2" prog="$3" min="$4" unit="$5" val
    val=$(awk "$prog" "$file" 2>/dev/null | head -1)
    if [[ -z "$val" ]]; then
        VERDICT_REASON="no $label"
        VERDICT_DETAIL=""
        return 1
    fi
    awk -v v="$val" -v m="$min" 'BEGIN { exit !(v + 0 >= m + 0) }' && return 0
    VERDICT_REASON="$label below floor ${min} ${unit}"
    VERDICT_DETAIL="measured ${val} ${unit}"
    return 1
}

## ── Per-job gates ─────────────────────────────────────────────────────────

## nccl-tests. $2 is the transport this job is scoped to: `ib` for the
## -nonvlink pair, which forces traffic out to the HCAs, or `nvlink`.
##
## ONLY the per-channel `via ...` lines are evidence of where data went:
##
##   Channel 01/1 : 2[2] -> 3[3] [receive] via NET/Socket/0/Shared   <- TCP
##   Channel 00/0 : 0[0] -> 1[1] via P2P/MNNVL                       <- NVLink
##
## `Using network Socket`, `NET/Socket : Using` and `Using network IB` are NOT.
## They name the net plugin NCCL registered, which it does whether or not the
## net is ever used. A perfectly healthy single-node NVLink run initialises a
## net plugin for potential inter-node use, finds no IB, falls back to Socket
## for that role, logs all three of those lines, and then moves every byte over
## NVLink at 220 GB/s.
##
## Forbidding those strings failed exactly such a run -- 32 channels of
## via P2P/MNNVL, avg bus bandwidth 220.837 -- as "collective carried over TCP".
## The rule is: judge the channels, never the plugin registration.
## $4 is the largest-size busbw floor, and is optional -- empty means this job
## has no such floor and is judged on the average alone.
_v_gate_nccl() {
    local file="$1" transport="$2" min="$3" peak_min="$4"

    ## nccl-tests prints both of these only after every message size has run and
    ## validated, so requiring them is a positive check. A run that dies in
    ## ncclCommInitRank prints neither.
    _v_require "$file" "out-of-bounds validation"  '^# Out of bounds values *: *0 OK' || return 1
    _v_require "$file" "bus-bandwidth summary"     '^# Avg bus bandwidth *:'          || return 1
    _v_forbid  "$file" "run error"                 "$VERDICT_RUN_ERRORS"              || return 1

    ## Order matters from here down, and it is ordered by causation rather than
    ## by severity: the first check to fire is the one whose reason gets
    ## reported, so the earliest link in the chain has to be checked first.
    ##
    ## The chain runs: enroot builds a fresh /dev -> the container cannot see the
    ## HCAs -> ibv_get_device_list returns nothing -> `NET/IB : No device found.`
    ## -> the IB plugin fails to load -> NCCL falls back to Socket -> every
    ## channel goes over bond0. Checking the last of those first would report 40
    ## nodes as "collective carried over TCP", which is true, and would send
    ## someone to look at the fabric instead of at a missing bind mount.
    if [[ "$transport" == "ib" ]]; then
        ## jobs/nvl72/nccl-hca.sh probes libibverbs from inside the container -- the
        ## same call NCCL makes -- and prints a fixed last line. `(none)` there
        ## is the root cause, stated plainly and without anyone needing to know
        ## what `NET/IB : No device found.` implies about enroot. A result from
        ## before that probe existed has no such line and falls through.
        _v_forbid  "$file" "no HCA visible inside the container" \
            'container sees HCAs [^:]*: \(none\)' || return 1

        _v_forbid  "$file" "no IB device visible to NCCL"  'NET/IB : No device found'   || return 1
        _v_forbid  "$file" "IB plugin failed to load"      'Failed to initialize NET plugin IB' || return 1
        _v_require "$file" "IB named as chosen network"    'Using network IB'           || return 1

        ## Last of the transport checks, not first: by this point everything
        ## that explains WHY it fell back has already been ruled out, so a hit
        ## here means the fallback happened for a reason not yet accounted for.
        _v_forbid "$file" "collective carried over TCP" 'via NET/Socket' || return 1
    else
        ## NVLink scope. The collective is meant to stay on NVLink and never
        ## reach the network at all, so ANY channel on the net is a failure --
        ## whether it landed on Socket or on IB. Stated as a forbid rather than
        ## as "require via P2P" on purpose: this was checked against a healthy
        ## run, which has no `via NET/` line anywhere, and a forbid cannot
        ## false-fail a legitimate path that happens to be named something the
        ## one log inspected did not contain.
        _v_forbid "$file" "collective left NVLink for the network" 'via NET/' || return 1
    fi

    ## Deliberately not forbidding `via SHM` yet. On the NVLink scope it is a
    ## real degradation and should fail, but no known-good log from this
    ## platform has been read to confirm NCCL never uses it on a healthy run --
    ## and a forbid pattern that is wrong drains the whole cluster at once. The
    ## bandwidth floor below catches the gross case meanwhile. Add it here once
    ## a passing run has been looked at.

    ## Average first, peak second: a run that is slow everywhere should be
    ## reported as such rather than as a peak problem, and the average floor is
    ## the coarser of the two.
    _v_min_bw "$file" "$min" || return 1
    [[ -n "$peak_min" ]] && { _v_min_peak_bw "$file" "$peak_min" || return 1; }
    return 0
}

## `dcgmi diag` prints a results table of `| <test> | Pass |` rows on a clean
## run. Requiring at least one distinguishes a passing diagnostic from one that
## never ran -- no dcgmi binary, nv-hostengine down, no GPUs visible. Without it
## the error grep alone reports a pass for empty output.
_v_gate_dcgm() {
    local file="$1"
    _v_require   "$file" "dcgmi Pass row"          '\|[[:space:]]*Pass[[:space:]]*\|' || return 1
    _v_forbid_i  "$file" "dcgmi fail/warn/error"   'fail|warn|error'                  || return 1
    return 0
}

## nvbandwidth, per MOP section 6.2's cross-cutting criteria. The per-test SUM
## thresholds in section 6.1 are the GB200 4-GPU baseline and do not transfer
## to this platform, so no SUM floor is applied -- add one here once a baseline
## has been measured, and it will re-judge every result already on disk.
##
## The N/A rule is the whole reason this gate exists. It used to be a flat
## `grep -iE "N/A"` over the file, which matched the matrix diagonal -- the
## cell where a GPU would be talking to itself, printed N/A on every healthy
## run of every peer test:
##
##   memcpy CE GPU(row) -> GPU(column) bandwidth (GB/s)
##              0         1         2         3
##    0       N/A    767.64    770.54    770.26
##
## So the job could not pass on any node with more than one GPU. It failed
## closed and it failed silently: the sbatch wrote its own FAIL as the last
## line, and a self-reported FAIL is the one verdict this file does not
## re-judge, so no amount of tightening or loosening the rule afterwards could
## reach the results it had already condemned. They had to be re-run.
##
## What section 6.2 actually asks for is an N/A "where a peer transfer was
## expected", which is a claim about POSITION, not about the string. Checked
## positionally below: in a GPU(row) x GPU(column) matrix, N/A is expected on
## the diagonal and nowhere else; in the CPU(row) matrices every cell is a real
## transfer and N/A anywhere is a fault.
_v_nvb_missing_peer() {
    local file="$1" hit
    hit=$(awk '
        ## Reset at each test rather than only on seeing a CPU(row) header:
        ## `device_local_copy` prints `GPU(column)` with no row axis at all, and
        ## would otherwise inherit the exemption from the previous test.
        /^Running /             { peer = 0 }
        /GPU\(row\)/            { peer = 1; next }
        /CPU\(row\)/            { peer = 0; next }
        /^ *[0-9]+ +/ && NF > 1 {
            for (j = 2; j <= NF; j++)
                if ($j == "N/A" && !(peer && j - 2 == $1 + 0))
                    print "line " NR ": row " $1 ", column " (j - 2)
        }' "$file" 2>/dev/null | head -1)
    [[ -z "$hit" ]] && return 0
    VERDICT_REASON="missing peer transfer -- N/A off the matrix diagonal"
    VERDICT_DETAIL="$hit"
    return 1
}

## Run-to-run instability. Each test prints its own coefficient of variation
## after its matrix; any one of them over the bar fails the run.
_v_nvb_unstable() {
    local file="$1" max="$2" hit
    hit=$(awk -v max="$max" \
        '/^COEFFICIENT_OF_VARIATION/ && $NF + 0 > max + 0 { print $2 " = " $NF }' \
        "$file" 2>/dev/null | head -1)
    [[ -z "$hit" ]] && return 0
    VERDICT_REASON="bandwidth unstable -- coefficient of variation above ${max}"
    VERDICT_DETAIL="$hit"
    return 1
}

_v_gate_nvbandwidth() {
    local file="$1"

    ## nvbandwidth prints one SUM line per test it completed, so this is the
    ## positive check: a tool that never started, or a container that came up
    ## without GPUs, prints none.
    _v_require "$file" "per-test SUM lines" '^SUM ' || return 1
    _v_forbid  "$file" "run error"          "$VERDICT_RUN_ERRORS" || return 1

    ## Matched narrowly and case-sensitively on nvbandwidth's own words for a
    ## test it declined to run. NOT a bare `error` sweep of the file: the
    ## previous rule paired one of those with the N/A bug above, and a blanket
    ## grep over a log full of test names is how that class of false-fail gets
    ## in. Judge the strings the tool actually prints.
    _v_forbid "$file" "test not supported on this platform" \
        'Waived|not supported|Unsupported' || return 1

    ## Position before magnitude: a missing P2P route explains a low number,
    ## and reporting the number would send someone to look at performance.
    _v_nvb_missing_peer "$file" || return 1
    _v_nvb_unstable "$file" "$VERDICT_MAX_COV_NVBANDWIDTH" || return 1
    return 0
}

## nvloom. Every process must enumerate the same rackGuid -- more than one
## distinct value means the ranks disagree about what fabric they are on.
## Bandwidth uniformity (MOP section 4: no link >3% below the matrix average)
## needs the per-platform matrix and is not gated here yet.
_v_gate_nvloom() {
    local file="$1" guids
    _v_require "$file" "rackGuid line" 'rackGuid' || return 1
    _v_forbid  "$file" "run error"     "$VERDICT_RUN_ERRORS" || return 1
    ## Matched narrowly: suite names like `fabric-stress` must not trip this.
    _v_forbid  "$file" "CUDA error, assertion or MPI abort" \
        'cuda error|CUDA_ERROR|assertion|assert failed|MPI_Abort' || return 1

    guids=$(grep -oE "rackGuid[: ]+[0-9a-fA-Fx]+" "$file" 2>/dev/null \
            | awk '{print $NF}' | sort -u | wc -l)
    [[ "$guids" -eq 1 ]] && return 0
    VERDICT_REASON="ranks disagree on rackGuid"
    VERDICT_DETAIL="$guids distinct values"
    return 1
}

## cublasmatmul. One TFLOPS figure per GPU is expected; requiring at least one
## is what stops a run that produced no number at all from passing on the
## absence of the word error.
_v_gate_cublasmatmul() {
    local file="$1" low
    _v_require_count "$file" "TFLOPS readings" '[0-9]+(\.[0-9]+)?[[:space:]]*TFLOPS' \
        "$VERDICT_MIN_TFLOPS_READINGS" || return 1
    _v_forbid "$file" "run error"   "$VERDICT_RUN_ERRORS" || return 1
    _v_forbid "$file" "GEMM result mismatch" 'mismatch|Mismatch' || return 1

    ## No-op while the floor is 0 -- see VERDICT_MIN_TFLOPS_GEMM above.
    [[ "$VERDICT_MIN_TFLOPS_GEMM" == 0 ]] && return 0
    low=$(grep -oiE "[0-9]+(\.[0-9]+)?[[:space:]]*TFLOPS" "$file" 2>/dev/null \
          | grep -oE "^[0-9]+(\.[0-9]+)?" \
          | awk -v min="$VERDICT_MIN_TFLOPS_GEMM" 'NF && $1 + 0 < min + 0' | head -1)
    [[ -z "$low" ]] && return 0
    VERDICT_REASON="GEMM below floor ${VERDICT_MIN_TFLOPS_GEMM} TFLOPS"
    VERDICT_DETAIL="slowest GPU measured ${low} TFLOPS"
    return 1
}

## STREAM. `Triad:  <best rate MB/s>  <avg>  <min>  <max>`, best rate gated.
_v_gate_stream() {
    local file="$1"
    _v_require "$file" "Triad result"      '^Triad:'          || return 1
    _v_forbid  "$file" "run error"         "$VERDICT_RUN_ERRORS" || return 1
    _v_forbid_i "$file" "STREAM solution validation failed" 'failed validation' || return 1
    _v_min_value "$file" "Triad bandwidth" '/^Triad:/ {print $2}' \
        "$VERDICT_MIN_TRIAD_MBS" "MB/s" || return 1
    return 0
}

## stressapptest ends with `Status: PASS` or `Status: FAIL`.
_v_gate_stressapptest() {
    local file="$1"
    _v_require  "$file" "stressapptest PASS status" '^Status: PASS' || return 1
    _v_forbid   "$file" "run error"                 "$VERDICT_RUN_ERRORS" || return 1
    _v_forbid_i "$file" "memory miscompare or hardware error" \
        'hardware error|miscompare|Status: FAIL' || return 1
    return 0
}

## memtester prints `<subtest> : ok` per subtest, `FAILURE` on a bad address,
## and `Done.` when every loop has finished. Both positive markers are required:
## with the error grep alone, output that stops partway through -- an OOM kill,
## a walltime kill, a memtester that is not installed -- reads as a pass.
_v_gate_memtester() {
    local file="$1"
    _v_require "$file" "memtester subtest results" ':[[:space:]]*ok[[:space:]]*$' || return 1
    _v_require "$file" "memtester Done marker"     '^Done\.?$' || return 1
    _v_forbid  "$file" "run error"                 "$VERDICT_RUN_ERRORS" || return 1
    ## FAILURE is memtester's own word for a bad address, and it prints it in
    ## caps. Matched case-sensitively so it cannot catch prose.
    _v_forbid  "$file" "memtester reported a bad address" 'FAILURE' || return 1
    return 0
}

## stress-ng prints `successful run completed` on a clean pass. `unsuccessful`
## is its word for the other outcome -- and note that `successful run
## completed` does not contain it, so the two rules do not collide.
_v_gate_stress_ng() {
    local file="$1"
    _v_require  "$file" "stress-ng completion line" 'successful run completed' || return 1
    _v_forbid   "$file" "run error"                 "$VERDICT_RUN_ERRORS" || return 1
    _v_forbid_i "$file" "stressor failed"           'unsuccessful|fatal|failed' || return 1
    return 0
}

## fio. One `read:`/`write:` IOPS summary per pass, four passes.
_v_gate_fio() {
    local file="$1"
    _v_require_count "$file" "fio IOPS summaries" 'IOPS=' \
        "$VERDICT_MIN_FIO_PASSES" || return 1
    _v_forbid "$file" "run error" "$VERDICT_RUN_ERRORS" || return 1
    ## `^fio: ` is how fio prefixes its own diagnostics. Anchored, because the
    ## string appears in ordinary output otherwise.
    _v_forbid "$file" "fio reported an error" \
        '^fio: |error=|No such file or directory' || return 1
    return 0
}

## ethr. The bandwidth and latency passes each print a results table.
_v_gate_ethr() {
    local file="$1"
    _v_require  "$file" "ethr results" 'Bandwidth|Latency' || return 1
    _v_forbid   "$file" "run error"    "$VERDICT_RUN_ERRORS" || return 1
    ## The interface having no address is the job's own message, and is the
    ## common case here -- a NIC named in IFACES that this node does not have.
    _v_forbid   "$file" "interface has no IPv4 address" '^ethr: no IPv4 address' || return 1
    _v_forbid_i "$file" "could not reach the ethr server" \
        'connection refused|no route to host|unable to' || return 1
    return 0
}

## HPL prints a residual check that ends in PASSED.
_v_gate_hpl() {
    local file="$1"
    _v_require "$file" "HPL PASSED line" 'PASSED' || return 1
    _v_forbid  "$file" "run error"       "$VERDICT_RUN_ERRORS" || return 1
    return 0
}

## llm-pretrain. Per-step timings are the evidence training actually stepped.
_v_gate_llm_pretrain() {
    local file="$1"
    _v_require  "$file" "training step timings" 'train_step_timing|reduced_train_loss' || return 1
    _v_forbid   "$file" "run error"             "$VERDICT_RUN_ERRORS" || return 1
    _v_forbid_i "$file" "training aborted"      'traceback|cuda error|nccl error|out of memory' || return 1
    return 0
}

## mnubergemm is an internal tool with no documented success banner, so there
## is no positive marker to require beyond the file being non-empty: a
## container that starts, runs nothing and exits 0 produces an empty file and a
## zero status. Add a real marker here once the clean-run format is known.
_v_gate_mnubergemm() {
    local file="$1"
    [[ -s "$file" ]] || { VERDICT_REASON="empty result file"; return 1; }
    _v_forbid "$file" "run error" "$VERDICT_RUN_ERRORS" || return 1
    _v_forbid "$file" "CUDA error, assertion or MPI abort" \
        'cuda error|CUDA_ERROR|assertion|assert failed|MPI_Abort' || return 1
    return 0
}

## nvsm. `nvsm show health` ends in a health summary; requiring it is what
## proves both srun steps got far enough to report.
##
## The fail/error sweep below is deliberately broad and is the one rule in this
## file that has NOT been checked against a captured healthy run -- `nvsm show
## health` reports on things whose names contain the word error, and if it
## prints any of them unconditionally this gate will false-fail the way
## nvbandwidth's N/A rule did. Capture a passing run as a fixture and narrow
## this to the strings nvsm uses for an actual fault.
_v_gate_nvsm() {
    local file="$1"
    _v_require  "$file" "nvsm health summary" 'Health Summary|System Status' || return 1
    _v_forbid   "$file" "run error"           "$VERDICT_RUN_ERRORS" || return 1
    _v_forbid_i "$file" "nvsm reported a health fault" 'fail|unhealthy|error' || return 1
    return 0
}

## The template job. Gated so the shape example.sbatch demonstrates is the
## shape that is actually in use -- it is copied for every new benchmark.
_v_gate_example() {
    local file="$1"
    _v_require "$file" "test job marker" '^Test job!$'    || return 1
    _v_forbid  "$file" "run error"       "$VERDICT_RUN_ERRORS" || return 1
    return 0
}

## Fallback for jobs that have no gate written for them yet. It applies the
## common failure signatures and nothing else -- it cannot know what that job's
## output is supposed to look like, so it does not pretend to. A job that
## matters belongs above, with a rule that names its own success condition.
_v_gate_generic() {
    local file="$1"
    [[ -s "$file" ]] || { VERDICT_REASON="empty result file"; return 1; }
    _v_forbid "$file" "run error" "$VERDICT_RUN_ERRORS" || return 1
    return 0
}

## ── Entry point ───────────────────────────────────────────────────────────

## verdict <job> <file>
##
## Sets VERDICT_STATUS to exactly one of:
##
##   NOT_RUN      no result file
##   INCOMPLETE   the file ends in no marker -- the job died before its last
##                line: node crash, walltime kill, OOM. Callers must treat this
##                as a failure, not as "no verdict yet", or a node that
##                reliably kills its jobs retries forever and never drains.
##                Note that "died" is the caller's conclusion, not this
##                function's evidence: sbatch writes --output as the job runs,
##                so a RUNNING job also has no marker yet. launch_job.sh earns
##                the conclusion by checking squeue before it judges anything;
##                status-check.sh, which reads results at arbitrary times,
##                re-labels the live column RUNNING. A caller doing neither
##                will call every in-flight job dead.
##   FAIL         the job reported it could not run, or the gate rejected it
##   DONE         the gate accepted it
##
## and VERDICT_REASON / VERDICT_DETAIL to why, for everything except DONE.
##
## This sets variables rather than echoing, and callers must NOT wrap it in
## $(...). Command substitution runs in a subshell, so the reason would be set
## in a child and lost -- leaving every failure reported with an empty
## explanation, which is the entire thing this file was written to provide.
verdict() {
    local job="$1" file="$2" last
    VERDICT_STATUS=""
    VERDICT_REASON=""
    VERDICT_DETAIL=""

    if [[ -z "$file" || ! -f "$file" ]]; then
        VERDICT_REASON="no result file"
        VERDICT_STATUS=NOT_RUN
        return
    fi

    last=$(tail -1 "$file" 2>/dev/null)
    case "$last" in
        FAIL)
            ## Self-reported: the job refused to run at all, or srun exited
            ## non-zero. The log is the diagnosis, not the gate.
            VERDICT_REASON="job reported FAIL"
            VERDICT_DETAIL="$(grep -nEm1 "$VERDICT_RUN_ERRORS|^No compute-plane HCA" "$file" 2>/dev/null | cut -c1-100)"
            VERDICT_STATUS=FAIL
            return
            ;;
        PENDING|DONE)
            ## PENDING is the current contract. DONE is legacy, written by an
            ## sbatch that judged itself before this file existed -- re-judged
            ## here rather than trusted, which is what retires those results.
            ;;
        *)
            VERDICT_REASON="no end marker -- job died before finishing"
            VERDICT_STATUS=INCOMPLETE
            return
            ;;
    esac

    case "$job" in
        allreduce)
            _v_gate_nccl "$file" nvlink "$VERDICT_MIN_BW_NVLINK" "$VERDICT_MIN_PEAK_BW_ALLREDUCE" ;;
        alltoall)
            _v_gate_nccl "$file" nvlink "$VERDICT_MIN_BW_NVLINK" "$VERDICT_MIN_PEAK_BW_ALLTOALL" ;;
        allreduce-nonvlink|alltoall-nonvlink)
            _v_gate_nccl "$file" ib "$VERDICT_MIN_BW_NONVLINK" "" ;;
        dcgm|dcgm-r2|dcgm-r4)
            _v_gate_dcgm "$file" ;;
        nvbandwidth)
            _v_gate_nvbandwidth "$file" ;;
        nvloom)
            _v_gate_nvloom "$file" ;;
        cublasmatmul)
            _v_gate_cublasmatmul "$file" ;;
        stream)
            _v_gate_stream "$file" ;;
        stressapptest)
            _v_gate_stressapptest "$file" ;;
        memtester)
            _v_gate_memtester "$file" ;;
        stress-ng)
            _v_gate_stress_ng "$file" ;;
        fio)
            _v_gate_fio "$file" ;;
        ethr)
            _v_gate_ethr "$file" ;;
        hpl)
            _v_gate_hpl "$file" ;;
        llm-pretrain)
            _v_gate_llm_pretrain "$file" ;;
        mnubergemm)
            _v_gate_mnubergemm "$file" ;;
        nvsm)
            _v_gate_nvsm "$file" ;;
        example)
            _v_gate_example "$file" ;;
        *)
            _v_gate_generic "$file" ;;
    esac && { VERDICT_STATUS=DONE; return; }

    VERDICT_STATUS=FAIL
}

## verdict_job_name <result-file-basename>
##
## Strips the -run<N> suffix multi-run jobs carry, so the caller can hand a
## column name straight to verdict().
verdict_job_name() {
    local name="${1##*/}"
    name="${name%.txt}"
    printf '%s' "${name%-run[0-9]*}"
}
