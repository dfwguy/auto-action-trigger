#!/bin/bash
#
# Shared pass/fail rule for a benchmark result file. Sourced by
# actions/launch_job.sh, status-check.sh and daily-report.sh.
#
# A verdict is DERIVED, never stored: an sbatch writes FAIL (could not run) or
# PENDING (ran, srun exited 0), and DONE is computed here from the log on every
# read, so tightening a gate re-judges every result already on disk. Files
# ending in DONE are legacy and are re-judged here rather than trusted.
# See docs/benchmarks.md#where-a-pass-is-decided.

## Bandwidth floors, GB/s, on the LARGEST-MESSAGE-SIZE out-of-place busbw --
## the same figure daily-report.sh prints, so report and floor compare directly.
## The `# Avg bus bandwidth` line is required below as evidence the run finished
## but is not judged. Per job because alltoall and allreduce are not comparable
## and NVLink and IB are different fabrics: 683/665/623 are NVLink figures; 43
## is the compute-plane HCA spec figure and sits above every IB-scope result
## captured so far, so suspect it, not the fabric, if every node fails in the
## thirties. See docs/benchmarks.md#host-hcas-are-not-container-hcas.
VERDICT_MIN_PEAK_BW_ALLREDUCE=683
VERDICT_MIN_PEAK_BW_ALLTOALL=623
VERDICT_MIN_PEAK_BW_ALLREDUCE_NONVLINK=43
VERDICT_MIN_PEAK_BW_ALLTOALL_NONVLINK=43
## A second check on a node that runs SHARP slowly, not the thing that finds a
## node lacking it -- without NVLS the job dies in ncclCommInitRank first. 665
## rather than allreduce's 683 because pinning NCCL_ALGO costs a little
## bandwidth; it is the bottom of the healthy band on ink50 (665.0-673.3) and
## clears it only just, so suspect this floor first if isolated nodes fail by a
## fraction of a GB/s. See docs/benchmarks.md#judge-what-the-tool-means-not-what-it-says.
VERDICT_MIN_PEAK_BW_ALLREDUCE_FORCESHARP=665

## Floors for the non-NCCL jobs, here rather than in each sbatch for the same
## reason the NCCL floors are -- see the header. A floor of 0 means one has not
## been established for this platform yet; the gate skips that check rather than
## passing everything, and says so at the point of use.
VERDICT_MIN_TRIAD_MBS=400000        ## STREAM Triad, MB/s
VERDICT_MIN_TFLOPS_GEMM=0           ## cublasmatmul per-GPU TFLOPS -- not set
VERDICT_MIN_TFLOPS_READINGS=1       ## one TFLOPS figure per GPU is expected

## nvbandwidth run-to-run instability, from MOP section 6.2. Set above the MOP's
## 0.02: the one_to_all and host_to_all families print 0.01-0.04 on healthy
## nodes, where the spread is real topology rather than instability. 0.08 clears
## that band and still catches a link varying enough to drag a benchmark down.
VERDICT_MAX_COV_NVBANDWIDTH=0.08

## fio runs four passes (read, write, randread, randwrite) and each prints one
## IOPS summary, so fewer than four means a pass did not report.
VERDICT_MIN_FIO_PASSES=4

## Failure signatures common to every job. A summary line can print in full and
## a rank still die on the way out, so this is checked independently of whether
## the expected output is present. The last two are the two ways an overrun
## arrives -- Slurm's step cancellation and the dcgm jobs' `timeout` wrapper --
## so it is reported as a run error rather than as missing output. See
## docs/benchmarks.md#two-time-limits-and-the-order-they-fire-in.
VERDICT_RUN_ERRORS='NCCL WARN|Test NCCL failure|Test failure|srun: error|Segmentation fault|CANCELLED AT|error: unable to|slurmstepd: error|^timeout: killed after'

## Set by verdict() on every call. REASON must read IDENTICALLY on every node
## failing the same way -- status-check.sh groups through dshbak, so anything
## per-node in it splits one block into forty. Per-node specifics (line number,
## matched text, measured value) go in DETAIL and nowhere else.
## See docs/operations.md#status-and-reporting.
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

## Pattern must be absent. The detail carries the line number and matched text,
## because "which line said so" is the first thing anyone asks.
_v_forbid() {
    local file="$1" label="$2" re="$3" hit
    hit=$(grep -nEm1 "$re" "$file" 2>/dev/null)
    [[ -z "$hit" ]] && return 0
    VERDICT_REASON="$label"
    VERDICT_DETAIL="line ${hit%%:*}: $(printf '%s' "${hit#*:}" | sed 's/^[[:space:]]*//' | cut -c1-90)"
    return 1
}

## Case-insensitive _v_forbid, for rules that are deliberately broad. Fixed
## strings like `NCCL WARN` stay case-sensitive so they cannot catch prose --
## see docs/benchmarks.md#judge-what-the-tool-means-not-what-it-says.
_v_forbid_i() {
    local file="$1" label="$2" re="$3" hit
    hit=$(grep -niEm1 "$re" "$file" 2>/dev/null)
    [[ -z "$hit" ]] && return 0
    VERDICT_REASON="$label"
    VERDICT_DETAIL="line ${hit%%:*}: $(printf '%s' "${hit#*:}" | sed 's/^[[:space:]]*//' | cut -c1-90)"
    return 1
}

## Floor on the largest message size actually run, out-of-place busbw (column 8).
## Extraction must stay identical to daily-report.sh's extract_metric, or the
## report prints a number the gate did not judge. `sort -k1,1n` because
## nccl-tests does not guarantee the largest size is printed last. Comparison in
## awk because bash arithmetic is integer-only and these are floats.
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

## Pattern must appear at least $min times, where one line per pass is the
## evidence every pass ran. `_v_require` alone would accept the first of four.
_v_require_count() {
    local file="$1" label="$2" re="$3" min="$4" n
    n=$(grep -cE "$re" "$file" 2>/dev/null)
    [[ "$n" -ge "$min" ]] && return 0
    VERDICT_REASON="fewer than $min $label"
    VERDICT_DETAIL="found $n"
    return 1
}

## Floor on a single value extracted by an awk program. $5 is the unit, and
## belongs in the REASON rather than the detail: "below floor 400000 MB/s" reads
## the same on every node failing that way, so dshbak keeps them in one block.
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
## -nonvlink pair, which forces traffic out to the HCAs, or `nvlink`. $3 is the
## largest-size busbw floor, optional -- empty means none has been established
## and the run is judged on transport alone.
##
## Only the per-channel `via ...` lines are evidence of where data went; `Using
## network IB`/`Socket` name the plugin NCCL registered and prove nothing. See
## docs/benchmarks.md#judge-the-channels-never-the-plugin-registration.
_v_gate_nccl() {
    local file="$1" transport="$2" peak_min="$3"

    ## Printed only after every message size ran and validated, so requiring them
    ## is a positive check. A run that dies in ncclCommInitRank prints neither.
    _v_require "$file" "out-of-bounds validation"  '^# Out of bounds values *: *0 OK' || return 1
    _v_require "$file" "bus-bandwidth summary"     '^# Avg bus bandwidth *:'          || return 1
    _v_forbid  "$file" "run error"                 "$VERDICT_RUN_ERRORS"              || return 1

    ## Ordered by causation, not severity -- the first check to fire is the one
    ## whose reason gets reported, so keep new checks in the chain's order. See
    ## docs/benchmarks.md#host-hcas-are-not-container-hcas.
    if [[ "$transport" == "ib" ]]; then
        ## jobs/nvl72/nccl-hca.sh makes the same libibverbs call NCCL does from
        ## inside the container; `(none)` here is the root cause stated plainly.
        ## A result from before that probe existed has no such line.
        _v_forbid  "$file" "no HCA visible inside the container" \
            'container sees HCAs [^:]*: \(none\)' || return 1

        _v_forbid  "$file" "no IB device visible to NCCL"  'NET/IB : No device found'   || return 1
        _v_forbid  "$file" "IB plugin failed to load"      'Failed to initialize NET plugin IB' || return 1
        _v_require "$file" "IB named as chosen network"    'Using network IB'           || return 1

        ## Last, not first: everything explaining WHY it fell back is ruled out
        ## by here, so a hit means a reason not yet accounted for.
        _v_forbid "$file" "collective carried over TCP" 'via NET/Socket' || return 1
    else
        ## NVLink scope: any channel on the net fails, Socket or IB. A forbid
        ## rather than "require via P2P" so it cannot false-fail a legitimate
        ## path the one healthy log inspected did not happen to name.
        _v_forbid "$file" "collective left NVLink for the network" 'via NET/' || return 1
    fi

    ## Deliberately not forbidding `via SHM` yet: it is a real degradation on the
    ## NVLink scope, but no known-good log from this platform has been read to
    ## confirm NCCL never uses it, and a wrong forbid drains the whole cluster at
    ## once. The bandwidth floor catches the gross case meanwhile.

    ## Bandwidth last, and only the largest-size figure -- see the floors at the
    ## top of this file.
    [[ -n "$peak_min" ]] && { _v_min_peak_bw "$file" "$peak_min" || return 1; }
    return 0
}

## Which dcgmi subtests came back Fail, by name, in table order -- the name is
## what makes the verdict actionable. A failing test spreads over several rows
## whose first column is empty, so the name is carried forward from the last row
## that had one; rules (`-----`, `=====`) are not names and must not be carried,
## or a Fail gets reported against a section header. Names only, no values or GPU
## indices: this becomes VERDICT_REASON -- see the note on it above.
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

## The line that explains a dcgmi failure, for VERDICT_DETAIL. dcgmi's
## `Warning:`/`Error:` row under the failing test, not the bare `Fail`, is what
## tells an operator whether the node is broken or the profile is wrong. Falls
## back to the Fail row for output that carries no warning text.
_v_dcgm_fail_detail() {
    local file="$1" hit
    hit=$(grep -nEm1 '^\|[[:space:]]*(Warning|Error)[^|]*\|' "$file" 2>/dev/null)
    [[ -n "$hit" ]] ||
        hit=$(grep -nEm1 '\|[[:space:]]*(GPU[0-9]+:[[:space:]]*)?Fail[[:space:]]*\|' "$file" 2>/dev/null)
    [[ -n "$hit" ]] || return 0
    ## Padding squeezed out and the divider spelled: read as captured the row is
    ## a header and forty spaces before the text that matters.
    printf 'line %s: %s' "${hit%%:*}" \
        "$(printf '%s' "${hit#*:}" \
           | sed 's/^[[:space:]|]*//; s/[[:space:]|]*$//; s/[[:space:]]*|[[:space:]]*/ -- /g' \
           | cut -c1-90)"
}

## Requiring one `| <test> | Pass |` row distinguishes a passing diagnostic from
## one that never ran -- no dcgmi binary, nv-hostengine down, no GPUs visible.
## The named-subtest check comes before the broad fail/warn/error sweep so the
## reason says WHICH test failed; the sweep stays as the catch-all for a problem
## reported outside the results table.
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

## nvbandwidth, per MOP section 6.2. Section 6.1's per-test SUM thresholds are
## the GB200 4-GPU baseline and do not transfer to this platform, so no SUM floor
## is applied -- adding one here later re-judges every result on disk.
##
## Section 6.2's N/A rule is about POSITION, not the string: on a GPU(row) x
## GPU(column) matrix N/A is expected on the diagonal and nowhere else, and in
## the CPU(row) matrices every cell is a real transfer. Matching the string flat
## is what made this gate necessary -- see
## docs/benchmarks.md#judge-what-the-tool-means-not-what-it-says.
_v_nvb_missing_peer() {
    local file="$1" hit
    hit=$(awk '
        ## Reset at each test, not just on a CPU(row) header: device_local_copy
        ## prints GPU(column) with no row axis and would otherwise inherit the
        ## diagonal exemption from the previous test.
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

## Each test prints its own coefficient of variation after its matrix; any one
## over the bar fails the run.
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

    ## One SUM line per completed test, so this is the positive check: a tool
    ## that never started, or a container without GPUs, prints none.
    _v_require "$file" "per-test SUM lines" '^SUM ' || return 1
    _v_forbid  "$file" "run error"          "$VERDICT_RUN_ERRORS" || return 1

    ## nvbandwidth's own words for a test it declined to run, matched narrowly
    ## and case-sensitively. Deliberately not a bare `error` sweep -- a blanket
    ## grep over a log full of test names is how the N/A false-fail got in.
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

## memtester prints `<subtest> : ok` per subtest and `Done.` when every loop has
## finished. Both are required: with the error grep alone, output that stops
## partway through -- OOM, walltime kill, no binary -- reads as a pass.
_v_gate_memtester() {
    local file="$1"
    _v_require "$file" "memtester subtest results" ':[[:space:]]*ok[[:space:]]*$' || return 1
    _v_require "$file" "memtester Done marker"     '^Done\.?$' || return 1
    _v_forbid  "$file" "run error"                 "$VERDICT_RUN_ERRORS" || return 1
    ## memtester's own word for a bad address, printed in caps. Case-sensitive
    ## so it cannot catch prose.
    _v_forbid  "$file" "memtester reported a bad address" 'FAILURE' || return 1
    return 0
}

## stress-ng prints `successful run completed` on a clean pass; `unsuccessful`
## is its word for the other outcome, and the pass line does not contain it, so
## the two rules do not collide.
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
    ## `fio: ` prefixes fio's own diagnostics. Anchored, because the string
    ## appears in ordinary output otherwise.
    _v_forbid "$file" "fio reported an error" \
        '^fio: |error=|No such file or directory' || return 1
    return 0
}

## ethr. The bandwidth and latency passes each print a results table.
_v_gate_ethr() {
    local file="$1"
    _v_require  "$file" "ethr results" 'Bandwidth|Latency' || return 1
    _v_forbid   "$file" "run error"    "$VERDICT_RUN_ERRORS" || return 1
    ## The job's own message, and the common case here -- a NIC named in IFACES
    ## that this node does not have.
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

## nvsm. The health summary proves both srun steps got far enough to report.
## The fail/error sweep is the loosest rule in this file and the one never
## checked against a captured healthy run -- narrow it to nvsm's own fault
## strings once one exists. See
## docs/benchmarks.md#judge-what-the-tool-means-not-what-it-says.
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

## Fallback for jobs with no gate yet: the common failure signatures and nothing
## else, because it cannot know what that job's output should look like. A job
## that matters belongs above, with a rule naming its own success condition.
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
            _v_gate_nccl "$file" nvlink "$VERDICT_MIN_PEAK_BW_ALLREDUCE_FORCESHARP" ;;
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
##   INCOMPLETE   no end marker. "Died" is the caller's conclusion, not this
##                function's evidence -- a RUNNING job has no marker either, so
##                a caller that does not check squeue first will call every
##                in-flight job dead. See docs/operations.md#status-and-reporting.
##   FAIL         the job reported it could not run, or the gate rejected it
##   DONE         the gate accepted it
##
## and VERDICT_REASON / VERDICT_DETAIL to why, for everything except DONE.
##
## Callers must NOT wrap this in $(...): the subshell would set the reason in a
## child and lose it, leaving every failure reported with no explanation.
##
## Scoped to the function, not the file, so a genuinely unused variable added
## elsewhere here is still caught: setting those three IS the return value, but
## every read is in a caller, and shellcheck sees one file at a time.
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
            ## Self-reported: the job could not run, or the workload exited
            ## non-zero. The STATUS is taken at its word and never re-judged --
            ## the property the nvbandwidth note above depends on -- but the
            ## REASON is derived, because "job reported FAIL" names no cause and
            ## an sbatch only decides whether the job RAN.
            ##
            ## Asked in causal order, first answer wins: the gate is last because
            ## on a job that died early its positive checks report the missing
            ## output rather than the reason it is missing.
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
            ## PENDING is the current contract; DONE is legacy and is re-judged
            ## here rather than trusted -- see the header.
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
