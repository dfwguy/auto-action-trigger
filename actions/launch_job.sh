#!/bin/bash
#
#

## ── Settings ──────────────────────────────────────────────────────────────
##
## Hardcoded path: BCM invokes this by absolute path with no working directory
## to infer from. Missing settings.sh is fatal rather than defaulted -- an empty
## BENCHMARKS reads as "everything passing" on every node. See docs/settings.md.
home=/home/cmods/bringup
if [[ ! -f "$home/settings.sh" ]]; then
    echo "ERROR: $home/settings.sh is missing -- refusing to run, because an" >&2
    echo "       empty benchmark list reads as 'everything passing' on every node." >&2
    exit 1
fi
source "$home/settings.sh"

## Retry and drain policy, the two lists, and how the ordering between them is
## expressed: docs/sequencer.md#retry-and-drain-behaviour and
## docs/sequencer.md#two-lists.

## set paths
logs="$home/results/$HOSTNAME"
quickview="$logs/quick-view.txt"
tracelog="$logs/trigger.log"

## Per-node and distinct per list: the two lists are queued at once and have to
## be counted and cancelled separately. Anything matching neither is somebody
## else's job. See docs/sequencer.md#two-lists.
JOB_NAME_BENCH="bringup-$HOSTNAME"
JOB_NAME_BURNIN="burnin-$HOSTNAME"

## ── Tracing ───────────────────────────────────────────────────────────────
##
## Every gate below can end the run with a plain `exit 0`, and a node that has
## silently stopped testing looks exactly like one that is quietly idle. So
## every decision is written down instead.
##
## The flags, and what --force deliberately does not override, are in
## docs/sequencer.md#running-it-by-hand. There is no node argument -- the
## trigger fires on the node it is deciding about -- so an unrecognised argument
## is fatal here rather than traced: the run that followed would sweep whatever
## node the command was typed on and report success from a log nobody reads.
EXPLAIN=0
FORCE=0
FORCE_ALL=0
TEST_LIST=""
## Default on for a terminal, off otherwise: BCM's action output goes nowhere
## anyone reads, and neither does pdsh's until you ask with -v.
VERBOSE=0; [[ -t 1 ]] && VERBOSE=1
usage() {
    cat <<'USAGE'
Usage: launch_job.sh [--explain] [--force] [--all] [--test JOB] [--verbose|--quiet]

  --explain, -n   dry run: print every gate, submit/drain/archive nothing
  --force,   -f   ignore the hourly retry gate and sweep now
  --all,     -a   re-queue every job, passing ones included (implies --force)
  --test,    -t   run JOB instead of the configured lists, whether or not
                  BENCHMARKS names it. Repeatable. Implies --force and --all,
                  drains nothing, and leaves quick-view.txt alone
  --verbose, -v   mirror the trace to stdout (default when stdout is a tty)
  --quiet,   -q   never mirror the trace to stdout

Decides about the node it runs on, and takes no node argument. To sweep a set
of nodes, name them where they can be reached:

  pdsh -w 'ink50-dh01-h02-[11,13-18]' '/home/cmods/bringup/actions/launch_job.sh -f -v'

With no arguments -- how BCM invokes it -- the hourly gate applies and only
jobs without a passing result are queued.
USAGE
}
## while/shift rather than `for arg`: -t takes a value.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --explain|-n|--dry-run) EXPLAIN=1 ;;
        --force|-f)             FORCE=1 ;;
        --all|-a)               FORCE=1; FORCE_ALL=1 ;;
        --test|-t)
            [[ -n "${2:-}" ]] || {
                echo "ERROR: $1 needs a job name -- nothing was swept." >&2
                usage >&2
                exit 2 ;
            }
            TEST_LIST+="${TEST_LIST:+ }$2"
            FORCE=1; FORCE_ALL=1
            shift ;;
        --verbose|-v)           VERBOSE=1 ;;
        --quiet|-q)             VERBOSE=0 ;;
        -h|--help)              usage; exit 0 ;;
        *)
            echo "ERROR: unrecognised argument '$1' -- nothing was swept." >&2
            usage >&2
            exit 2 ;;
    esac
    shift
done

## Fatal rather than traced and skipped, unlike a bad BENCHMARKS entry: the
## operator is standing there, and a name that resolves to no .sbatch would
## otherwise sweep nothing and exit looking like a healthy idle cycle.
## See docs/sequencer.md#running-a-job-that-is-not-in-the-list.
for _job in $TEST_LIST; do
    [[ -f "$JOBS_DIR/$_job.sbatch" ]] || {
        echo "ERROR: --test $_job: no $JOBS_DIR/$_job.sbatch -- nothing was swept." >&2
        echo "       Available: $(cd "$JOBS_DIR" 2>/dev/null && ls ./*.sbatch 2>/dev/null | sed 's#^\./##;s#\.sbatch$##' | tr '\n' ' ')" >&2
        exit 2
    }
done
unset _job

mkdir -p "$logs"

## Tested once, not per line, and a run that cannot write anything down says
## everything out loud instead -- otherwise it is silent in both directions at
## once. root's cycles leave trigger.log root-owned inside a $JOB_USER-owned
## directory, so a hand-run as $JOB_USER very often cannot append.
##
## The braces matter: `>> file 2>/dev/null` does NOT suppress the failure.
## Redirections open left to right, so the append fails while stderr is still
## the terminal and bash reports it there, once per traced line.
TRACE_WRITABLE=-1
trace_writable() {
    [[ "$TRACE_WRITABLE" -ge 0 ]] && return "$TRACE_WRITABLE"
    if { : >> "$tracelog"; } 2>/dev/null; then
        TRACE_WRITABLE=0
    else
        TRACE_WRITABLE=1
        VERBOSE=1
        echo "WARNING: cannot write $tracelog as $(id -un) -- $(stat -c '%U owns it, mode %a' "$tracelog" 2>/dev/null || echo 'and it cannot be created')." >&2
        echo "         Tracing to stdout only. Root's next cycle repairs it, or:" >&2
        echo "           sudo chown -R $JOB_USER:$JOB_USER $logs" >&2
    fi
    return "$TRACE_WRITABLE"
}
trace() {
    trace_writable && printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$tracelog" 2>/dev/null
    [[ "$EXPLAIN" -eq 1 || "$VERBOSE" -eq 1 ]] && printf '%s\n' "$*"
    return 0
}

## Keep the trace from growing without bound -- it gets a line or two per
## monitoring cycle, forever.
if [[ -f "$tracelog" ]] && [[ "$(stat -c %s "$tracelog" 2>/dev/null || echo 0)" -gt 1000000 ]]; then
    tail -2000 "$tracelog" > "$tracelog.tmp" && mv "$tracelog.tmp" "$tracelog"
fi

## Appended to the gates a forced run does NOT open, so the trace answers "I
## ran it with --force and nothing happened" where the operator is reading.
force_note=""
[[ "$FORCE" -eq 1 ]] && force_note=" --force does not override that."

## ── Extra environment for the jobs ────────────────────────────────────────
##
## An allowlist rather than a blocklist: the submission is built as a string and
## run through `su - $JOB_USER -c`, so a plausible typo like `NCCL_X=0;id` would
## run as root on 200+ nodes. Commas are out because --export is itself
## comma-separated. See docs/settings.md#what-is-rejected.
JOB_ENV_ARGS=""
JOB_ENV_NAMES=()
## Unquoted on purpose -- this is the list-in-a-string convention BENCHMARKS
## and CONTAINERS already use, and word splitting is how it is read.
# shellcheck disable=SC2086
for _pair in $JOB_ENV; do
    if [[ ! "$_pair" =~ ^[A-Za-z_][A-Za-z0-9_]*=[A-Za-z0-9_.:/+@%-]*$ ]]; then
        trace "WARNING: JOB_ENV entry '$_pair' is not NAME=VALUE with a value of [A-Za-z0-9_.:/+@%-] -- dropped, and the jobs will run without it."
        continue
    fi
    JOB_ENV_ARGS+=",$_pair"
    JOB_ENV_NAMES+=("${_pair%%=*}")
done
unset _pair

## Without this line, results appearing off-cadence -- or a passing job suddenly
## re-running -- reads as the sequencer misbehaving rather than as a human.
if [[ -n "$TEST_LIST" ]]; then
    trace "MANUAL TEST: --test $TEST_LIST -- BENCHMARKS and BURNIN not surveyed this run, no drains, quick-view.txt left alone"
else
    [[ "$FORCE" -eq 1 ]] &&
        trace "MANUAL: --force -- hourly gate bypassed$([[ "$FORCE_ALL" -eq 1 ]] && printf ', --all -- passing jobs re-queued too')"
fi

## ── Hand the result path to $JOB_USER ─────────────────────────────────────
##
## Re-checked every cycle, not just on creation, so clearing results/ by hand is
## safe and an already-broken tree repairs itself.
## See docs/sequencer.md#result-path-ownership.
ensure_owned() {
    local d="$1"
    [[ -d "$d" ]] || mkdir -p "$d" 2>/dev/null || return 1
    [[ "$(stat -c %U "$d" 2>/dev/null)" == "$JOB_USER" ]] && return 0
    ## Only root can hand a directory over; anyone else gets a diagnosis.
    if [[ "$EUID" -ne 0 ]]; then
        trace "WARNING: $d is owned by $(stat -c %U "$d" 2>/dev/null), not $JOB_USER, and we are not root -- sbatch --output will fail"
        return 0
    fi
    trace "chown $JOB_USER $d (was $(stat -c %U "$d" 2>/dev/null))"
    chown "$JOB_USER:$JOB_USER" "$d" 2>/dev/null
}

## The same repair for the two files this script writes itself: a handed-over
## directory is not enough, since root's cycle creates trigger.log and
## quick-view.txt inside it root-owned at 644.
ensure_file_owned() {
    local f="$1"
    [[ -e "$f" ]] || return 0
    [[ "$(stat -c %U "$f" 2>/dev/null)" == "$JOB_USER" ]] && return 0
    [[ "$EUID" -eq 0 ]] || return 0   # diagnosed by trace_writable, not here
    trace "chown $JOB_USER $f (was $(stat -c %U "$f" 2>/dev/null))"
    chown "$JOB_USER:$JOB_USER" "$f" 2>/dev/null
}

ensure_owned "$home/results"
ensure_owned "$logs"
ensure_file_owned "$tracelog"
ensure_file_owned "$quickview"

source /etc/profile.d/modules.sh
module load slurm

## BCM's environment, not a login shell. Without the client tools every check
## below reads as "node not in slurm" and the script exits looking healthy.
for tool in sinfo squeue scontrol sbatch; do
    command -v "$tool" >/dev/null 2>&1 || {
        trace "EXIT: $tool not on PATH after 'module load slurm' (PATH=$PATH)"
        exit 0
    }
done

## ── Pause ─────────────────────────────────────────────────────────────────
##
## A pause has to reach the queue too, or it is not a pause: pending jobs are
## cancelled, a running one is left to finish, and only our two job names are
## ever touched. See docs/settings.md#pause-switches.
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

    [[ "$FORCE" -eq 1 ]] &&
        trace "--force does not override PAUSE_JOBS: it is a site switch, not a timing gate. Set PAUSE_JOBS=no in ${SETTINGS_FILE:-SETTINGS} to sweep."
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

## Move a result aside so the slot is free for the next attempt; the archives
## double as the attempt history. Two suffixes because status-check.sh reads the
## name as a verdict -- it counts .fail<N> as rejections, and a pass that --all
## re-runs is not one. See docs/sequencer.md.
archive_result() {
    local file="$1" kind="${2:-fail}" base n
    [[ -f "$file" ]] || return 0
    base=$(basename "$file" .txt)
    ## ls|grep, not a glob: the serial must count archives of exactly this shape
    ## and a glob cannot spell "one or more digits", so <base>.fail[0-9]*.txt
    ## would swallow a hand-renamed <base>.fail2-bad.txt and the mv below would
    ## destroy an earlier attempt. Every name here came from result_file(), so
    ## the odd filenames SC2010 guards against cannot arise.
    # shellcheck disable=SC2010
    n=$(ls "$logs" 2>/dev/null | grep -cE "^${base}\.${kind}[0-9]+\.txt$")
    mv "$file" "$logs/${base}.${kind}$((n + 1)).txt"
}

## Drain only a node that is currently usable; anything already drained is left
## alone. DRAIN_AFTER_FAILED_BENCHMARK=no suppresses every drain here, including
## the timeout one, but still traces it. See docs/settings.md#drains.
drain_node() {
    local reason="$1"
    ## A hand-run of a job the fleet is not judged on cannot take the node out.
    ## See docs/sequencer.md#running-a-job-that-is-not-in-the-list.
    [[ -n "$TEST_LIST" ]] && {
        trace "drain suppressed by --test: $reason"
        return 0
    }
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

## ── Drains Slurm set itself ───────────────────────────────────────────────
##
## Cleared before any gate below reads the node state, and only the `machine`
## class -- every other drain belongs to whoever set it. After the PAUSE_JOBS
## gate on purpose: a resume is touching Slurm. The state is re-read rather than
## assumed. See docs/sequencer.md#drains-slurm-set-itself.
if [[ -f "$home/slurm-recovery.sh" ]]; then
    recover_log() { trace "$@"; }
    RECOVER_ACCEPT="machine"
    RECOVER_LOG="$logs/recover.log"
    RECOVER_DRY_RUN="$EXPLAIN"
    source "$home/slurm-recovery.sh"
    if slurm_recover_node "$HOSTNAME"; then
        [[ "$EXPLAIN" -eq 1 ]] || state=$(sinfo -N -n "$HOSTNAME" -h -o '%T')
        ensure_file_owned "$RECOVER_LOG"
        trace "state after recovery=$(printf '%s' "$state" | tr '\n' ',')"
    fi
else
    ## Named rather than skipped quietly: the tell for a deployment predating
    ## the file, whose absence is otherwise invisible -- nodes just stay drained.
    trace "WARNING: $home/slurm-recovery.sh is missing -- drains set by Slurm itself (prolog, rogue process, no reason) will not be cleared. Stale deployment?"
fi

## Wait if anything of ours is queued for this node. Asked per list by name and
## once by node, and why each query is load-bearing:
## docs/sequencer.md#retry-and-drain-behaviour.
##
## %V and %r come last and in that order: a Slurm reason is free text with
## spaces in it, so everything reading these lines takes $1..$4 positionally and
## the reason as the remainder. Nothing may be added after %r.
queue_fmt='%i %T %M %V %r'
mine_bench=$(squeue -h -n "$JOB_NAME_BENCH"  -o "$queue_fmt" 2>/dev/null)
mine_burnin=$(squeue -h -n "$JOB_NAME_BURNIN" -o "$queue_fmt" 2>/dev/null)

## The scheduler's reason is the only part of a stuck queue that says anything.
## Cleanly-schedulable jobs report "None" and are left out, so this is empty on
## a healthy cycle and the trace stays one line.
queue_detail() {
    awk 'NF >= 5 {
             reason = $5
             for (i = 6; i <= NF; i++) reason = reason " " $i
             if (reason == "None" || reason == "(null)") next
             printf " [%s %s: %s]", $1, $2, reason
         }' <<<"$1"
}

## ── Jobs the scheduler has given up on ────────────────────────────────────
##
## A held job reads as PENDING at priority 0 and never starts, so the busy gate
## below would wait on it forever. Ours by construction (matched by name), so
## cancelling is safe; an operator's own hold is only named in the trace, and
## the cadence comes from the job's own submit time.
## See docs/sequencer.md#jobs-the-scheduler-has-given-up-on.
LAUNCH_FAILED_HELD='launch failed requeued held'

reap_held_jobs() {
    local queue="$1" id state elapsed submit reason age submit_epoch out now
    local wait_secs=$(( RETRY_INTERVAL_HOURS * 3600 ))
    now=$(date +%s)
    reaped=0
    while read -r id state elapsed submit reason; do
        [[ -n "$id" && "$state" == "PENDING" ]] || continue
        [[ "$reason" == "$LAUNCH_FAILED_HELD" ]] || continue

        ## No parseable submit time means no cadence, and cancelling on every
        ## cycle is worse than leaving it -- the operator still gets the reason.
        if ! submit_epoch=$(date -d "$submit" +%s 2>/dev/null) || [[ -z "$submit_epoch" ]]; then
            trace "job $id is held after a failed launch, but its submit time ('$submit') did not parse -- left queued; 'scancel $id' to clear it"
            continue
        fi
        age=$(( now - submit_epoch ))

        if [[ "$age" -lt "$wait_secs" ]]; then
            trace "job $id held after a failed launch ('$reason') ${age}s ago -- cancelling and resubmitting in $(( wait_secs - age ))s"
            continue
        fi
        if [[ "$EXPLAIN" -eq 1 ]]; then
            trace "WOULD CANCEL $id -- held ${age}s after a failed launch ('$reason')"
            continue
        fi
        if ! command -v scancel >/dev/null 2>&1; then
            trace "WARNING: job $id is held after a failed launch but scancel is not on PATH -- left queued"
            continue
        fi

        out=$(scancel "$id" 2>&1)
        trace "CANCELLED $id -- held ${age}s after a failed launch ('$reason'); the survey below decides what to resubmit${out:+ -- $out}"
        reaped=1
    done <<<"$queue"
}

reap_held_jobs "$mine_bench";  bench_reaped=$reaped
reap_held_jobs "$mine_burnin"; burnin_reaped=$reaped

## Re-ask rather than editing the lists in place: scancel is asynchronous, and
## the busy gate must act on what the scheduler holds now.
[[ "$bench_reaped"  -eq 1 ]] && mine_bench=$(squeue -h -n "$JOB_NAME_BENCH"  -o "$queue_fmt" 2>/dev/null)
[[ "$burnin_reaped" -eq 1 ]] && mine_burnin=$(squeue -h -n "$JOB_NAME_BURNIN" -o "$queue_fmt" 2>/dev/null)

mine="$(printf '%s\n%s\n' "$mine_bench" "$mine_burnin" | grep -v '^$')"

## Anything on the node that is not ours. Matched by name, because the node
## query returns our own jobs too once the scheduler has placed one.
foreign=$(squeue -h -w "$HOSTNAME" -o '%i %T %M %j' 2>/dev/null |
          awk -v a="$JOB_NAME_BENCH" -v b="$JOB_NAME_BURNIN" '$4 != a && $4 != b')

if [[ -n "$foreign" ]]; then
    trace "EXIT: $(wc -l <<<"$foreign") job(s) not ours on $HOSTNAME -- leaving the node to them"
    exit 0
fi

## RUNNING only: a PENDING job reads 0:00 for as long as it waits, so a backlog
## behind a dead node must never be drained as a stuck job -- that would bury
## the real reason. See docs/sequencer.md#retry-and-drain-behaviour.
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
trace "queue: bench=$(grep -c . <<<"$mine_bench") burnin=$(grep -c . <<<"$mine_burnin")${running:+ running=${elapsed}}$(queue_detail "$mine")"

## ── Survey what has and has not passed ────────────────────────────────────
## A job passes when verdict() returns DONE for every run. The verdict is
## re-derived from the log on every sweep rather than read from a marker the
## sbatch left, so a result that passed an older, looser gate does not keep its
## pass forever. See the header of verdict.sh.

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
declare -a surveyed_jobs=()
declare -A job_runs=()
declare -A fail_reasons=()
newest_result=0
swept=1
## Survey one list. pending_jobs / failed_jobs / swept reset on each call;
## fail_reasons, job_runs and newest_result accumulate, being keyed by job or
## properties of the node.
##
## $2 is whether this list is in the queue. If it is, the survey still runs --
## quick-view has to say something about every job -- but its per-run failure
## lines are not traced: "INCOMPLETE" once a cycle for six hours reads as a node
## failing when it is a node working. See docs/sequencer.md#two-lists.
survey() {
    local list="$1" busy="${2:-0}" job launch totalRuns passed attempted failed r file mtime

    pending_jobs=()
    failed_jobs=()
    surveyed_jobs=()
    swept=1

for job in $list; do
    launch="$JOBS_DIR/$job.sbatch"
    ## A listed benchmark with no sbatch behind it drops out of the sweep
    ## entirely and would otherwise never show up as missing. Worth a line.
    [[ -f "$launch" ]] || { trace "skip $job: no $launch"; continue; }
    ## What --all can re-queue. Built here rather than from $list, so a forced
    ## sweep cannot pend a job that has nothing to submit.
    surveyed_jobs+=("$job")

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

        ## Only DONE is a pass. A file ending in no marker (crash, walltime
        ## kill, OOM) counts as a failure rather than "no verdict yet" -- as the
        ## latter it stayed pending forever, never entered failed_jobs, and a
        ## node that reliably killed its jobs never drained.
        ##
        ## Not $(verdict ...) -- a subshell would set the reason in a child and
        ## lose it. See the note on verdict().
        verdict "$job" "$file"
        if [[ "$VERDICT_STATUS" == "DONE" ]]; then
            passed=$((passed + 1))
        else
            failed=1
            ## Why, not just that: what an operator can act on without opening
            ## the log.
            fail_reasons["$job"]="$VERDICT_REASON"
            [[ "$busy" -eq 0 ]] &&
                trace "$job run $r: $VERDICT_STATUS -- ${VERDICT_REASON}${VERDICT_DETAIL:+ [$VERDICT_DETAIL]}"
        fi
    done

    ## Archived attempts still count as having run — a rotated-aside job is
    ## mid-retry, not untested. ls|grep for the same reason as archive_result():
    ## the shape needs alternation and a one-or-more digit run, and a looser
    ## match marks a never-run job as attempted, dropping it out of the
    ## swept-clean gate below with nothing written down.
    # shellcheck disable=SC2010
    if [[ "$attempted" -eq 0 ]] &&
       ls "$logs" 2>/dev/null | grep -qE "^${job}(-run[0-9]+)?\.(fail|prev)[0-9]+\.txt$"; then
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

## The one file an operator reads per node, so it carries both lists -- a
## burn-in nobody has run must not read as DONE next to benchmarks that are.
##
## Temp file and rename, not truncate in place: rename needs write permission on
## the *directory*, which $JOB_USER has, while truncating needs it on the file,
## which they do not when root's cycle created it. A reader also never sees the
## file half-written.
forced_reason=""
[[ "$FORCE_ALL" -eq 1 ]] && forced_reason="re-queued by --all"
write_quickview() {
    local job reason
    ## The file describes the BENCHMARKS and BURNIN lists, which a --test run
    ## has not surveyed -- writing it here would report every real column as
    ## QUEUED. See docs/sequencer.md#running-a-job-that-is-not-in-the-list.
    [[ -n "$TEST_LIST" ]] && return 0
    {
        for job in $BENCHMARKS; do
            if ! in_list "$job" "${bench_pending[@]}"; then
                echo "$job: DONE"
            elif [[ "$bench_busy" -eq 1 ]]; then
                echo "$job: IN QUEUE"
            else
                reason="${fail_reasons[$job]:-${forced_reason}}"
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
                reason="${fail_reasons[$job]:-${forced_reason}}"
                echo "$job: QUEUED${reason:+  <- $reason}"
            fi
        done
    } > "$quickview.tmp" 2>/dev/null && mv "$quickview.tmp" "$quickview" 2>/dev/null ||
        trace "WARNING: could not write $quickview as $(id -un) -- $(stat -c '%U owns it' "$quickview" 2>/dev/null || echo 'the directory is not writable'). The trace above is the current state."
}

## ── Survey both lists ─────────────────────────────────────────────────────
##
## Both, every cycle, independently; the ordering between them is queue priority
## rather than a gate. See docs/sequencer.md#two-lists.
##
## --all widens `pending` to every job in the list, and only that -- the failure
## and sweep bookkeeping keeps reading the results on disk, so a forced re-sweep
## neither invents a failure nor clears one.
##
## --test replaces the list outright rather than adding to it, so a run asked
## for one job submits one job. See
## docs/sequencer.md#running-a-job-that-is-not-in-the-list.
survey "${TEST_LIST:-$BENCHMARKS}" "$bench_busy"
bench_pending=("${pending_jobs[@]}")
bench_failed=("${failed_jobs[@]}")
bench_swept=$swept
[[ "$FORCE_ALL" -eq 1 ]] && bench_pending=("${surveyed_jobs[@]}")
trace "survey${TEST_LIST:+ (--test)}: pending=[${bench_pending[*]}] failed=[${bench_failed[*]}] swept=$bench_swept busy=$bench_busy"

burn_pending=()
burn_failed=()
burn_swept=1
if [[ -z "$TEST_LIST" ]] && setting_enabled "$RUN_BURNIN"; then
    ## A settings mistake worth naming: without this line the node quietly
    ## never burns in.
    if [[ -z "${BURNIN// /}" ]]; then
        trace "RUN_BURNIN=$RUN_BURNIN but BURNIN is empty -- nothing to burn in"
    else
        survey "$BURNIN" "$burnin_busy"
        burn_pending=("${pending_jobs[@]}")
        burn_failed=("${failed_jobs[@]}")
        burn_swept=$swept
        [[ "$FORCE_ALL" -eq 1 ]] && burn_pending=("${surveyed_jobs[@]}")
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
        ## The scheduler's reason is repeated here rather than left to the
        ## `queue:` line above: this is the line that says why the node stopped
        ## and it has to stand on its own.
        trace "EXIT: waiting on our own queue${running:+ (RUNNING for $elapsed, limit ${MAX_JOB_HOURS}h)}$(queue_detail "$mine").${force_note:+$force_note Submitting on top of a queued batch is how a node runs the same job twice; scancel -n $JOB_NAME_BENCH / -n $JOB_NAME_BURNIN first if that is what you want.}"
        exit 0
    fi
fi

## Only failures from a list with nothing in the queue are actionable: judging a
## mid-run list would drain a node for a job that has not finished.
declare -a failed_jobs_actionable=()
burnin_only=1
if [[ "$bench_busy" -eq 0 && "$bench_swept" -eq 1 ]]; then
    for j in "${bench_failed[@]}"; do failed_jobs_actionable+=("$j"); burnin_only=0; done
fi
if [[ "$burnin_busy" -eq 0 && "$burn_swept" -eq 1 ]]; then
    for j in "${burn_failed[@]}"; do failed_jobs_actionable+=("$j"); done
fi

## ── Drain once the full sweep has run and something is still failing ──────
## Not on the first failure, and only on results newer than the drain window.
## See docs/sequencer.md#retry-and-drain-behaviour.

age=-1
[[ "$newest_result" -gt 0 ]] && age=$(( $(date +%s) - newest_result ))

## A Slurm reason is one short field, so only the first failure is named -- the
## rest are in trigger.log and quick-view.txt. Burn-in-only failures are
## labelled: to whoever reads `sinfo -R`, a node that worked for hours and then
## stopped is not the same as one that failed a fifteen-minute collective.
if [[ "${#failed_jobs_actionable[@]}" -gt 0 && \
      "$age" -ge 0 && "$age" -lt $(( DRAIN_WINDOW_MINUTES * 60 )) ]]; then
    first_reason="${fail_reasons[${failed_jobs_actionable[0]}]}"
    label=""
    [[ "$burnin_only" -eq 1 ]] && label="burn-in "
    drain_node "${label}${failed_jobs_actionable[*]} FAIL${first_reason:+: $first_reason} ($DRAIN_MARKER)"
fi

## ── Hourly gate ───────────────────────────────────────────────────────────

## The only gate --force opens, because it is a cadence and not a safety check:
## everything deciding whether this node should get work at all is asked
## elsewhere. See docs/sequencer.md#running-it-by-hand.
if [[ "$age" -ge 0 && "$age" -lt $(( RETRY_INTERVAL_HOURS * 3600 )) ]]; then
    if [[ "$FORCE" -eq 1 ]]; then
        trace "hourly gate bypassed by --force (newest result is ${age}s old, would have waited $(( RETRY_INTERVAL_HOURS * 3600 - age ))s)"
    else
        trace "EXIT: newest result is ${age}s old, next sweep in $(( RETRY_INTERVAL_HOURS * 3600 - age ))s"
        exit 0
    fi
else
    trace "hourly gate open (newest result age=${age}s, -1 means no results on disk)"
fi

## ── Queue every non-passing job, in listed order ──────────────────────────

## Queueing behind an operator's drain would dump the whole batch on the node
## the moment they resume it, so nothing is submitted unless the drain carries
## our own marker. --force and --all move the *schedule*, not this.
drain_reason=$(sinfo -n "$HOSTNAME" -h -o '%E' 2>/dev/null | head -1)
case "$state" in
    *drain*|*down*|*fail*|*maint*)
        if [[ "$drain_reason" != *"$DRAIN_MARKER"* ]]; then
            trace "EXIT: node is $state for a reason that is not ours -- '${drain_reason:-<empty>}' does not carry '$DRAIN_MARKER'.${force_note} scontrol update nodename=$HOSTNAME state=RESUME to release it."
            exit 0
        fi
        ;;
esac

resume_node

## Queue priority is NOT set here: each job carries its own `#SBATCH --nice`, so
## a hand-submitted job sits where a sequencer-submitted one would. This script
## decides only *what* to submit. See docs/benchmarks.md#queue-priority.
submit_list() {
    local jname="$1"; shift
    local job launch totalRuns r file submit out kind name

    for job in "$@"; do
    launch="$JOBS_DIR/$job.sbatch"
    totalRuns=${job_runs["$job"]}

    ## The job file wins when both name a variable, which is right -- but the
    ## override was invisible, so a SETTINGS line that did nothing looked exactly
    ## like one that worked. See docs/settings.md#the-job-file-wins.
    if [[ -f "$launch" ]]; then
        for name in "${JOB_ENV_NAMES[@]}"; do
            grep -qE "^[[:space:]]*export[[:space:]]+$name=" "$launch" &&
                trace "NOTE: JOB_ENV sets $name, but $job.sbatch exports its own -- the job file's value is what runs."
        done
    fi

    for ((r = 1; r <= totalRuns; r++)); do
        file=$(result_file "$job" "$r" "$totalRuns")
        ## Judged by the current gate, so a run that passed an older, looser one
        ## is re-queued here. Under --all the verdict is still taken: it decides
        ## which suffix the existing result is kept under. See archive_result.
        kind=fail
        verdict "$job" "$file"
        if [[ "$VERDICT_STATUS" == "DONE" ]]; then
            [[ "$FORCE_ALL" -eq 1 ]] || continue
            kind=prev
        fi

        ## Nothing here serializes the batch -- `#SBATCH --exclusive` in every
        ## jobs/*.sbatch does, and no job may depend on an earlier one having
        ## finished. See docs/sequencer.md.
        ##
        ## -J is load-bearing: it is what the queue queries above match on to see
        ## our own queued-but-unplaced jobs, and what tells a burn-in from a
        ## benchmark. It must be passed here, not as an #SBATCH line -- those are
        ## comments, not shell, and would not expand $HOSTNAME.
        submit="source /etc/profile.d/modules.sh; module load slurm; \
mkdir -p $logs && sbatch -w $HOSTNAME -J $jname \
--export=ALL,RESULT_FILE=$file$JOB_ENV_ARGS --output=$file $launch"

        if [[ "$EXPLAIN" -eq 1 ]]; then
            trace "WOULD SUBMIT $job run $r$([[ -f "$file" ]] && printf ' (existing %s result kept as .%s<N>.txt)' "$VERDICT_STATUS" "$kind"): $([[ "$EUID" -eq 0 ]] && printf 'su - %s -c ' "$JOB_USER")\"$submit\""
            continue
        fi

        archive_result "$file" "$kind"

        ## stderr is merged and kept: a bad partition, an unknown node name, an
        ## account limit and a failed su all look identical from outside -- no
        ## job, no result file, no complaint -- and sbatch's own diagnosis is the
        ## only thing that tells them apart.
        ##
        ## Same submission either way; only how we arrive at $JOB_USER differs.
        ## `su` authenticates for anyone but root, and a hand-run over pdsh has
        ## no terminal to be asked on. See docs/sequencer.md#running-it-by-hand.
        if [[ "$EUID" -eq 0 ]]; then
            out=$(su - "$JOB_USER" -c "$submit" 2>&1)
        elif [[ "$(id -un)" == "$JOB_USER" ]]; then
            out=$(bash -lc "$submit" 2>&1)
        else
            trace "SUBMIT FAILED $job run $r: running as $(id -un), which is neither root nor $JOB_USER -- 'su - $JOB_USER' would ask for a password. Run as root or as $JOB_USER."
            continue
        fi
        if [[ "$out" == *"Submitted batch job"* ]]; then
            ## The environment goes in the trace, not just the job id: when a
            ## result is questioned weeks later, SETTINGS says whatever it says
            ## then, so what the run was given has to be written down now.
            trace "submitted $job run $r: ${out##*$'\n'}${JOB_ENV_ARGS:+ (JOB_ENV:${JOB_ENV_ARGS//,/ })}"
        else
            trace "SUBMIT FAILED $job run $r: ${out:-<no output>}"
        fi
    done
    done
}

## Skipped rather than added to: what keeps a cycle from submitting the same run
## twice while the first copy waits behind a burn-in.
if [[ "${#bench_pending[@]}" -gt 0 && "$bench_busy" -eq 0 ]]; then
    submit_list "$JOB_NAME_BENCH" "${bench_pending[@]}"
fi
if [[ "${#burn_pending[@]}" -gt 0 && "$burnin_busy" -eq 0 ]]; then
    submit_list "$JOB_NAME_BURNIN" "${burn_pending[@]}"
fi

## Reflect the newly queued state. Queued lines carry the reason the previous
## attempt was rejected, so this file answers "why is this node still being
## retested" on its own.
write_quickview
