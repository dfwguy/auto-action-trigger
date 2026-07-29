#!/bin/bash
#
# Judges every (node, column) cell of the fleet, in parallel, and writes one
# row per cell:
#
#   <node><FS><column><FS><status><FS><reason><FS><metric>
#
# where FS is ASCII US (0x1f), NOT a tab -- see SCAN_FS below, which is the one
# thing about this format worth reading before changing it.
#
# Sourced by status-check.sh and daily-report.sh, which each ignore the fields
# they do not use. Both used to walk the fleet themselves, judging one cell per
# iteration in the reporting shell; on a fleet of thousands of nodes that is
# tens of thousands of sequential verdict() calls, each of which forks a handful
# of greps. Reading every result file on the cluster is a fraction of a second
# of work -- the cost is the process churn, and the fact that one shell does all
# of it.
#
# Two things follow from that, and both are the point of this file:
#
#   * The walk is chunked across SCAN_JOBS worker processes. No verdict depends
#     on another node, so there is no ordering to preserve during the scan --
#     only in the output, which the callers sort.
#   * The per-cell path forks as little as it can, because any saving there is
#     multiplied by every cell on the cluster. `_scan_last_archive` in
#     particular is a bash glob rather than `ls | sed | sort | tail`: it fires
#     on every NOT_RUN cell, which is MOST of them early in a bringup, when
#     these reports are read most often.
#
# This file is both sourced and run: sourced by the reporting scripts for
# scan_fleet(), and run by xargs as the worker -- the same arrangement as
# node_health.sh running each health check with `bash "$check_file"`, and the
# reason this is 644 rather than 755. Running it by hand does a scan with no
# caller to make a report out of it.

## The field separator for a scan row, and deliberately not a tab.
##
## `read` splits on IFS, but when IFS holds a WHITESPACE character it also
## collapses runs of it -- so with a tab, a row whose reason is empty and whose
## metric is not, which is every passing cell that produced a number, delivers
## the metric into the reason's variable and leaves the metric empty. The report
## then prints DONE in a column that has a figure for it. It reads as a parsing
## bug in the gate, and it is not: it is one line of the reader.
##
## US (0x1f) is not IFS whitespace, so the empty field survives, and no
## benchmark writes one into a log. Callers must split on SCAN_FS, never on a
## tab -- daily-report.sh's TABLE is still tab separated, which is a different
## thing at a different layer.
SCAN_FS=$'\037'

## ── Metric extraction ─────────────────────────────────────────────────────
## A single numeric value (or empty) for a completed result file. Lives here
## rather than in daily-report.sh because the worker is what has the file open,
## and because the allreduce/alltoall extraction has to stay identical to
## verdict.sh's _v_min_peak_bw -- the report must print the number the gate
## judged. Change one and change the other.
##
## One awk per metric, not a pipeline: these run on every DONE or FAIL cell.

extract_metric() {
    local job="$1" file="$2"
    case "$job" in
        hpl)
            # WC summary line: T/V N NB P Q Time Gflops (per_GPU)
            awk '/^WC/ { print $7; exit }' "$file" 2>/dev/null
            ;;
        allreduce|alltoall|allreduce-nonvlink|alltoall-nonvlink|allreduce-forcesharp)
            # Out-of-place busbw at the largest message size actually run --
            # the same number verdict.sh's _v_min_peak_bw judges against
            # VERDICT_MIN_PEAK_BW_*, so this column can be read against those
            # floors directly. The maximum is tracked in the pass because
            # nccl-tests does not guarantee the largest size is printed last.
            awk '$1 ~ /^[0-9]+$/ && $1 + 0 >= big { big = $1 + 0; v = $8 }
                 END { print v }' "$file" 2>/dev/null
            ;;
        nvbandwidth)
            # Lowest SUM across the requested test cases -- the weakest path
            awk '/^SUM / { if (n++ == 0 || $NF + 0 < m + 0) m = $NF }
                 END { if (n) print m }' "$file" 2>/dev/null
            ;;
        stream)
            # Triad best rate, MB/s
            awk '/^Triad:/ { print $2; exit }' "$file" 2>/dev/null
            ;;
        fio)
            # Highest aggregate bandwidth reported across the four passes.
            # Still `sort -h`: these values carry K/M/G suffixes and the
            # ordering wanted is human-numeric, which awk has no equivalent of.
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

## ── Per-node scan ─────────────────────────────────────────────────────────

# Newest <col>.<kind><N>.txt, into _SCAN_ARCHIVE. `.fail<N>.txt` is
# launch_job.sh's archive of a rejected attempt; `.prev<N>.txt` is a PASSING
# result moved aside by `launch_job.sh --all`, never counted as a failure.
# Selected by numeric suffix, not mtime: an rsync or restore reorders mtimes,
# the suffix is authoritative.
#
# A glob and parameter expansion rather than `ls | sed | sort | tail`, which is
# four processes. This runs twice for every NOT_RUN cell, so on a fleet that has
# not run yet it was the largest single source of forks in either report.
_scan_last_archive() {
    local node="$1" col="$2" kind="$3" f n best=-1
    _SCAN_ARCHIVE=""
    for f in "$SCAN_RESULTS_DIR/$node/${col}.${kind}"[0-9]*.txt; do
        ## An unmatched glob is left literal, so this is the "no archives" case
        ## as much as it is a guard against a directory of that name.
        [[ -f "$f" ]] || continue
        n="${f##*/}"
        n="${n#"${col}.${kind}"}"
        n="${n%.txt}"
        [[ "$n" =~ ^[0-9]+$ ]] || continue
        ## 10#: a suffix like 08 is decimal here, not octal.
        if (( 10#$n > best )); then
            best=$(( 10#$n ))
            _SCAN_ARCHIVE="$f"
        fi
    done
    [[ -n "$_SCAN_ARCHIVE" ]]
}

# The column a running batch is currently writing, into _SCAN_LIVE, or empty.
# squeue knows the node but not the benchmark; the file system does. sbatch
# truncates --output at job start and every benchmark is --exclusive, so the
# live job's file is the newest result file on the node even before it writes
# its first byte.
#
# Archives are excluded: launch_job.sh `mv`s them at submit time, which can
# leave one newer than the file the new job is writing.
#
# Still three processes, and deliberately: this runs only for the nodes squeue
# named as RUNNING, which is a small minority of any fleet, and `ls -t` is the
# ordering the exclusion has to follow.
_scan_live_column() {
    local node="$1" f
    _SCAN_LIVE=""
    ## `ls -t` is the point: a glob expands in collating order, so newest-first
    ## would cost a stat per file, and the exclusion must follow the ordering.
    ## Every name here is a BENCHMARKS entry plus a fixed suffix, so the odd
    ## filenames SC2010 guards against cannot arise.
    # shellcheck disable=SC2010
    f=$(ls -t "$SCAN_RESULTS_DIR/$node"/*.txt 2>/dev/null \
        | grep -vE '\.(fail|prev)[0-9]+\.txt$' | head -1)
    [[ -n "$f" ]] || return
    f="${f##*/}"
    _SCAN_LIVE="${f%.txt}"
}

## One node, every column, one row per cell on stdout.
##
## Each row is written with a SINGLE printf. Workers share this stdout, and on
## Linux a write under PIPE_BUF is atomic while a field-at-a-time printf is
## not -- building the line first is what stops two workers interleaving into
## one corrupt row.
_scan_node() {
    local node="$1" col job file status reason metric i

    _SCAN_LIVE=""
    [[ -n "${_SCAN_RUNNING[$node]:-}" ]] && _scan_live_column "$node"

    for ((i = 0; i < ${#_SCAN_COLS[@]}; i++)); do
        col="${_SCAN_COLS[i]}"
        job="${_SCAN_COL_JOB[i]}"
        file="$SCAN_RESULTS_DIR/$node/${col}.txt"

        # Not $(verdict ...) -- a subshell would lose the reason. See verdict().
        verdict "$job" "$file"
        status="$VERDICT_STATUS"
        reason="$VERDICT_REASON"

        if [[ "$SCAN_ARCHIVES" == 1 && "$status" == "NOT_RUN" ]]; then
            ## launch_job.sh archives a rejected result before submitting the
            ## retry, so the column has no file at all in between. Judge the
            ## newest archive and call it RETRY, leaving NOT_RUN one meaning:
            ## never attempted.
            if _scan_last_archive "$node" "$col" fail; then
                verdict "$job" "$_SCAN_ARCHIVE"
                status=RETRY
                ## Not a contradiction: the gate has been loosened since the
                ## archive was rejected. Say so rather than printing RETRY with
                ## no reason.
                if [[ "$VERDICT_STATUS" == "DONE" ]]; then
                    reason="prior attempt passes the current gate"
                else
                    reason="$VERDICT_REASON"
                fi
            ## Same gap from `launch_job.sh --all`, which archives a PASSING
            ## result as <col>.prevN.txt -- no current file, no failures either.
            elif _scan_last_archive "$node" "$col" prev; then
                verdict "$job" "$_SCAN_ARCHIVE"
                status=RETRY
                reason="re-queued by --all; previous result: $VERDICT_STATUS"
            fi
        fi

        ## Only the column being written now. --exclusive runs these one at a
        ## time, so any OTHER marker-less file was left by a job that has exited.
        if [[ "$status" == "INCOMPLETE" && -n "$_SCAN_LIVE" && "$col" == "$_SCAN_LIVE" ]]; then
            status=RUNNING
            reason="job is on the node now, no verdict until it finishes"
        fi

        ## DONE and FAIL only: an INCOMPLETE log still carries parseable rows,
        ## and its largest message size is whichever one it reached.
        metric=""
        if [[ "$SCAN_METRICS" == 1 && ( "$status" == "DONE" || "$status" == "FAIL" ) ]]; then
            metric=$(extract_metric "$job" "$file")
        fi

        printf '%s%s%s%s%s%s%s%s%s\n' \
            "$node" "$SCAN_FS" "$col" "$SCAN_FS" "$status" \
            "$SCAN_FS" "$reason" "$SCAN_FS" "$metric"
    done
}

## ── Worker ────────────────────────────────────────────────────────────────

## Everything the worker needs arrives in the environment, except the node
## names, which arrive as arguments because that is what lets xargs do the
## chunking. The running-node list is a file rather than a variable: on a large
## fleet that is thousands of names, and every worker would carry a copy of it
## through exec.
scan_worker() {
    local n
    declare -gA _SCAN_RUNNING=()
    if [[ -n "$SCAN_RUNNING_FILE" && -r "$SCAN_RUNNING_FILE" ]]; then
        while IFS= read -r n; do
            [[ -n "$n" ]] && _SCAN_RUNNING["$n"]=1
        done < "$SCAN_RUNNING_FILE"
    fi

    ## Hoisted out of the per-cell path: the column -> job mapping is identical
    ## for every node, and working it out per cell cost a subshell apiece --
    ## one per cell on the cluster, for an answer that never changes.
    read -r -a _SCAN_COLS <<< "$SCAN_COLUMNS"
    _SCAN_COL_JOB=()
    for n in "${_SCAN_COLS[@]}"; do
        _SCAN_COL_JOB+=("$(verdict_job_name "$n")")
    done

    for n in "$@"; do
        _scan_node "$n"
    done
}

## ── Parallel fan-out ──────────────────────────────────────────────────────

## scan_fleet <node>...
##
## One row per cell on stdout, in no particular order -- callers sort. Reads the
## rest of its configuration from the environment; see scan_worker.
##
## The scan happens in children, so nothing it does can build state in the
## caller's shell. That is the same trap the old in-process scan carried -- the
## "never pipe this in summary mode" note -- moved somewhere it cannot be
## tripped by accident: a caller that wants a per-node roll-up now has to fold
## these rows itself.
##
## Worker stderr is deliberately NOT redirected. A worker that cannot read a
## results directory has to be able to say so; a silent scan reports a clean
## cluster, which is the failure this tree is built to avoid.
_scan_fleet_raw() {
    local n_nodes=$# jobs chunk

    (( n_nodes )) || return 0

    jobs="${SCAN_JOBS:-0}"
    if [[ ! "$jobs" =~ ^[0-9]+$ ]] || (( jobs < 1 )); then
        jobs=$(nproc 2>/dev/null) || jobs=4
    fi

    ## Roughly four chunks per worker, so one node with a slow results directory
    ## cannot leave a worker holding a quarter of the cluster after the others
    ## have finished. Not one node per chunk: every chunk pays a bash startup
    ## and a re-source of verdict.sh.
    chunk=$(( (n_nodes + jobs * 4 - 1) / (jobs * 4) ))
    (( chunk < 1 )) && chunk=1

    ## -d '\n' so a node name is taken literally rather than through xargs'
    ## quote handling; -r so an empty list runs nothing at all, rather than one
    ## worker with no arguments.
    printf '%s\n' "$@" \
        | xargs -r -d '\n' -n "$chunk" -P "$jobs" bash "$SCAN_LIB"
}

## ── Cache ─────────────────────────────────────────────────────────────────
##
## A judgement is a pure function of the result file and the gate, so a node
## whose files have not changed since the last report cannot have a different
## answer this time. The cache is that observation and nothing more: it never
## decides anything, it only says "you already worked this out".
##
## THE KEY INCLUDES THE GATE, and that is the whole reason this is safe to have.
## `verdict.sh` carries the floors and `verdict-scan.sh` carries the metric
## extraction, so both are hashed into the key: edit a floor -- which this repo
## does, `allreduce-forcesharp` has moved twice -- and every entry is stale at
## once and the fleet is re-judged. Without that, lowering a floor would leave
## every cached FAIL saying FAIL and nothing anywhere would say why. That is the
## failure this tree is built against, so it is worth saying plainly: a cache
## keyed on the result file alone would be a bug, not an optimisation.
##
## The column list is in the key too, so a `-t`-scoped run cannot replay rows
## for columns the full report wants.
##
## What is deliberately NOT cached:
##
##   * Nodes with a job on them now. RUNNING comes from squeue, which is live
##     state, and their files are being written as we look. Always re-judged.
##   * Anything at all when the results directory cannot be written. The report
##     is still correct, it just says once that it could not save the work.
##
## Validity is per FILE -- name, size and mtime, which is what `make` and rsync
## trust and costs one `find` for the fleet rather than reading 230MB. Replay is
## per NODE: any file added, removed or changed under a node re-judges that whole
## node. That split is on purpose. Per-file validity is what makes the check
## cheap and exact; per-node replay is what keeps the rules about which file
## feeds which cell -- the archive fallback especially -- in one place, in
## _scan_node(), rather than restated in awk where the two could drift apart.

## Records are one per line, first field a type tag:
##
##   #<key>                                     the gate and column set
##   N<FS><node>                                this node was scanned
##   F<FS><node><FS><file><FS><size><FS><mtime> what it was scanned at
##   R<FS><node><FS><col><FS><status><FS><reason><FS><metric>
##
## Flat because it is read by one awk pass and appended to by another. The N
## record is what distinguishes a node scanned and found empty from a node never
## scanned; without it a node with no result files could never be cached.
_scan_cache_file() {
    ## Per mode, because the two reports ask different questions of the same
    ## files: status-check wants the archive fallback and no metrics,
    ## daily-report the reverse. Separate files rather than one they would take
    ## turns invalidating.
    printf '%s/.result_cache.%s%s' \
        "$SCAN_RESULTS_DIR" "${SCAN_ARCHIVES:-0}" "${SCAN_METRICS:-0}"
}

_scan_cache_key() {
    { cat "$PARSERS_DIR/verdict.sh" "$SCAN_LIB" 2>/dev/null
      printf '%s' "$SCAN_COLUMNS"
    } | md5sum | cut -d' ' -f1
}

## scan_fleet <node>...
##
## The cache in front of _scan_fleet_raw. Same rows out, same order guarantee
## (none), so callers cannot tell which nodes were replayed -- that is the
## property the whole thing rests on, and what tests/scan-cache-test.sh checks.
##
## Set SCAN_CACHE=0 to bypass it entirely; both reports expose that as
## --no-cache.
scan_fleet() {
    (( $# )) || return 0

    local cache key tmp new ncols=0 rc=0
    local -a dirty cols

    [[ "${SCAN_CACHE:-1}" == 1 ]] || { _scan_fleet_raw "$@"; return; }

    cache=$(_scan_cache_file)
    ## Not being able to write is not a reason to report nothing, or to report
    ## something different. Say it once and judge the fleet the slow way.
    if ! { : >> "$cache"; } 2>/dev/null; then
        echo "NOTE: cannot write $cache -- judging every node from its files." >&2
        _scan_fleet_raw "$@"
        return
    fi

    tmp=$(mktemp -d) || { _scan_fleet_raw "$@"; return; }
    ## The cache is replaced by rename, so the new copy has to be built beside
    ## it, on the same filesystem. Everything else is scratch and lives in $tmp.
    new="$cache.new.$$"

    read -r -a cols <<< "$SCAN_COLUMNS"
    ncols=${#cols[@]}
    key=$(_scan_cache_key)

    printf '%s\n' "$@" > "$tmp/nodes"
    : > "$tmp/running"
    [[ -n "$SCAN_RUNNING_FILE" && -r "$SCAN_RUNNING_FILE" ]] &&
        cp "$SCAN_RUNNING_FILE" "$tmp/running"

    ## One `find` for the fleet: name, size and mtime of every result file,
    ## archives included, in the same separator everything else here uses.
    find "$SCAN_RESULTS_DIR" -mindepth 2 -maxdepth 2 -name '*.txt' \
        -printf '%P\037%s\037%T@\n' 2>/dev/null > "$tmp/sweep"

    ## The join. Reads cache, sweep and running state, then walks the requested
    ## nodes: clean ones have their rows replayed to stdout and their records
    ## carried forward, dirty ones are listed for the scan.
    awk -v FS="$SCAN_FS" -v OFS="$SCAN_FS" \
        -v key="$key" -v cachef="$cache" -v sweepf="$tmp/sweep" \
        -v runf="$tmp/running" -v dirtyf="$tmp/dirty" -v keepf="$tmp/keep" '
        FILENAME == cachef {
            if (stale) next
            if (substr($0, 1, 1) == "#") {
                ## One mismatch and the whole file is ignored: the gate moved,
                ## so nothing judged under the old one can be replayed.
                if (substr($0, 2) != key) stale = 1
                next
            }
            keep[$2] = keep[$2] $0 "\n"
            if ($1 == "N") cached[$2] = 1
            else if ($1 == "F") { was[$2 FS $3] = $4 FS $5; nwas[$2]++ }
            else if ($1 == "R") rows[$2] = rows[$2] $2 OFS $3 OFS $4 OFS $5 OFS $6 "\n"
            next
        }
        FILENAME == sweepf {
            i = index($1, "/")
            node = substr($1, 1, i - 1); file = substr($1, i + 1)
            nnow[node]++
            if (was[node FS file] != $2 FS $3) changed[node] = 1
            next
        }
        FILENAME == runf { if ($0 != "") live[$0] = 1; next }
        {
            node = $0
            ## Any one of these and the node is judged from its files again.
            ## Counts included, so a file that was DELETED is caught -- the
            ## per-file check only ever sees what is there now.
            if (stale || !(node in cached) || node in live ||
                node in changed || (nnow[node] + 0) != (nwas[node] + 0)) {
                print node > dirtyf
                next
            }
            printf "%s", rows[node]
            printf "%s", keep[node] > keepf
        }
    ' "$cache" "$tmp/sweep" "$tmp/running" "$tmp/nodes"

    ## Always present, even when nothing is dirty: it is an input to the awk
    ## below, and awk treats a missing input file as an error.
    [[ -f "$tmp/dirty" ]] || : > "$tmp/dirty"
    [[ -f "$tmp/keep" ]]  || : > "$tmp/keep"
    mapfile -t dirty < "$tmp/dirty"

    if (( ${#dirty[@]} )); then
        ## tee, not a second scan: the rows go to the caller and to the file the
        ## new cache records are built from, so the cache can never hold an
        ## answer the report did not print.
        _scan_fleet_raw "${dirty[@]}" | tee "$tmp/fresh"
        rc=${PIPESTATUS[0]}
    else
        : > "$tmp/fresh"
    fi

    ## The new cache: what survived, plus the nodes just judged. Written beside
    ## the old one and renamed, so a reader either sees the whole previous cache
    ## or the whole new one, and two reports running at once cannot interleave.
    {
        printf '#%s\n' "$key"
        cat "$tmp/keep"
        awk -v FS="$SCAN_FS" -v OFS="$SCAN_FS" -v ncols="$ncols" \
            -v sweepf="$tmp/sweep" -v dirtyf="$tmp/dirty" -v runf="$tmp/running" '
            FILENAME == dirtyf { want[$0] = 1; next }
            FILENAME == runf   { if ($0 != "") live[$0] = 1; next }
            FILENAME == sweepf {
                i = index($1, "/")
                node = substr($1, 1, i - 1)
                if (node in want) { files[node] = files[node] "F" OFS node OFS substr($1, i + 1) OFS $2 OFS $3 "\n" }
                next
            }
            { rows[$1] = rows[$1] "R" OFS $0 "\n"; n[$1]++ }
            END {
                for (node in want) {
                    ## A node with a job on it is not written down at all. Its
                    ## RUNNING came from squeue, and squeue will say something
                    ## else once the job ends -- with no file changing, so
                    ## nothing would ever invalidate it. Reading it back after
                    ## the job finished would report a dead job as live.
                    if (node in live) continue
                    ## And a node is recorded only if every one of its columns
                    ## came back. A worker that died leaves a short node, and
                    ## caching that would make the gap permanent; left out, it
                    ## is simply judged again next time.
                    if ((n[node] + 0) != ncols + 0) continue
                    printf "N%s%s\n", OFS, node
                    printf "%s", files[node]
                    printf "%s", rows[node]
                }
            }
        ' "$tmp/dirty" "$tmp/running" "$tmp/sweep" "$tmp/fresh"
    } > "$new" && mv -f "$new" "$cache"

    rm -rf "$tmp" "$new"
    return "$rc"
}

## ── Sourced, or run as the worker ─────────────────────────────────────────
## $0 is this file only when xargs ran it; when a reporting script sourced it,
## $0 is the reporting script. SCAN_LIB is resolved here, once, because that is
## the path scan_fleet has to hand to xargs.

SCAN_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/${BASH_SOURCE[0]##*/}"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    ## A worker is a fresh process: nothing the caller sourced is in scope, so
    ## it loads its own settings and its own copy of the gate.
    home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=/dev/null
    source "$home/settings.sh"
    if [[ ! -f "$PARSERS_DIR/verdict.sh" ]]; then
        echo "ERROR: $PARSERS_DIR/verdict.sh is missing -- nothing can be judged." >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$PARSERS_DIR/verdict.sh"
    scan_worker "$@"
fi
