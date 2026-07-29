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

## Bandwidth floors, GB/s, on the LARGEST-MESSAGE-SIZE out-of-place busbw.
##
## One number, read from one place, for every NCCL job: the largest-size row
## is also what daily-report.sh prints in these columns (see extract_metric
## there), so a figure in the report can be compared against the floor here
## directly. That is the whole point of stating them this way. The
## `# Avg bus bandwidth` line is NOT gated -- it averages every message size and
## comes out roughly 2x lower on the same run (1.17 vs 2.23 on the h01-14 socket
## run), so a floor set against it could not be checked against anything an
## operator is looking at. It is still required to be present below, as evidence
## the run finished; it is just not the number judged.
##
## Set per job because alltoall and allreduce bus bandwidth are not comparable,
## and because NVLink scope and IB scope are two different fabrics: 683/623 are
## NVLink figures. The -nonvlink pair is gated at 43, which is the rate the
## compute-plane HCAs are expected to sustain on this platform.
##
## 43 is a spec figure, not one read off a known-good run, and it is the one
## floor in this file set ABOVE every IB-scope result captured so far: the
## fixture that used to be called good-ib measures 32.35 and is now a
## below-floor case. So there is currently no captured -nonvlink run that
## passes this gate. If a fleet-wide report comes back failing every node at
## 30-something rather than a handful, that is this floor being wrong and not
## the fabric -- check a report before acting on the drains.
VERDICT_MIN_PEAK_BW_ALLREDUCE=683
VERDICT_MIN_PEAK_BW_ALLTOALL=623
VERDICT_MIN_PEAK_BW_ALLREDUCE_NONVLINK=43
VERDICT_MIN_PEAK_BW_ALLTOALL_NONVLINK=43
## allreduce-forcesharp has no floor of its own on purpose. It is the same
## collective on the same fabric as allreduce, with NCCL_ALGO=NVLS removing the
## fallback -- so when it runs at all, it ran the way allreduce is meant to and
## the 683 above is the figure it should meet. A second number here would be a
## second thing to keep in step for no gain. The question that job asks is
## answered before the bandwidth is: a node without working NVLS fails in
## ncclCommInitRank and never reaches a summary line to be judged.

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

## Floor on the largest message size actually run, out-of-place busbw (column 8
## of the data rows). The extraction here is deliberately the same as
## daily-report.sh's extract_metric: pick the numeric-first-field rows,
## sort by size, take the last. If one of the two is ever changed the other must
## change with it, or the report will print a number that the gate did not judge.
##
## `sort -k1,1n` rather than "last row in the file" because nccl-tests does not
## guarantee the largest size is printed last -- and taking the tail of the file
## blind would read whatever the final row happens to be.
##
## Kept in awk because bash arithmetic is integer-only and every one of these
## values is a float -- `[[ 2.23 -lt 23 ]]` is a syntax error, not a false.
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
## $3 is the largest-size busbw floor, and is optional -- empty means no floor
## has been established for this job yet and it is judged on transport alone.
_v_gate_nccl() {
    local file="$1" transport="$2" peak_min="$3"

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

    ## Bandwidth last, and only the largest-size figure -- see the floors at the
    ## top of this file for why the `# Avg bus bandwidth` line is required above
    ## but not judged here.
    [[ -n "$peak_min" ]] && { _v_min_peak_bw "$file" "$peak_min" || return 1; }
    return 0
}

## Which dcgmi subtests came back Fail, by name, in the order the table lists
## them. The name is what makes the verdict actionable: `targeted_power` and
## `diagnostic` are the same status and nothing like the same problem.
##
## The table is a two-column grid, and a failing test spreads over several rows:
##
##   | targeted_power            | Fail                                           |
##   |                           | GPU0: Skip                                     |
##   | Warning: GPU0             | Enforced power limit on GPU 0 set to 699.0, w  |
##   |                           | GPU2: Pass                                     |
##
## so the name is carried forward from the last row that had one -- the per-GPU
## rows underneath leave the first column empty and are reported against the
## test above them. Rows whose first column is a rule (`-----`, `=====`) are not
## names and must not be carried forward, or a Fail further down gets reported
## against a section header.
##
## Names only, no measured values and no GPU indices: this becomes
## VERDICT_REASON, which has to read identically on every node failing the same
## way -- see the note on VERDICT_REASON above. The specifics go in the detail.
_v_dcgm_failed_tests() {
    awk -F'|' '
        NF >= 3 {
            name = $2; res = $3
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", res)
            if (name != "" && name !~ /^[-=+]/ && name !~ /^Warning:/ && name !~ /^Error:/)
                last = name
            ## `Fail` on its own is the test verdict; `GPU3: Fail` is one GPU
            ## under it. Either one fails the test named in $last.
            if (res ~ /^(GPU[0-9]+:[[:space:]]*)?Fail$/ && last != "" && !(last in seen)) {
                seen[last] = 1
                order[++n] = last
            }
        }
        ## Capped, because this string can end up in a Slurm drain reason, which
        ## is one short field. The full table is in the result file.
        END {
            for (i = 1; i <= n && i <= 3; i++) printf "%s%s", (i > 1 ? ", " : ""), order[i]
            if (n > 3) printf ", and %d more", n - 3
        }' "$1" 2>/dev/null
}

## The line that explains a dcgmi failure, for VERDICT_DETAIL. dcgmi prints its
## reasoning in a `Warning:`/`Error:` row under the failing test -- the enforced
## power limit, the field that went out of range -- and that row, not the bare
## `Fail`, is what tells an operator whether the node is broken or the profile
## is wrong. Falls back to the Fail row itself for output that carries no
## warning text.
_v_dcgm_fail_detail() {
    local file="$1" hit
    hit=$(grep -nEm1 '^\|[[:space:]]*(Warning|Error)[^|]*\|' "$file" 2>/dev/null)
    [[ -n "$hit" ]] ||
        hit=$(grep -nEm1 '\|[[:space:]]*(GPU[0-9]+:[[:space:]]*)?Fail[[:space:]]*\|' "$file" 2>/dev/null)
    [[ -n "$hit" ]] || return 0
    ## The row is a table cell either side of a `|` padded out to the column
    ## width, so the padding is squeezed out and the divider spelled -- read as
    ## captured it is a header and forty spaces before the text that matters.
    printf 'line %s: %s' "${hit%%:*}" \
        "$(printf '%s' "${hit#*:}" \
           | sed 's/^[[:space:]|]*//; s/[[:space:]|]*$//; s/[[:space:]]*|[[:space:]]*/ -- /g' \
           | cut -c1-90)"
}

## `dcgmi diag` prints a results table of `| <test> | Pass |` rows on a clean
## run. Requiring at least one distinguishes a passing diagnostic from one that
## never ran -- no dcgmi binary, nv-hostengine down, no GPUs visible. Without it
## the error grep alone reports a pass for empty output.
##
## The named-subtest check comes before the broad fail/warn/error sweep so that
## the reason says WHICH test failed. The sweep stays underneath it as the
## catch-all: it is what still catches a dcgmi that reported a problem outside
## the results table, and dropping it would narrow this gate rather than sharpen
## it.
_v_gate_dcgm() {
    local file="$1" failed
    _v_require   "$file" "dcgmi Pass row"          '\|[[:space:]]*Pass[[:space:]]*\|' || return 1

    failed=$(_v_dcgm_failed_tests "$file")
    if [[ -n "$failed" ]]; then
        VERDICT_REASON="dcgmi subtest failed: $failed"
        VERDICT_DETAIL="$(_v_dcgm_fail_detail "$file")"
        return 1
    fi

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

## Run the gate for a job. Split out of verdict() because it is needed twice:
## once to judge a result that ran to completion, and once to explain a result
## whose job condemned itself -- see the FAIL branch below.
_v_dispatch_gate() {
    local job="$1" file="$2"
    case "$job" in
        allreduce)
            _v_gate_nccl "$file" nvlink "$VERDICT_MIN_PEAK_BW_ALLREDUCE" ;;
        allreduce-forcesharp)
            ## Deliberately the same floor as allreduce -- see the note by it.
            _v_gate_nccl "$file" nvlink "$VERDICT_MIN_PEAK_BW_ALLREDUCE" ;;
        alltoall)
            _v_gate_nccl "$file" nvlink "$VERDICT_MIN_PEAK_BW_ALLTOALL" ;;
        allreduce-nonvlink)
            _v_gate_nccl "$file" ib "$VERDICT_MIN_PEAK_BW_ALLREDUCE_NONVLINK" ;;
        alltoall-nonvlink)
            _v_gate_nccl "$file" ib "$VERDICT_MIN_PEAK_BW_ALLTOALL_NONVLINK" ;;
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
    esac
}

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
##
## The disable below is for those three variables. Setting them IS this
## function's return value, but every read of them happens in a caller that
## sources this file, so shellcheck -- which sees one file at a time -- reads
## the assignments as dead stores. Scoped to the function rather than the file
## so that a genuinely unused variable added elsewhere here still gets caught.
# shellcheck disable=SC2034
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
            ## Self-reported: the job refused to run at all, or the workload
            ## exited non-zero.
            ##
            ## The STATUS is not re-judged -- a self-reported FAIL stays a FAIL
            ## whatever the log says, which is the property the nvbandwidth note
            ## above depends on. The REASON is, because "job reported FAIL" names
            ## no cause: `dcgmi diag` exits 226 on a failed subtest and the
            ## sbatch, which only decides whether the job RAN, turns that into a
            ## bare FAIL. Fifty nodes then read `dcgm: FAIL -- job reported FAIL`
            ## and every one of them had to be opened by hand to find the one
            ## line that said which subtest.
            ##
            ## Asked in causal order, first answer wins: a run error explains the
            ## non-zero exit on its own, and the gate is asked last because on a
            ## job that died early its positive checks report the missing output
            ## rather than the reason it is missing.
            VERDICT_STATUS=FAIL
            _v_forbid "$file" "run error"                "$VERDICT_RUN_ERRORS"   &&
            _v_forbid "$file" "no compute-plane HCA"     '^No compute-plane HCA' &&
            _v_dispatch_gate "$job" "$file" && {
                ## Nothing in the log accounts for it -- the exit status is all
                ## there is. Same words as before, now meaning "and we looked".
                VERDICT_REASON="job reported FAIL"
                VERDICT_DETAIL=""
            }
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

    _v_dispatch_gate "$job" "$file" && { VERDICT_STATUS=DONE; return; }

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
