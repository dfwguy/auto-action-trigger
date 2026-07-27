#!/bin/bash
#
# Shared pass/fail rule for a benchmark result file. Sourced by
# actions/launch_job.sh, status-check.sh and status-daily-report.sh.
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
## (1.17 vs 2.23 on the h01-14 socket run), and status-daily-report.sh's
## extract_metric reports the largest-size row. Same file, two numbers -- do
## not compare a floor set here against a figure from that report.
VERDICT_MIN_BW_NVLINK=10
VERDICT_MIN_BW_NONVLINK=10

## Floors on the LARGEST-MESSAGE-SIZE out-of-place busbw, GB/s -- a different
## number from the ones above, read from a different place in the same file.
## These are the figures status-daily-report.sh prints in its allreduce and
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

## Failure signatures common to every job. A summary line can print in full and
## a rank still die on the way out, so this is checked independently of whether
## the expected output is present.
VERDICT_RUN_ERRORS='NCCL WARN|Test NCCL failure|Test failure|srun: error|Segmentation fault|CANCELLED AT|error: unable to|slurmstepd: error'

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
## status-daily-report.sh's extract_metric: pick the numeric-first-field rows,
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
