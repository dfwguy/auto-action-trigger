#!/bin/bash
#
#

#[[ "$CMD_CATEGORY" == "spcx-hosts" ]] || exit 0

## ── Settings ──────────────────────────────────────────────────────────────
##
## Everything configurable lives in SETTINGS (or SETTINGS.default when a site
## has not made one). BCM invokes this script by absolute path with no working
## directory to infer from, so the checkout is located the same way it always
## was -- by the hardcoded path below -- and the settings are read from there.
##
## This gives us: BENCHMARKS, BURNIN, RUN_BURNIN, JOBS_DIR, PARSERS_DIR,
## JOB_USER, MAX_JOB_HOURS, RETRY_INTERVAL_HOURS, DRAIN_WINDOW_MINUTES,
## DRAIN_MARKER, PAUSE_JOBS, and DRAIN_AFTER_FAILED_BENCHMARK.
##
## A missing settings.sh is fatal rather than defaulted. Without it BENCHMARKS
## is empty, the sweep finds nothing pending on every node, and the whole
## cluster reads as "every benchmark passing" -- a silent stop, which is the
## one failure mode the tracing below exists to prevent.
home=/home/cmods/bringup
if [[ ! -f "$home/settings.sh" ]]; then
    echo "ERROR: $home/settings.sh is missing -- refusing to run, because an" >&2
    echo "       empty benchmark list reads as 'everything passing' on every node." >&2
    exit 1
fi
source "$home/settings.sh"

## Retry policy.
##
## Once an hour, every benchmark in BENCHMARKS that does not have a passing
## result is queued, in listed order. Slurm runs them back to back on the node.
## There is no retry limit -- a node keeps being re-tested until it passes or an
## operator intervenes.
##
## Two lists, both surveyed every cycle. BENCHMARKS always runs; BURNIN runs
## when RUN_BURNIN is on. They are separate lists rather than one longer
## BENCHMARKS because they answer different questions on different timescales
## -- "does this node work", in minutes, and "does it keep working", in days --
## and because the queue has to be able to tell them apart.
##
## What orders them is Slurm priority, not a gate, and each job states its own
## in `#SBATCH --nice`: 0 for the dcgm gates, 20 for the rest of the sweep,
## 100000 for mnubergemm -- large enough that a burn-in is always behind any
## benchmark in the queue. Burn-in was gated behind a clean sweep before, which
## made the ordering absolute at the cost of making it rigid: a node failing
## one benchmark could never start burning in, and a node three days into a
## burn-in could not pick up a benchmark retry until it finished.
##
## The limit of doing it with priority is that priority does not preempt.
## Everything here is --exclusive, so a burn-in run that has already started
## holds the node until it ends -- up to MAX_JOB_HOURS. A benchmark submitted
## behind it goes ahead of the remaining burn-in runs, not ahead of the one on
## the node. On the shipped list that is a wait of one ~6h run rather than of
## twelve. A site that needs a benchmark to interrupt a running burn-in needs
## Slurm preemption (PreemptType/PreemptMode with the two lists in different
## partitions or QOSes), which is a scheduler configuration and not something
## this script can arrange.
##
## This script fires on every BCM monitoring cycle, so the hourly cadence needs
## no cron and no second trigger -- just a time gate. Retry state is derived
## entirely from files already on disk: the newest result file's mtime is when
## the last sweep ran, and prior failures are archived as <job>.fail<N>.txt.
## There is no state file to keep in sync.
##
## The node is drained only once a full sweep has been attempted -- every
## benchmark has run at least once and something is still not passing. A single
## failure mid-sweep does not drain, so the rest of the sweep still runs and one
## bad test does not hide the state of the others.
##
## The drain reason carries a marker, and only drains carrying that marker are
## ever cleared. An operator drain is never auto-resumed, and a node already
## drained for another reason is left alone.
## A drain only fires on failures that just happened -- results newer than
## DRAIN_WINDOW_MINUTES. Without that window the script would re-drain from
## stale result files on every cycle, so a node an operator had resumed would
## be pulled straight back out of service. Failures only take the node down
## again once a fresh retry sweep has failed again.
##
## Keep DRAIN_WINDOW_MINUTES above the BCM monitoring interval, or the drain is
## missed entirely, and well below RETRY_INTERVAL_HOURS. Both, along with
## MAX_JOB_HOURS and DRAIN_MARKER, are set in SETTINGS.

## set paths
logs="$home/results/$HOSTNAME"
quickview="$logs/quick-view.txt"
tracelog="$logs/trigger.log"

## Slurm job names, one per list. Both are per-node because every queue query
## below is per-node, and they are distinct from each other because the two
## lists are queued at the same time and have to be counted, cancelled and
## reasoned about separately. Anything matching neither is somebody else's job.
JOB_NAME_BENCH="bringup-$HOSTNAME"
JOB_NAME_BURNIN="burnin-$HOSTNAME"

## ── Tracing ───────────────────────────────────────────────────────────────
##
## Every gate below can end the run with a plain `exit 0`, which is correct --
## the trigger re-fires on every monitoring cycle and most cycles have nothing
## to do. But it also means a node that has silently stopped testing looks
## exactly like a node that is quietly idle: no output, no exit code, nothing
## in a log. Each decision is therefore recorded, so "nothing is running"
## always has a written reason next to it.
##
## `launch_job.sh --explain` mirrors the trace to stdout and makes the run a
## dry run: state is read, but no sbatch, drain, or resume is issued and no
## result file is archived. Safe to run by hand on a node while the trigger is
## live -- it cannot queue a duplicate job or move a result out from under one.
EXPLAIN=0
case "$1" in
    --explain|-n|--dry-run) EXPLAIN=1 ;;
esac

mkdir -p "$logs"

## The append is allowed to fail silently: running --explain by hand as an
## unprivileged user should still print its trace, not die on the log file.
trace() {
    printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$tracelog" 2>/dev/null
    [[ "$EXPLAIN" -eq 1 ]] && printf '%s\n' "$*"
    return 0
}

## Keep the trace from growing without bound -- it gets a line or two per
## monitoring cycle, forever.
if [[ -f "$tracelog" ]] && [[ "$(stat -c %s "$tracelog" 2>/dev/null || echo 0)" -gt 1000000 ]]; then
    tail -2000 "$tracelog" > "$tracelog.tmp" && mv "$tracelog.tmp" "$tracelog"
fi

## ── Hand the result path to $JOB_USER ─────────────────────────────────────
##
## BCM runs this script as root, but the benchmarks are submitted with
## `su - $JOB_USER` and sbatch writes its --output as that user. So when root
## is the one that creates results/ or results/<node>, they land root-owned at
## mode 755 and $JOB_USER cannot create a file inside. sbatch still returns a
## job id and slurm still schedules the job -- it dies at startup with nowhere
## to write its output. The node goes back to idle with no result file, no
## FAIL, and no archive: identical, from every angle, to never having run.
##
## This is not hypothetical. Clearing results/ by hand is a normal thing to do
## between bringup passes, and the very next monitoring cycle has root recreate
## the tree. So rather than only getting ownership right on creation, fix it on
## every cycle: `mv results results.old` or `rm -rf results` is then a safe
## operation, and any tree already broken repairs itself without intervention.
ensure_owned() {
    local d="$1"
    [[ -d "$d" ]] || mkdir -p "$d" 2>/dev/null || return 1
    [[ "$(stat -c %U "$d" 2>/dev/null)" == "$JOB_USER" ]] && return 0
    ## Only root can hand a directory over. Running by hand as an unprivileged
    ## user, this is a diagnosis rather than something we can act on.
    if [[ "$EUID" -ne 0 ]]; then
        trace "WARNING: $d is owned by $(stat -c %U "$d" 2>/dev/null), not $JOB_USER, and we are not root -- sbatch --output will fail"
        return 0
    fi
    trace "chown $JOB_USER $d (was $(stat -c %U "$d" 2>/dev/null))"
    chown "$JOB_USER:$JOB_USER" "$d" 2>/dev/null
}

ensure_owned "$home/results"
ensure_owned "$logs"

source /etc/profile.d/modules.sh
module load slurm

## The trigger runs this with BCM's environment, not a login shell. If the
## slurm module did not give us the client tools, every downstream check reads
## as "node not in slurm" and the script exits looking perfectly healthy.
for tool in sinfo squeue scontrol sbatch; do
    command -v "$tool" >/dev/null 2>&1 || {
        trace "EXIT: $tool not on PATH after 'module load slurm' (PATH=$PATH)"
        exit 0
    }
done

## ── Pause ─────────────────────────────────────────────────────────────────
##
## PAUSE_JOBS=yes stops the sequencer here: nothing is submitted, nothing is
## drained, nothing is resumed, and no result is archived. Results already on
## disk are left exactly as they are, so unpausing resumes the sweep rather
## than restarting it.
##
## Pausing has to reach the queue as well, or it is not a pause. The trigger
## fires every monitoring cycle but the batch it already submitted sits in
## Slurm for hours, so gating submission alone leaves the cluster running
## benchmarks for the rest of the sweep. Two populations, handled differently:
##
##   PENDING -- cancelled. A pending job has produced nothing, and the next
##              unpaused sweep queues it again from the same survey, so this
##              costs a queue slot and no results.
##   RUNNING -- left to finish. It holds the node exclusively and has been
##              writing to its result file for some time; killing it turns
##              hours of burn-in into a truncated log that the gate reads as
##              INCOMPLETE, which is indistinguishable from a node that
##              crashed mid-benchmark. The id is traced so an operator who
##              wants the node back now can scancel it deliberately.
##
## Only jobs carrying one of our two names are ever cancelled -- the same name
## queries the queue check below uses, and both of them, so a pause stops the
## burn-in as well as the sweep. Somebody else's job on this node is not ours
## to stop, and a pause is not a reason to touch it.
if setting_enabled "$PAUSE_JOBS"; then
    paused_queue=$( { squeue -h -n "$JOB_NAME_BENCH"  -o '%i %T %M' 2>/dev/null
                      squeue -h -n "$JOB_NAME_BURNIN" -o '%i %T %M' 2>/dev/null
                    } | grep -v '^$' )
    pending_ids=$(awk '$2 == "PENDING" { print $1 }' <<<"$paused_queue" | tr '\n' ' ')
    pending_ids="${pending_ids% }"

    if [[ -n "$pending_ids" ]]; then
        if [[ "$EXPLAIN" -eq 1 ]]; then
            trace "WOULD CANCEL pending: $pending_ids"
        elif ! command -v scancel >/dev/null 2>&1; then
            trace "WARNING: PAUSE_JOBS=yes but scancel is not on PATH -- pending jobs left queued: $pending_ids"
        else
            out=$(scancel $pending_ids 2>&1)
            trace "PAUSE_JOBS: cancelled pending $pending_ids${out:+ -- $out}"
        fi
    fi

    while read -r id state elapsed; do
        [[ "$state" == "RUNNING" ]] || continue
        trace "PAUSE_JOBS: job $id still RUNNING for $elapsed -- left to finish; 'scancel $id' to stop it now"
    done <<<"$paused_queue"

    trace "EXIT: PAUSE_JOBS=$PAUSE_JOBS in ${SETTINGS_FILE:-<no settings file found>} -- no submissions, no drains, no resumes"
    exit 0
fi

## Result file for run $2 of job $1. Single-run jobs use <job>.txt.
result_file() {
    local job="$1" run="$2" total="$3"
    if [[ "$total" -eq 1 ]]; then
        echo "$logs/$job.txt"
    else
        echo "$logs/$job-run${run}.txt"
    fi
}

## Move a non-passing result aside as <name>.fail<N>.txt so the slot is free
## for the next attempt. The archives double as the per-job attempt history.
archive_result() {
    local file="$1" base n
    [[ -f "$file" ]] || return 0
    base=$(basename "$file" .txt)
    n=$(ls "$logs" 2>/dev/null | grep -cE "^${base}\.fail[0-9]+\.txt$")
    mv "$file" "$logs/${base}.fail$((n + 1)).txt"
}

## Drain only if the node is currently usable and not already drained by us.
## A node drained for any other reason is left alone.
##
## DRAIN_AFTER_FAILED_BENCHMARK=no in SETTINGS disables every drain this script
## would issue, including the MAX_JOB_HOURS timeout drain. Testing continues
## exactly as before — results are still recorded and failures still retry
## hourly — the node is just never taken out of service. The suppressed drain
## is still traced, so the trigger log answers "what would this have done" for
## a site running with drains off.
drain_node() {
    local reason="$1"
    setting_enabled "$DRAIN_AFTER_FAILED_BENCHMARK" || {
        trace "drain suppressed by DRAIN_AFTER_FAILED_BENCHMARK=$DRAIN_AFTER_FAILED_BENCHMARK: $reason"
        return 0
    }
    case "$state" in
        *drain*|*down*|*fail*|*maint*) trace "drain skipped, already $state: $reason"; return 0 ;;
    esac
    trace "DRAIN: $reason"
    [[ "$EXPLAIN" -eq 1 ]] && return 0
    scontrol update nodename="$HOSTNAME" state=DRAIN reason="$reason"
}

## Clear only our own drain — the marker is what makes this safe.
resume_node() {
    local current
    current=$(sinfo -n "$HOSTNAME" -h -o '%E' 2>/dev/null | head -1)
    [[ "$current" == *"$DRAIN_MARKER"* ]] || return 0
    trace "RESUME: clearing own drain ($current)"
    [[ "$EXPLAIN" -eq 1 ]] && return 0
    scontrol update nodename="$HOSTNAME" state=RESUME
}

## Check if node is in slurm; if not - quit
state=$(sinfo -N -n "$HOSTNAME" -h -o '%T')
if [[ -z "$state" ]]; then
    trace "EXIT: $HOSTNAME not known to slurm (sinfo -N -n returned nothing)"
    exit 0
fi
trace "state=$(printf '%s' "$state" | tr '\n' ',') explain=$EXPLAIN"

## If a job of ours is anywhere in the queue for this node -- running or still
## pending -- wait. The queue is asked two ways, and both are load-bearing.
##
## `-w $HOSTNAME` matches on the node a job is *assigned* to, and the scheduler
## only assigns one once the job is about to run. Our batch is submitted with
## `-w` as a constraint, not an assignment, so while the node is down or
## drained the entire queued batch is invisible to that query. The sweep then
## saw an idle node with no passing results and submitted the whole list again,
## every hour, with nothing ever draining the pile: nine nodes reached ~35
## queued jobs each before anyone noticed.
##
## `-n <name>` matches on the job names every submission below carries, so our
## batch is visible from the moment sbatch returns, wherever the scheduler has
## or has not placed it. That is the query that closes the requeue loop. The
## node query stays, because it catches the one thing the name queries cannot:
## somebody else's job occupying the node, which is still a reason not to pile
## benchmarks on top of it.
##
## The two lists carry different names -- bringup-<node> and burnin-<node> --
## and that is what lets them be queued at the same time. "Is anything of ours
## out there" was one question when there was one list; with two it has to be
## asked per list, or a burn-in sitting in the queue for three days would block
## every benchmark retry behind it and the jobs' nice values would never get a
## chance to matter. The names are also worth having in `squeue` on their own:
## an operator can see which of the two a node is doing, and stop just the
## burn-in with `scancel -n burnin-<node>`.
mine_bench=$(squeue -h -n "$JOB_NAME_BENCH"  -o '%i %T %M' 2>/dev/null)
mine_burnin=$(squeue -h -n "$JOB_NAME_BURNIN" -o '%i %T %M' 2>/dev/null)
mine="$(printf '%s\n%s\n' "$mine_bench" "$mine_burnin" | grep -v '^$')"

## Anything on the node that is not ours. Matched by name, because the node
## query returns our own jobs too once the scheduler has placed one.
foreign=$(squeue -h -w "$HOSTNAME" -o '%i %T %M %j' 2>/dev/null |
          awk -v a="$JOB_NAME_BENCH" -v b="$JOB_NAME_BURNIN" '$4 != a && $4 != b')

if [[ -n "$foreign" ]]; then
    trace "EXIT: $(wc -l <<<"$foreign") job(s) not ours on $HOSTNAME -- leaving the node to them"
    exit 0
fi

## Only a RUNNING job has an elapsed time worth measuring. A PENDING one reads
## 0:00 for as long as it waits, so feeding it to the MAX_JOB_HOURS check would
## compare 0 against the limit forever -- harmless, but it also means a backlog
## behind a dead node must never be mistaken for a stuck job and drained on
## that basis. The node is already unusable; draining it for "timeout" would
## just bury the real reason.
if [[ -n "$mine" ]]; then
    running=$(awk '$2 == "RUNNING" { print; exit }' <<<"$mine")
    if [[ -n "$running" ]]; then
        elapsed=$(awk '{print $3}' <<<"$running")

        # Parse elapsed time — squeue formats: MM:SS, HH:MM:SS, D-HH:MM:SS
        elapsed_hours=0
        if [[ "$elapsed" =~ ^([0-9]+)-([0-9]+):([0-9]+):([0-9]+)$ ]]; then
            elapsed_hours=$(( ${BASH_REMATCH[1]} * 24 + ${BASH_REMATCH[2]} ))
        elif [[ "$elapsed" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
            elapsed_hours=${BASH_REMATCH[1]}
        fi

        if [[ "$elapsed_hours" -ge "$MAX_JOB_HOURS" ]]; then
            drain_node "job timeout after ${elapsed_hours}h (RUNNING)"
        fi
    fi
fi

## Per-list, not one gate for both: a queued burn-in must not stop a benchmark
## being submitted, which is the whole point of giving them separate names.
bench_busy=0;  [[ -n "$mine_bench"  ]] && bench_busy=1
burnin_busy=0; [[ -n "$mine_burnin" ]] && burnin_busy=1
trace "queue: bench=$(grep -c . <<<"$mine_bench") burnin=$(grep -c . <<<"$mine_burnin")${running:+ running=${elapsed}}"

## ── Survey what has and has not passed ────────────────────────────────────
## A job passes when verdict() returns DONE for every one of its runs. Anything
## else — FAIL, truncated output from a crashed node, or no file at all — is not
## a pass and gets queued again on the next sweep.
##
## The verdict is derived from the log here, on every sweep, rather than read
## from a marker the sbatch wrote at run time. That is deliberate: a result
## judged by an older, looser gate is re-judged by the current one instead of
## keeping its original pass forever. See the header of verdict.sh.

if [[ ! -f "$PARSERS_DIR/verdict.sh" ]]; then
    trace "EXIT: $PARSERS_DIR/verdict.sh is missing -- it carries the pass/fail rule"
    trace "      for every job, and without it nothing can be judged. Refusing to run,"
    trace "      because treating that as 'no results yet' would requeue the whole"
    trace "      benchmark list on every node, every hour, forever."
    trace "      PARSERS=$PARSERS, from ${SETTINGS_FILE:-<no settings file found>}."
    exit 0
fi
source "$PARSERS_DIR/verdict.sh"

declare -a pending_jobs=()
declare -a failed_jobs=()
declare -A job_runs=()
declare -A fail_reasons=()
newest_result=0
swept=1
## Survey one list. pending_jobs / failed_jobs / swept are per-list and reset
## on each call; fail_reasons, job_runs and newest_result accumulate, because
## they are keyed by job or are properties of the node rather than of a list.
##
## $2 is whether jobs from this list are currently in the queue. If they are,
## the results on disk are being written right now, and a file with no end
## marker yet is a job in progress rather than a job that died -- so the survey
## still runs (quick-view has to say something about every job) but its
## per-run failure lines are not traced, because "INCOMPLETE" logged once a
## cycle for six hours reads as a node failing when it is a node working.
## Nothing acts on a busy list either: see the submit and drain gates below.
survey() {
    local list="$1" busy="${2:-0}" job launch totalRuns passed attempted failed r file mtime

    pending_jobs=()
    failed_jobs=()
    swept=1

for job in $list; do
    launch="$JOBS_DIR/$job.sbatch"
    ## A benchmark named in the list with no sbatch file behind it drops out of
    ## the sweep entirely -- it never goes pending, so it never blocks a node
    ## and never shows up as missing. Worth a line.
    [[ -f "$launch" ]] || { trace "skip $job: no $launch"; continue; }

    if grep -Fq "totalRuns" "$launch"; then
        totalRuns=$(grep -F totalRuns "$launch" | head -1 | awk -F= '{print $2}' | tr -d '[:space:]')
    else
        totalRuns=1
    fi
    [[ "$totalRuns" =~ ^[0-9]+$ ]] && [[ "$totalRuns" -gt 0 ]] || totalRuns=1
    job_runs["$job"]=$totalRuns

    passed=0
    attempted=0
    failed=0
    for ((r = 1; r <= totalRuns; r++)); do
        file=$(result_file "$job" "$r" "$totalRuns")
        [[ -f "$file" ]] || continue
        attempted=1

        mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
        [[ "$mtime" -gt "$newest_result" ]] && newest_result=$mtime

        ## Only DONE is a pass. Everything else counts as a failure, including
        ## a file that ends in no marker at all because the job never reached
        ## its last line -- node crash, walltime kill, OOM. Treating that as
        ## "no verdict yet" left the job pending forever without ever entering
        ## failed_jobs, so a node that reliably kills its jobs retried hourly
        ## and never drained. verdict() reports that case as INCOMPLETE.
        ##
        ## An unterminated file is a dead job only when nothing of this list is
        ## in the queue -- which is what $busy answers, and why nothing acts on
        ## a busy list.
        ## Not $(verdict ...) -- that would run it in a subshell and the reason
        ## would be set in a child and lost. See the note on verdict().
        verdict "$job" "$file"
        if [[ "$VERDICT_STATUS" == "DONE" ]]; then
            passed=$((passed + 1))
        else
            failed=1
            ## Why, not just that. This is the line that turns "allreduce-nonvlink
            ## FAIL" into something an operator can act on without opening the log.
            fail_reasons["$job"]="$VERDICT_REASON"
            [[ "$busy" -eq 0 ]] &&
                trace "$job run $r: $VERDICT_STATUS -- ${VERDICT_REASON}${VERDICT_DETAIL:+ [$VERDICT_DETAIL]}"
        fi
    done

    ## Archived attempts still count as having run — a job whose output was
    ## rotated aside is mid-retry, not untested.
    if [[ "$attempted" -eq 0 ]] &&
       ls "$logs" 2>/dev/null | grep -qE "^${job}(-run[0-9]+)?\.fail[0-9]+\.txt$"; then
        attempted=1
    fi

    [[ "$attempted" -eq 0 ]] && swept=0
    [[ "$failed" -eq 1 ]] && failed_jobs+=("$job")
    [[ "$passed" -lt "$totalRuns" ]] && pending_jobs+=("$job")
done
    return 0
}

in_list() {
    local job="$1"; shift
    local p
    for p in "$@"; do
        [[ "$p" == "$job" ]] && return 0
    done
    return 1
}

## quick-view.txt is the one file an operator reads per node, so it carries
## both lists. A burn-in nobody has run must not read as DONE next to the
## benchmarks that are -- that would report a node as burned in on the strength
## of having passed a fifteen-minute allreduce.
write_quickview() {
    local job reason
    {
        for job in $BENCHMARKS; do
            if ! in_list "$job" "${bench_pending[@]}"; then
                echo "$job: DONE"
            elif [[ "$bench_busy" -eq 1 ]]; then
                echo "$job: IN QUEUE"
            else
                reason="${fail_reasons[$job]}"
                echo "$job: QUEUED${reason:+  <- $reason}"
            fi
        done
        for job in $BURNIN; do
            if ! setting_enabled "$RUN_BURNIN"; then
                echo "$job: BURN-IN OFF  <- RUN_BURNIN=$RUN_BURNIN"
            elif ! in_list "$job" "${burn_pending[@]}"; then
                echo "$job: DONE"
            elif [[ "$burnin_busy" -eq 1 ]]; then
                echo "$job: IN QUEUE"
            else
                reason="${fail_reasons[$job]}"
                echo "$job: QUEUED${reason:+  <- $reason}"
            fi
        done
    } > "$quickview"
}

## ── Survey both lists ─────────────────────────────────────────────────────
##
## Both, every cycle, and independently. Burn-in used to be gated behind a
## clean sweep, which made the ordering absolute but also made it rigid: a node
## that failed one benchmark could never start burning in, and a node three
## days into a burn-in could not pick up a benchmark retry until it finished.
##
## The ordering is now expressed as queue priority instead -- each job's own
## `#SBATCH --nice` -- so both lists can be in the queue at once and Slurm runs
## the important one next. What that does not do is preempt: a
## burn-in run that has already started holds the node until it ends, because
## every job here is --exclusive. The gain is that a benchmark goes ahead of
## the *remaining* burn-in runs rather than behind all of them, which on the
## shipped list is a wait of one run rather than of twelve.
survey "$BENCHMARKS" "$bench_busy"
bench_pending=("${pending_jobs[@]}")
bench_failed=("${failed_jobs[@]}")
bench_swept=$swept
trace "survey: pending=[${bench_pending[*]}] failed=[${bench_failed[*]}] swept=$bench_swept busy=$bench_busy"

burn_pending=()
burn_failed=()
burn_swept=1
if setting_enabled "$RUN_BURNIN"; then
    ## An empty BURNIN with the switch on is a settings mistake worth naming:
    ## the operator asked for a phase that has no jobs in it, and without this
    ## line the node quietly never burns in.
    if [[ -z "${BURNIN// /}" ]]; then
        trace "RUN_BURNIN=$RUN_BURNIN but BURNIN is empty -- nothing to burn in"
    else
        survey "$BURNIN" "$burnin_busy"
        burn_pending=("${pending_jobs[@]}")
        burn_failed=("${failed_jobs[@]}")
        burn_swept=$swept
        trace "burn-in survey: pending=[${burn_pending[*]}] failed=[${burn_failed[*]}] swept=$burn_swept busy=$burnin_busy"
    fi
fi

## Nothing to do at all -- everything that is meant to run has passed.
if [[ "${#bench_pending[@]}" -eq 0 && "${#burn_pending[@]}" -eq 0 ]]; then
    write_quickview
    resume_node
    if setting_enabled "$RUN_BURNIN"; then
        trace "EXIT: every benchmark and every burn-in job passing"
    else
        trace "EXIT: every benchmark passing (burn-in not run: RUN_BURNIN=$RUN_BURNIN)"
    fi
    exit 0
fi

## Everything left is waiting on jobs that are already out there. Nothing to
## submit, nothing to judge -- say what is in flight and stop.
if [[ "$bench_busy" -eq 1 || "$burnin_busy" -eq 1 ]]; then
    if [[ ( "${#bench_pending[@]}" -eq 0 || "$bench_busy" -eq 1 ) && \
          ( "${#burn_pending[@]}" -eq 0 || "$burnin_busy" -eq 1 ) ]]; then
        write_quickview
        trace "EXIT: waiting on our own queue${running:+ (RUNNING for $elapsed, limit ${MAX_JOB_HOURS}h)}"
        exit 0
    fi
fi

## Only failures from a list with nothing in the queue are actionable: a list
## that is mid-run has results being written right now, and judging those would
## drain a node for a job that has not finished.
declare -a failed_jobs_actionable=()
burnin_only=1
if [[ "$bench_busy" -eq 0 && "$bench_swept" -eq 1 ]]; then
    for j in "${bench_failed[@]}"; do failed_jobs_actionable+=("$j"); burnin_only=0; done
fi
if [[ "$burnin_busy" -eq 0 && "$burn_swept" -eq 1 ]]; then
    for j in "${burn_failed[@]}"; do failed_jobs_actionable+=("$j"); done
fi

## ── Drain once the full sweep has run and something is still failing ──────
## Not on the first failure — the rest of the sweep still needs to run, and one
## bad test should not hide the state of the others.

## Only failures that just landed count. Stale results are left alone, so a
## node an operator resumed is not immediately pulled back out of service --
## it takes a fresh retry sweep failing again.

age=-1
[[ "$newest_result" -gt 0 ]] && age=$(( $(date +%s) - newest_result ))

## The reason carries why the first failing job failed, not just its name. A
## Slurm reason is a single short field and there may be several failures, so
## only the first is named -- the rest, and the full text for every one, are in
## trigger.log and quick-view.txt next to the results.
## The list is named in the reason when the failures are burn-in only, because
## the two mean different things to whoever reads `sinfo -R`: a benchmark
## failure is a node that does not work, and a burn-in failure is a node that
## worked for hours and then stopped -- which is the more interesting of the
## two and should not be reported as if it had failed a fifteen-minute
## collective.
if [[ "${#failed_jobs_actionable[@]}" -gt 0 && \
      "$age" -ge 0 && "$age" -lt $(( DRAIN_WINDOW_MINUTES * 60 )) ]]; then
    first_reason="${fail_reasons[${failed_jobs_actionable[0]}]}"
    label=""
    [[ "$burnin_only" -eq 1 ]] && label="burn-in "
    drain_node "${label}${failed_jobs_actionable[*]} FAIL${first_reason:+: $first_reason} ($DRAIN_MARKER)"
fi

## ── Hourly gate ───────────────────────────────────────────────────────────

if [[ "$age" -ge 0 && "$age" -lt $(( RETRY_INTERVAL_HOURS * 3600 )) ]]; then
    trace "EXIT: newest result is ${age}s old, next sweep in $(( RETRY_INTERVAL_HOURS * 3600 - age ))s"
    exit 0
fi
trace "hourly gate open (newest result age=${age}s, -1 means no results on disk)"

## ── Queue every non-passing job, in listed order ──────────────────────────

## A node drained by an operator stays untouched — queueing work behind their
## drain would dump the whole batch on the node the moment they resume it.
drain_reason=$(sinfo -n "$HOSTNAME" -h -o '%E' 2>/dev/null | head -1)
case "$state" in
    *drain*|*down*|*fail*|*maint*)
        if [[ "$drain_reason" != *"$DRAIN_MARKER"* ]]; then
            trace "EXIT: node is $state for a reason that is not ours -- '${drain_reason:-<empty>}' does not carry '$DRAIN_MARKER'. scontrol update nodename=$HOSTNAME state=RESUME to release it."
            exit 0
        fi
        ;;
esac

resume_node

## Queue priority is NOT set here. Each job carries its own `#SBATCH --nice`,
## alongside its time limit and its allocation, because that is where the rest
## of a job's scheduling character already lives -- and because a job submitted
## by hand should carry the same priority as one the sequencer submits. This
## script only decides *what* to submit; the job file decides where it sits in
## the queue. See docs/benchmarks.md.
submit_list() {
    local jname="$1"; shift
    local job launch totalRuns r file submit out

    for job in "$@"; do
    launch="$JOBS_DIR/$job.sbatch"
    totalRuns=${job_runs["$job"]}

    for ((r = 1; r <= totalRuns; r++)); do
        file=$(result_file "$job" "$r" "$totalRuns")
        ## Judged by the current gate, not by whatever marker the sbatch left
        ## behind. A run that passed an older, looser gate is re-queued here --
        ## which is the whole point, and is what the old `tail -1 == DONE` test
        ## structurally could not do.
        verdict "$job" "$file"
        [[ "$VERDICT_STATUS" == "DONE" ]] && continue

        ## What serializes the batch is `#SBATCH --exclusive` in every
        ## jobs/*.sbatch, not anything passed here. Without serialization the
        ## whole batch is eligible at once, and a GPU job landing on top of
        ## dcgm's stress plugins fails on buffer allocation -- nccl-tests
        ## reports that as `Cuda failure 2 'out of memory'` after NCCL init has
        ## already succeeded. The CPU-only jobs (stream, stressapptest) skew
        ## collective timings the same way without ever touching a GPU.
        ##
        ## This used to be `--dependency=singleton` over a shared job name.
        ## Singleton matches on name alone, cluster-wide, so the name had to
        ## carry the hostname or a bare `bringup` would have serialized every
        ## node in the rack against every other -- serialization by string
        ## equality, one typo away from a rack-wide queue of one, and it said
        ## nothing about what the job would actually be given when it ran.
        ## --exclusive states the real requirement -- this job wants the whole
        ## node -- and the scheduler enforces one-at-a-time from that. It also
        ## keeps somebody else's job off the node mid-benchmark, which singleton
        ## never did: it only ever held back OUR jobs of the same name.
        ##
        ## Ordering within a tier still follows the listed order in practice:
        ## these are submitted in that order, carry the same nice, and a
        ## whole-node job leaves no backfill window for a later one to slip
        ## into. It is a scheduling consequence rather than a guarantee, so do
        ## not add a job here that depends on an earlier one having finished.
        ## Ordering *between* tiers is each job's own `#SBATCH --nice`.
        ##
        ## -J is per-list and per-node, and load-bearing: it is what the queue
        ## queries above match on to see our own queued-but-unplaced jobs, and
        ## it is what tells a burn-in apart from a benchmark there. It has to be
        ## passed here rather than as an #SBATCH line -- those are comments, not
        ## shell, and would not expand $HOSTNAME.
        submit="source /etc/profile.d/modules.sh; module load slurm; \
mkdir -p $logs && sbatch -w $HOSTNAME -J $jname \
--export=ALL,RESULT_FILE=$file --output=$file $launch"

        if [[ "$EXPLAIN" -eq 1 ]]; then
            trace "WOULD SUBMIT $job run $r: su - $JOB_USER -c \"$submit\""
            continue
        fi

        archive_result "$file"

        ## sbatch's own diagnosis of a rejected submission is the single most
        ## useful line in this whole script, and it used to go to BCM's action
        ## output, which nothing reads. A bad partition, an unknown node name,
        ## an account limit, or su failing for cmods all land here -- and all
        ## of them look identical from outside: no job, no result file, no
        ## complaint. Merge stderr and keep it.
        out=$(su - "$JOB_USER" -c "$submit" 2>&1)
        if [[ "$out" == *"Submitted batch job"* ]]; then
            trace "submitted $job run $r: ${out##*$'\n'}"
        else
            trace "SUBMIT FAILED $job run $r: ${out:-<no output>}"
        fi
    done
    done
}

## A list with jobs already in the queue is skipped rather than added to --
## that is what keeps a cycle from submitting the same run twice while the
## first copy waits behind a burn-in.
if [[ "${#bench_pending[@]}" -gt 0 && "$bench_busy" -eq 0 ]]; then
    submit_list "$JOB_NAME_BENCH" "${bench_pending[@]}"
fi
if [[ "${#burn_pending[@]}" -gt 0 && "$burnin_busy" -eq 0 ]]; then
    submit_list "$JOB_NAME_BURNIN" "${burn_pending[@]}"
fi

## Reflect the newly queued state for anyone reading quick-view directly.
## Queued lines carry the reason the previous attempt was rejected, so this file
## answers "why is this node still being retested" on its own.
write_quickview
