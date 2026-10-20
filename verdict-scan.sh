#!/bin/bash
#
# Judges every (node, column) cell of the fleet in parallel and writes one row
# per cell: <node><FS><column><FS><status><FS><reason><FS><metric>.
#
# Sourced by report_job-status.sh and report_benchmarks.sh for scan_fleet(), and run by
# its own xargs as the worker. See
# docs/explanation/verdicts-and-the-cache.md#how-a-report-is-produced.

## Not a tab: `read` collapses runs of IFS whitespace and eats empty fields.
## Split on this, never on a tab. See
## docs/explanation/verdicts-and-the-cache.md#how-a-report-is-produced.
SCAN_FS=$'\037'

## ── Metric extraction ─────────────────────────────────────────────────────
## One numeric value, or empty, for a completed result file. The allreduce and
## alltoall case must stay identical to verdict.sh's _v_min_peak_bw, or the
## report prints a number the gate did not judge -- change one, change the other.

extract_metric() {
    local job="$1" file="$2"
    case "$job" in
        hpl)
            # WC summary line: T/V N NB P Q Time Gflops (per_GPU)
            awk '/^WC/ { print $7; exit }' "$file" 2>/dev/null
            ;;
        allreduce|alltoall|allreduce-nonvlink|alltoall-nonvlink|allreduce-forcesharp|*-pytorch)
            # Out-of-place busbw at the largest size run, so the column reads
            # against VERDICT_MIN_PEAK_BW_* directly. Max tracked in the pass:
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
            # Highest aggregate bandwidth across the four passes. `sort -h`
            # because these carry K/M/G suffixes, which awk cannot order.
            grep -oE 'bw=[0-9.]+[KMG]?i?B/s' "$file" 2>/dev/null | sed 's/bw=//' | sort -h | tail -1
            ;;
        llm-pretrain|llm-pretrain-solo|deepseek-v3-proxy)
            # Median step time in ms, from the gate's own helper rather than a
            # second copy of it, so the column reads against
            # VERDICT_MAX_STEP_MS_LLM_* directly.
            _v_llm_step_ms "$file" | cut -d' ' -f1
            ;;
    esac
}

metric_label() {
    case "$1" in
        hpl)                echo "gflops"      ;;
        allreduce|alltoall|allreduce-nonvlink|alltoall-nonvlink|allreduce-forcesharp|*-pytorch)
                            echo "busbw_GBs"   ;;
        nvbandwidth)        echo "min_GBs"     ;;
        stream)             echo "triad_MBs"   ;;
        fio)                echo "bw"          ;;
        llm-pretrain|llm-pretrain-solo|deepseek-v3-proxy)
                            echo "step_ms"     ;;
    esac
}

## ── Burn-in ────────────────────────────────────────────────────────────────
## Trimmed copies of actions/launch_job.sh's job_launcher/job_total_runs/
## job_run_seconds -- the report side of the same read-by-grep-never-source
## rule (docs/explanation/sequencing.md#nothing-is-read-by-sourcing-it), kept
## here rather than sourced from launch_job.sh because that file pulls in the
## submission machinery this report side has no business running.

_scan_job_launcher() {
    local job="$1"
    [[ -f "$JOBS_DIR/$job.sbatch" ]] && { printf '%s' "$JOBS_DIR/$job.sbatch"; return 0; }
    [[ -f "$JOBS_DIR/$job.sh" ]] &&
        grep -qE '^[[:space:]]*job_launch=host[[:space:]]*$' "$JOBS_DIR/$job.sh" && {
            printf '%s' "$JOBS_DIR/$job.sh"; return 0; }
    return 1
}

_scan_job_total_runs() {
    local launch="$1" total=1
    if grep -Fq "totalRuns" "$launch"; then
        total=$(grep -F totalRuns "$launch" | head -1 | awk -F= '{print $2}' | tr -d '[:space:]')
    fi
    [[ "$total" =~ ^[0-9]+$ ]] && [[ "$total" -gt 0 ]] || total=1
    printf '%s' "$total"
}

_scan_job_run_seconds() {
    local launch="$1" secs h m s
    if grep -Fq -- "--time_to_run" "$launch"; then
        secs=$(grep -F -- "--time_to_run" "$launch" | head -1 | awk '{print $2}' | tr -d '[:space:]')
        [[ "$secs" =~ ^[0-9]+$ ]] && { printf '%s' "$secs"; return; }
    fi
    IFS=: read -r h m s < <(grep -F "STEP_TIMELIMIT=" "$launch" | head -1 | awk -F= '{print $2}')
    [[ "$h" =~ ^[0-9]+$ ]] || h=0
    [[ "$m" =~ ^[0-9]+$ ]] || m=0
    [[ "$s" =~ ^[0-9]+$ ]] || s=0
    printf '%s' $(( 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

## "<N>H/<BURNIN_HOURS>H" for one node -- validated hours summed across every
## job in BURNIN, never DONE on its own: the campaign target is additive
## information, not a verdict. Bypasses the scan cache entirely (not called
## through scan_fleet/_scan_node) -- correctly, since the value depends on
## BURNIN_HOURS too, not just one result file and one gate.
## See docs/explanation/burn-in-waveform.md.
burnin_hours_cell() {
    local node="$1" job launch total secs r file hours=0
    for job in $BURNIN; do
        launch=$(_scan_job_launcher "$job") || continue
        total=$(_scan_job_total_runs "$launch")
        secs=$(_scan_job_run_seconds "$launch")
        for ((r = 1; r <= total; r++)); do
            if [[ "$total" -eq 1 ]]; then
                file="$SCAN_RESULTS_DIR/$node/$job.txt"
            else
                file="$SCAN_RESULTS_DIR/$node/$job-run${r}.txt"
            fi
            [[ -f "$file" ]] || continue
            verdict "$job" "$file"
            [[ "$VERDICT_STATUS" == "DONE" ]] && hours=$(( hours + secs / 3600 ))
        done
    done
    printf '%sH/%sH' "$hours" "${BURNIN_HOURS:-0}"
}

## ── Per-node scan ─────────────────────────────────────────────────────────

# Newest <col>.<kind><N>.txt, into _SCAN_ARCHIVE. By numeric suffix, not mtime:
# an rsync or restore reorders mtimes. A glob, not `ls | sed | sort | tail`,
# because this fires twice per NOT_RUN cell.
# See docs/explanation/sequencing.md for what writes .failN and .prevN.
_scan_last_archive() {
    local node="$1" col="$2" kind="$3" f n best=-1
    _SCAN_ARCHIVE=""
    for f in "$SCAN_RESULTS_DIR/$node/${col}.${kind}"[0-9]*.txt; do
        ## An unmatched glob is left literal: this is the "no archives" case.
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

# The column a running batch is writing, into _SCAN_LIVE. squeue knows the node
# but not the benchmark; the newest current result file does. Three processes on
# purpose -- only RUNNING nodes reach here.
#
# Matched against _SCAN_RESULT_RE rather than "every .txt that is not an
# archive": the node directory also holds quick-view.txt, which is not a result.
# See docs/reference/scripts.md.
_scan_live_column() {
    local node="$1" f
    _SCAN_LIVE=""
    [[ -n "$_SCAN_RESULT_RE" ]] || return
    ## `ls -t` is the point: a glob expands in collating order. Every name the
    ## regex admits is a job name plus a fixed suffix, so the odd filenames
    ## SC2010 guards against cannot survive it.
    # shellcheck disable=SC2010
    f=$(ls -t "$SCAN_RESULTS_DIR/$node"/*.txt 2>/dev/null \
        | grep -E "$_SCAN_RESULT_RE" | head -1)
    [[ -n "$f" ]] || return
    f="${f##*/}"
    _SCAN_LIVE="${f%.txt}"
}

## One node, every column, one row per cell on stdout. Each row is ONE printf:
## workers share this stdout and only a single write under PIPE_BUF is atomic.
## See docs/explanation/verdicts-and-the-cache.md#how-a-report-is-produced.
_scan_node() {
    local node="$1" col job file judged status reason metric i

    _SCAN_LIVE=""
    [[ -n "${_SCAN_RUNNING[$node]:-}" ]] && _scan_live_column "$node"

    for ((i = 0; i < ${#_SCAN_COLS[@]}; i++)); do
        col="${_SCAN_COLS[i]}"
        job="${_SCAN_COL_JOB[i]}"
        file="$SCAN_RESULTS_DIR/$node/${col}.txt"
        judged="$file"

        # Not $(verdict ...) -- a subshell would lose the reason. See verdict().
        verdict "$job" "$file"
        status="$VERDICT_STATUS"
        reason="$VERDICT_REASON"

        if [[ "$SCAN_ARCHIVES" == 1 && "$status" == "NOT_RUN" ]]; then
            ## A column between two attempts has no current file, and which
            ## archive fills the gap is the whole verdict: .failN is a rejection
            ## and reads as one, .prevN is a pass --all asked for again.
            ## See docs/explanation/verdicts-and-the-cache.md#a-column-between-two-attempts.
            if _scan_last_archive "$node" "$col" fail; then
                verdict "$job" "$_SCAN_ARCHIVE"
                judged="$_SCAN_ARCHIVE"
                status=FAIL
                reason="$VERDICT_REASON; a re-run is queued"
                ## Not a contradiction: the gate has been loosened since the
                ## archive was rejected, so there is no failure left to report.
                if [[ "$VERDICT_STATUS" == "DONE" ]]; then
                    status=RERUNNING
                    reason="prior attempt passes the current gate"
                fi
            elif _scan_last_archive "$node" "$col" prev; then
                verdict "$job" "$_SCAN_ARCHIVE"
                judged="$_SCAN_ARCHIVE"
                status=RERUNNING
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
        ## and its largest message size is whichever one it reached. $judged and
        ## not $file: a FAIL from the gap above has no current file to measure.
        metric=""
        if [[ "$SCAN_METRICS" == 1 && ( "$status" == "DONE" || "$status" == "FAIL" ) ]]; then
            metric=$(extract_metric "$job" "$judged")
        fi

        printf '%s%s%s%s%s%s%s%s%s\n' \
            "$node" "$SCAN_FS" "$col" "$SCAN_FS" "$status" \
            "$SCAN_FS" "$reason" "$SCAN_FS" "$metric"
    done
}

## ── Worker ────────────────────────────────────────────────────────────────

## Configured through the environment; only the node names are arguments, so
## xargs can chunk them. The running list is a file, not a variable -- on a
## large fleet every worker would carry thousands of names through exec.
scan_worker() {
    local n
    declare -gA _SCAN_RUNNING=()
    if [[ -n "$SCAN_RUNNING_FILE" && -r "$SCAN_RUNNING_FILE" ]]; then
        while IFS= read -r n; do
            [[ -n "$n" ]] && _SCAN_RUNNING["$n"]=1
        done < "$SCAN_RUNNING_FILE"
    fi

    ## Hoisted: the column -> job mapping is the same for every node, and cost
    ## a subshell per cell for an answer that never changes.
    read -r -a _SCAN_COLS <<< "$SCAN_COLUMNS"
    _SCAN_COL_JOB=()
    for n in "${_SCAN_COLS[@]}"; do
        _SCAN_COL_JOB+=("$(verdict_job_name "$n")")
    done

    ## What a result file is allowed to be named, for _scan_live_column. Built
    ## from both lists and not from SCAN_COLUMNS: -t narrows the report, never
    ## what the node is running, and the newest file among a SUBSET of the
    ## columns is not the live one. Archives fail it by construction.
    ## See docs/reference/scripts.md.
    local alt=""
    # shellcheck disable=SC2086  # both lists are space separated job names
    for n in $BENCHMARKS $BURNIN; do
        alt+="${alt:+|}$n"
    done
    _SCAN_RESULT_RE=""
    [[ -n "$alt" ]] && _SCAN_RESULT_RE="/($alt)(-run[0-9]+)?\.txt\$"

    for n in "$@"; do
        _scan_node "$n"
    done
}

## ── Parallel fan-out ──────────────────────────────────────────────────────

## _scan_fleet_raw <node>... -- judge every node given, unconditionally.
##
## Rows in no particular order; callers sort. Runs in children, so it cannot
## build state in the caller's shell. Worker stderr is deliberately not
## redirected -- a silent scan reports a clean cluster.
## See docs/explanation/verdicts-and-the-cache.md#how-a-report-is-produced.
_scan_fleet_raw() {
    local n_nodes=$# jobs chunk

    (( n_nodes )) || return 0

    jobs="${SCAN_JOBS:-0}"
    if [[ ! "$jobs" =~ ^[0-9]+$ ]] || (( jobs < 1 )); then
        jobs=$(nproc 2>/dev/null) || jobs=4
    fi

    ## ~4 chunks per worker: enough to even out a slow node, few enough that
    ## the bash startup and re-source of verdict.sh per chunk stays amortised.
    chunk=$(( (n_nodes + jobs * 4 - 1) / (jobs * 4) ))
    (( chunk < 1 )) && chunk=1

    ## -d so node names bypass xargs' quote handling; -r so an empty list runs
    ## nothing rather than one worker with no arguments.
    printf '%s\n' "$@" \
        | xargs -r -d '\n' -n "$chunk" -P "$jobs" bash "$SCAN_LIB"
}

## ── Cache ─────────────────────────────────────────────────────────────────
##
## A judgement is a pure function of the result file and the gate, so a node
## whose files have not moved cannot have a different answer. The key covers
## BOTH -- edit a floor and the whole fleet is re-judged. Anything added to a
## verdict that is not such a pure function must not be cached.
##
## Read docs/explanation/verdicts-and-the-cache.md#the-verdict-cache before changing any of this.

## One record per line, first field a type tag:
##
##   #<key>                                     the gate and column set
##   N<FS><node>                                this node was scanned
##   F<FS><node><FS><file><FS><size><FS><mtime> what it was scanned at
##   R<FS><node><FS><col><FS><status><FS><reason><FS><metric>
##
## N is what tells a node scanned and found empty from one never scanned.
_scan_cache_file() {
    ## Per mode: the two reports ask different questions of the same files and
    ## would otherwise take turns invalidating one file.
    printf '%s/.result_cache.%s%s' \
        "$SCAN_RESULTS_DIR" "${SCAN_ARCHIVES:-0}" "${SCAN_METRICS:-0}"
}

## The floors are named rather than catted: they live in SETTINGS.
## See docs/reference/settings.md#benchmark-pass-floors.
_scan_cache_key() {
    local v
    { cat "$PARSERS_DIR/verdict.sh" "$SCAN_LIB" 2>/dev/null
      for v in "${!VERDICT_MIN_PEAK_BW_@}" "${!VERDICT_MAX_STEP_MS_@}"; do printf '%s=%s\n' "$v" "${!v}"; done
      printf '%s' "$SCAN_COLUMNS"
    } | md5sum | cut -d' ' -f1
}

## scan_fleet <node>... -- the cache in front of _scan_fleet_raw.
##
## Same rows out, so callers cannot tell which nodes were replayed. That is the
## property everything rests on; tests/scan-cache-test.sh is what holds it.
## SCAN_CACHE=0 bypasses it, exposed by both reports as --no-cache.
scan_fleet() {
    (( $# )) || return 0

    local cache key tmp new ncols=0 rc=0
    local -a dirty cols

    [[ "${SCAN_CACHE:-1}" == 1 ]] || { _scan_fleet_raw "$@"; return; }

    cache=$(_scan_cache_file)
    ## Unwritable is not a reason to report nothing. Say so once, judge it all.
    if ! { : >> "$cache"; } 2>/dev/null; then
        echo "NOTE: cannot write $cache -- judging every node from its files." >&2
        _scan_fleet_raw "$@"
        return
    fi

    tmp=$(mktemp -d) || { _scan_fleet_raw "$@"; return; }
    ## Replaced by rename, so the new copy must be built on the same filesystem.
    new="$cache.new.$$"

    read -r -a cols <<< "$SCAN_COLUMNS"
    ncols=${#cols[@]}
    key=$(_scan_cache_key)

    printf '%s\n' "$@" > "$tmp/nodes"
    : > "$tmp/running"
    [[ -n "$SCAN_RUNNING_FILE" && -r "$SCAN_RUNNING_FILE" ]] &&
        cp "$SCAN_RUNNING_FILE" "$tmp/running"

    ## One `find` for the fleet: name, size and mtime of every result file.
    find "$SCAN_RESULTS_DIR" -mindepth 2 -maxdepth 2 -name '*.txt' \
        -printf '%P\037%s\037%T@\n' 2>/dev/null > "$tmp/sweep"

    ## The join: clean nodes are replayed to stdout, dirty ones listed to scan.
    awk -v FS="$SCAN_FS" -v OFS="$SCAN_FS" \
        -v key="$key" -v cachef="$cache" -v sweepf="$tmp/sweep" \
        -v runf="$tmp/running" -v dirtyf="$tmp/dirty" -v keepf="$tmp/keep" '
        FILENAME == cachef {
            if (stale) next
            ## A key mismatch voids the file: the gate moved, so nothing
            ## judged under the old one can be replayed.
            if (substr($0, 1, 1) == "#") { if (substr($0, 2) != key) stale = 1; next }
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
            ## Counts included, so a DELETED file is caught: the per-file check
            ## only ever sees what is there now.
            if (stale || !(node in cached) || node in live ||
                node in changed || (nnow[node] + 0) != (nwas[node] + 0)) {
                print node > dirtyf
                next
            }
            printf "%s", rows[node]
            printf "%s", keep[node] > keepf
        }
    ' "$cache" "$tmp/sweep" "$tmp/running" "$tmp/nodes"

    ## Always present: awk treats a missing input file as an error.
    [[ -f "$tmp/dirty" ]] || : > "$tmp/dirty"
    [[ -f "$tmp/keep" ]]  || : > "$tmp/keep"
    mapfile -t dirty < "$tmp/dirty"

    if (( ${#dirty[@]} )); then
        ## tee, not a second scan, so the cache cannot hold an answer the
        ## report did not print.
        _scan_fleet_raw "${dirty[@]}" | tee "$tmp/fresh"
        rc=${PIPESTATUS[0]}
    else
        : > "$tmp/fresh"
    fi

    ## What survived plus what was just judged, renamed into place so a reader
    ## sees one whole cache or the other and two reports cannot interleave.
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
                    ## Never write down a running node: nothing on disk would
                    ## invalidate its RUNNING once the job ends.
                    if (node in live) continue
                    ## Short node = a worker died. Recording it would make the
                    ## gap permanent; left out, it is judged again next time.
                    if ((n[node] + 0) != ncols + 0) continue
                    printf "N%s%s\n", OFS, node
                    printf "%s", files[node]
                    printf "%s", rows[node]
                }
            }
        ' "$tmp/dirty" "$tmp/running" "$tmp/sweep" "$tmp/fresh"
    } > "$new" &&
        ## Group-writable regardless of the writer's umask. See
        ## docs/explanation/verdicts-and-the-cache.md#a-shared-cache-file.
        chmod 664 "$new" 2>/dev/null && mv -f "$new" "$cache"

    rm -rf "$tmp" "$new"
    return "$rc"
}

## ── Sourced, or run as the worker ─────────────────────────────────────────
## $0 is this file only when xargs ran it. SCAN_LIB is resolved once here
## because that is the path _scan_fleet_raw hands to xargs.

SCAN_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/${BASH_SOURCE[0]##*/}"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    ## A fresh process: nothing the caller sourced is in scope.
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
