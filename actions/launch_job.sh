#!/bin/bash
#
#

## ── Settings ──────────────────────────────────────────────────────────────
##
## Located from this file rather than a literal path, which is what lets the
## tree move with the account. See docs/reference/layout.md#runtime-paths.
## Missing settings.sh is fatal rather than defaulted -- an empty BENCHMARKS
## reads as "everything passing" on every node. See docs/reference/settings.md.
## LAUNCH_JOB_HOME is for the test suites; nothing in the deployment sets it.
home="${LAUNCH_JOB_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if [[ ! -f "$home/settings.sh" ]]; then
    echo "ERROR: $home/settings.sh is missing -- refusing to run, because an" >&2
    echo "       empty benchmark list reads as 'everything passing' on every node." >&2
    exit 1
fi
source "$home/settings.sh"

## Retry and drain policy, the two lists, and how the ordering between them is
## expressed: docs/explanation/sequencing.md#retry-and-drain-behaviour and
## docs/explanation/sequencing.md#two-lists.

## set paths
logs="$home/results/$HOSTNAME"
quickview="$logs/quick-view.txt"
tracelog="$logs/trigger.log"

## Per-node and distinct per list: the two lists are queued at once and have to
## be counted and cancelled separately. Anything matching neither is somebody
## else's job. See docs/explanation/sequencing.md#two-lists.
JOB_NAME_BENCH="bringup-$HOSTNAME"
JOB_NAME_BURNIN="burnin-$HOSTNAME"

## A job is either a `.sbatch` this script submits, or a `.sh` it runs on the
## node so the job's own tool submits. `.sbatch` wins when both exist.
##
## The `job_launch=host` line is what makes a `.sh` a job: JOBS_DIR also holds
## sourced helpers like nccl-hca.sh, and a bare *.sh glob would offer those as
## benchmarks. See docs/explanation/sequencing.md#host-launched-jobs.
job_launcher() {
    local job="$1"
    [[ -f "$JOBS_DIR/$job.sbatch" ]] && { printf '%s\n' "$JOBS_DIR/$job.sbatch"; return 0; }
    [[ -f "$JOBS_DIR/$job.sh" ]] &&
        grep -qE '^[[:space:]]*job_launch=host[[:space:]]*$' "$JOBS_DIR/$job.sh" && {
            printf '%s\n' "$JOBS_DIR/$job.sh"; return 0; }
    return 1
}

## The listing --test and the survey offer. Same rule as job_launcher, so a
## name that appears here is a name that resolves.
job_list() {
    local f
    for f in "$JOBS_DIR"/*.sbatch; do
        [[ -f "$f" ]] && { f=${f##*/}; printf '%s\n' "${f%.sbatch}"; }
    done
    for f in "$JOBS_DIR"/*.sh; do
        [[ -f "$f" ]] && grep -qE '^[[:space:]]*job_launch=host[[:space:]]*$' "$f" &&
            { f=${f##*/}; printf '%s\n' "${f%.sh}"; }
    done
}

## How many runs a job wants. Read from the launcher rather than SETTINGS, and
## used by both the cadence gate and the survey -- two readings of `totalRuns`
## would drift, and the gate would key on a file the survey never looks at.
job_total_runs() {
    local launch="$1" total=1
    if grep -Fq "totalRuns" "$launch"; then
        total=$(grep -F totalRuns "$launch" | head -1 | awk -F= '{print $2}' | tr -d '[:space:]')
    fi
    [[ "$total" =~ ^[0-9]+$ ]] && [[ "$total" -gt 0 ]] || total=1
    printf '%s' "$total"
}

## Result file for run $2 of job $1. Single-run jobs use <job>.txt.
result_file() {
    local job="$1" run="$2" total="$3"
    if [[ "$total" -eq 1 ]]; then
        echo "$logs/$job.txt"
    else
        echo "$logs/$job-run${run}.txt"
    fi
}

## ── Tracing ───────────────────────────────────────────────────────────────
##
## Every gate below can end the run with a plain `exit 0`, and a node that has
## silently stopped testing looks exactly like one that is quietly idle. So
## every decision is written down instead.
##
## The flags, and what --force deliberately does not override, are in
## docs/how-to/run-a-job-by-hand.md. There is no node argument -- the
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
    cat <<USAGE
Usage: launch_job.sh [--explain] [--force] [--all] [--test JOB] [--verbose|--quiet]

  --explain, -n   dry run: print every gate, submit/drain/archive nothing
  --force,   -f   ignore each job's hourly retry window and submit now
  --all,     -a   offer every job, passing ones included (implies --force)
  --test,    -t   run JOB instead of the configured lists, whether or not
                  BENCHMARKS names it. Repeatable. Implies --force and --all,
                  drains nothing, and leaves quick-view.txt alone
  --verbose, -v   mirror the trace to stdout (default when stdout is a tty)
  --quiet,   -q   never mirror the trace to stdout

Decides about the node it runs on, and takes no node argument. To sweep a set
of nodes, name them where they can be reached:

  pdsh -R ssh -w 'ink50-dh01-h02-[11,13-18]' '$home/actions/launch_job.sh -f -v'

With no arguments -- how BCM invokes it -- one job is submitted at a time, in
BENCHMARKS order, and no job re-runs inside its own hourly window.
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
## operator is standing there, and a name that resolves to no launcher would
## otherwise sweep nothing and exit looking like a healthy idle cycle.
## See docs/how-to/run-a-job-by-hand.md#running-a-job-that-is-not-in-the-list.
for _job in $TEST_LIST; do
    job_launcher "$_job" >/dev/null || {
        echo "ERROR: --test $_job: no $JOBS_DIR/$_job.sbatch or $JOBS_DIR/$_job.sh -- nothing was swept." >&2
        echo "       Available: $(job_list | sort -u | tr '\n' ' ')" >&2
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

## ── Extra environment for the jobs ────────────────────────────────────────
##
## An allowlist rather than a blocklist: the submission is built as a string and
## run through `su - $JOB_USER -c`, so a plausible typo like `NCCL_X=0;id` would
## run as root on 200+ nodes. Commas are out because --export is itself
## comma-separated. See docs/reference/settings.md#what-is-rejected.
## Two forms of the same allowlisted list: a comma-separated one for sbatch
## --export, and a space-separated one for the `NAME=VALUE ... bash launcher`
## prefix a host-launched job gets instead. See docs/explanation/sequencing.md#host-launched-jobs.
JOB_ENV_ARGS=""
JOB_ENV_PAIRS=()
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
    JOB_ENV_PAIRS+=("$_pair")
    JOB_ENV_NAMES+=("${_pair%%=*}")
done
unset _pair

## The site's paths, which a job running from Slurm's spool copy cannot work out
## for itself. Same allowlist as JOB_ENV, for the same reason -- the string is
## run by `su - $JOB_USER -c`. Empty is left to the job to diagnose.
## See docs/explanation/sequencing.md#what-a-submission-carries.
##
## SITE_EXPORT is the same list for the sbatch form: --export takes commas
## where a command line takes spaces.
SITE_ARGS=""
SITE_EXPORT=""
for _var in BRINGUP_HOME CONTAINER_DIR LLMB_INSTALL LLMB_BIN LLMB_HF LLMB_IMAGES; do
    _value="${!_var:-}"
    [[ -n "$_value" ]] || continue
    if [[ "$_value" =~ ^[A-Za-z0-9_.:/+@%=-]+$ ]]; then
        SITE_ARGS+=" $_var=$_value"
        SITE_EXPORT+=",$_var=$_value"
    else
        trace "WARNING: $_var contains characters outside [A-Za-z0-9_.:/+@%=-] -- dropped, and the job will refuse rather than run without it."
    fi
done
unset _var _value

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
## See docs/reference/layout.md#result-path-ownership.
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

## ── Hosts that are not compute nodes ──────────────────────────────────────
##
## Above every other gate, and not overridden by --test or --force: nothing
## below this can succeed on a host slurm will never schedule a job on.
## See docs/explanation/sequencing.md#a-host-that-is-not-a-compute-node.
if node_excluded "$HOSTNAME"; then
    node_mark_excluded "$logs" "EXCLUDE_NODES='$EXCLUDE_NODES' in ${SETTINGS_FILE:-<no settings file found>}"
    ensure_file_owned "$logs/$NOT_COMPUTE_MARKER"
    trace "EXIT: EXCLUDE_NODES='$EXCLUDE_NODES' in ${SETTINGS_FILE:-<no settings file found>} matches $HOSTNAME -- this host is not a compute node, so no jobs are submitted here and the reports leave it out. Neither --test nor --force opens this."
    exit 0
elif node_self_excluded; then
    node_mark_excluded "$logs" "self-detected: slurmctld is installed here and slurmd is not"
    ensure_file_owned "$logs/$NOT_COMPUTE_MARKER"
    trace "EXIT: $HOSTNAME runs slurmctld and has no slurmd, so it is a head node and slurm will never schedule a job on it -- no jobs submitted, and the reports leave it out. Name it in EXCLUDE_NODES to say so deliberately; delete $logs/$NOT_COMPUTE_MARKER if this is wrong."
    exit 0
fi
node_unmark_excluded "$logs"

## ── Which nodes this framework tests ──────────────────────────────────────
##
## Shell globs, not regexes: `ink40-dh4-*` is the form node names are written in
## everywhere else, and as an ERE it would match nothing and quietly stop the
## fleet. Empty means every node.
## See docs/reference/settings.md#restricting-which-nodes-run-jobs.
node_in_scope() {
    local pat
    [[ -z "${NODE_FILTER// /}" ]] && return 0
    for pat in $NODE_FILTER; do
        # shellcheck disable=SC2053  # a glob on the right is the whole point here
        [[ "$HOSTNAME" == $pat ]] && return 0
    done
    return 1
}

if ! node_in_scope; then
    ## --test names both a job and, by running here, a node, so it opens this;
    ## --force does not. A forced sweep is normally issued over pdsh across a
    ## whole rack, and that must not quietly test nodes the site excluded.
    ## See docs/reference/settings.md#restricting-which-nodes-run-jobs.
    if [[ -n "$TEST_LIST" ]]; then
        trace "NODE_FILTER='$NODE_FILTER' does not match $HOSTNAME, but --test $TEST_LIST names this node by running on it -- testing anyway. This node is outside the set the sequencer sweeps, so nothing here will be re-run on a cadence."
    elif [[ "$EXPLAIN" -eq 1 ]]; then
        trace "NODE_FILTER='$NODE_FILTER' does not match $HOSTNAME -- explaining anyway; a real cycle would stop here"
    else
        trace "EXIT: NODE_FILTER='$NODE_FILTER' in ${SETTINGS_FILE:-<no settings file found>} does not match $HOSTNAME -- no jobs submitted here.$([[ "$FORCE" -eq 1 ]] && printf ' --force does not override it: a forced sweep is usually a whole rack over pdsh, and this node is not in the set.') Health checks and reporting are unaffected."
        exit 0
    fi
fi

## The module load is local and contacts nothing, so it happens before the
## in-flight gate below -- which needs `scontrol`, and nothing else.
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

## The pass/fail rule, sourced here because the in-flight gate below needs it to
## tell a finished job from one still writing. See the header of verdict.sh.
if [[ ! -f "$PARSERS_DIR/verdict.sh" ]]; then
    trace "EXIT: $PARSERS_DIR/verdict.sh is missing -- it carries the pass/fail rule"
    trace "      for every job, and without it nothing can be judged. Refusing to run,"
    trace "      because treating that as 'no results yet' would requeue the whole"
    trace "      benchmark list on every node, every hour, forever."
    trace "      PARSERS=$PARSERS, from ${SETTINGS_FILE:-<no settings file found>}."
    exit 0
fi
source "$PARSERS_DIR/verdict.sh"

## ── What is in flight, asked without the controller ───────────────────────
##
## One job at a time per node, and the question "is it still going" is answered
## from the node itself rather than from slurmctld: `scontrol listjobs` contacts
## the local slurmstepd processes only. See docs/explanation/sequencing.md#one-job-at-a-time.
inflight="$logs/.in-flight"

## Tab separated, jobid first. Same shape as recover.log, for the same reason.
inflight_write() {
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" > "$inflight" 2>/dev/null ||
        trace "WARNING: could not write $inflight -- the next cycle will not know this job is out, and may submit another on top of it"
    ensure_file_owned "$inflight"
}
inflight_clear() { rm -f "$inflight" 2>/dev/null; }
inflight_read() {
    [[ -f "$inflight" ]] || return 1
    IFS=$'\t' read -r IF_JOBID IF_JOB IF_RUN IF_TOTAL IF_EPOCH < "$inflight" || return 1
    ## A marker we cannot read is worse than none: it would pin the node forever.
    [[ "$IF_JOBID" =~ ^[0-9]+$ && -n "$IF_JOB" && "$IF_EPOCH" =~ ^[0-9]+$ ]] && return 0
    trace "WARNING: $inflight is unreadable ('$IF_JOBID $IF_JOB $IF_EPOCH') -- discarded, and the node is treated as idle"
    inflight_clear
    return 1
}

## Every job running here, ours and everyone else's, from the local slurmstepds
## rather than slurmctld. `listjobs` prints a JOBID header then one bare id per
## line. See docs/explanation/sequencing.md#what-the-node-can-answer-by-itself.
local_job_ids() {
    scontrol listjobs 2>/dev/null | awk '/^[0-9]+$/ { print }'
}
job_running_locally() {
    local id
    for id in $(local_job_ids); do [[ "$id" == "$1" ]] && return 0; done
    return 1
}

## Whether the result file has been finished off, which is what says the job
## ended -- sbatch creates it at start, so its existence says nothing and its
## absence says the job has not started, not that it is over. NOT_RUN is
## excluded for that reason, and the marker outlives a job that is still queued.
## See docs/explanation/sequencing.md#a-missing-result-file-is-not-a-finished-job.
result_complete() {
    verdict "$IF_JOB" "$1"
    [[ "$VERDICT_STATUS" != "INCOMPLETE" && "$VERDICT_STATUS" != "NOT_RUN" ]]
}

## Move a result aside so the slot is free for the next attempt; the archives
## double as the attempt history. Two suffixes because status-check.sh reads the
## name as a verdict -- it counts .fail<N> as rejections, and a pass that --all
## re-runs is not one. See docs/explanation/sequencing.md.
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

## The reason Slurm gives a job it gave up launching. Defined rather than
## inlined because an empty pattern matches every job, and the branch it guards
## cancels. See docs/explanation/sequencing.md#jobs-the-scheduler-has-given-up-on.
LAUNCH_FAILED_HELD='launch failed requeued held'

## ── Getting out of the way ────────────────────────────────────────────────
##
## Somebody else queued for this node outranks a benchmark of ours already
## running on it. Every check that stands between "a job is waiting" and a
## scancel is in the library, which never cancels an id the controller has not
## confirmed is ours. See docs/explanation/sequencing.md#getting-out-of-the-way.
YIELD_TRACE=""
yield_ready=0
if setting_enabled "$GET_OUT_OF_THE_WAY"; then
    if [[ -f "$home/get-out-of-the-way.sh" ]]; then
        yield_log() { trace "$@"; }
        ## SC2034: read by get-out-of-the-way.sh, sourced below, which
        ## shellcheck cannot see from here. `export` would put them in every
        ## job's environment. Repeated because it covers one assignment.
        # shellcheck disable=SC2034
        YIELD_OURS="$JOB_NAME_BENCH $JOB_NAME_BURNIN"
        # shellcheck disable=SC2034
        YIELD_USER="$JOB_USER"
        YIELD_STAMP="$logs/.yield-check"
        # shellcheck disable=SC2034
        YIELD_DRY_RUN="$EXPLAIN"
        source "$home/get-out-of-the-way.sh"
        yield_ready=1
    else
        trace "WARNING: GET_OUT_OF_THE_WAY=$GET_OUT_OF_THE_WAY but $home/get-out-of-the-way.sh is missing -- this node will never give itself up. Stale deployment?"
    fi
fi

## True only when our job was cancelled. Everything else leaves YIELD_TRACE for
## the line the caller was going to write anyway: a node that decided to stay
## has to say what it decided.
yield_job() {
    local rc=1
    YIELD_TRACE=""
    [[ "$yield_ready" -eq 1 ]] || return 1
    yield_to_waiter "$1" "$HOSTNAME" && rc=0
    ensure_file_owned "$YIELD_STAMP"
    [[ "$rc" -eq 0 ]] && return 0
    case "$YIELD_RESULT" in
        no-waiter)      YIELD_TRACE="nobody else is queued for $HOSTNAME" ;;
        would-yield)    YIELD_TRACE="--explain: nothing cancelled" ;;
        polled-recently|disabled|no-job) ;;
        *)              YIELD_TRACE="staying put: $YIELD_RESULT${YIELD_WAITER:+, with $YIELD_WAITER}" ;;
    esac
    return 1
}

## ── Node state, and only when something needs it ──────────────────────────
##
## The one thing a node cannot answer about itself: State and Reason live in
## slurmctld. Fetched lazily and cached, so a healthy cycle never asks.
## See docs/explanation/sequencing.md#what-the-node-can-answer-by-itself.
## NODE_ASKED separates "not fetched yet" from "fetched and got nothing", so a
## controller that timed out is not asked again on every call in the same run.
NODE_INFO=""
NODE_ASKED=0
state=""
node_info() {
    [[ "$NODE_ASKED" -eq 1 ]] && { [[ -n "$NODE_INFO" ]]; return; }
    NODE_ASKED=1
    NODE_INFO=$(scontrol show node "$HOSTNAME" 2>/dev/null)
    [[ -n "$NODE_INFO" ]] || return 1
    state=$(grep -oE 'State=[^ ]+' <<<"$NODE_INFO" | head -1 | cut -d= -f2)
    [[ -n "$state" ]]
}
## Reason is free text with spaces, and runs to the end of its line.
node_reason() {
    node_info || return 1
    grep -oE 'Reason=.*' <<<"$NODE_INFO" | head -1 | cut -d= -f2-
}


## ── Drains Slurm set itself ───────────────────────────────────────────────
##
## Only the `machine` class -- every other drain belongs to whoever set it.
## Above the PAUSE_JOBS gate and governed by PAUSE_RECOVERY instead: putting a
## node back is not putting work on it. The state is re-read rather than
## assumed. See docs/reference/settings.md#pause-switches.
## --explain reads through this the same way it reads through PAUSE_JOBS: a
## dry-run recovery issues no scontrol, restarts no slurmd and records no
## attempt, so the pause has nothing to protect it from.
## Called from inside the in-flight gate as well as after it; a node stuck
## behind its own undelivered job would otherwise never reach it. See
## docs/explanation/sequencing.md#a-queued-job-must-not-outrank-a-drain.
recovery_ran=0
recover_slurm_drains() {
    local recovery_paused=0
    [[ "$recovery_ran" -eq 1 ]] && return 0
    recovery_ran=1

    if setting_enabled "$PAUSE_RECOVERY"; then
        if [[ "$EXPLAIN" -eq 1 ]]; then
            trace "PAUSE_RECOVERY=$PAUSE_RECOVERY in ${SETTINGS_FILE:-<none>} -- explaining anyway; nothing below would be resumed while it is set"
        else
            trace "recovery paused: PAUSE_RECOVERY=$PAUSE_RECOVERY in ${SETTINGS_FILE:-<none>} -- drains Slurm set itself are left exactly where they are"
            recovery_paused=1
        fi
    fi

    if [[ "$recovery_paused" -eq 1 ]]; then
        :
    elif [[ -n "${inflight_overrun:-}" ]]; then
        ## The only way to reach here with a job of ours still on the node. It is
        ## drained below, and recovery would do nothing but hold on it.
        :
    elif [[ -f "$home/slurm-recovery.sh" ]]; then
        recover_log() { trace "$@"; }
        ## SC2034: read by slurm-recovery.sh, sourced below, which shellcheck
        ## cannot follow from inside a function. `export` would put them in
        ## every job's environment. Repeated: it covers one assignment.
        # shellcheck disable=SC2034
        RECOVER_ACCEPT="machine"
        RECOVER_LOG="$logs/recover.log"
        # shellcheck disable=SC2034
        RECOVER_DRY_RUN="$EXPLAIN"
        source "$home/slurm-recovery.sh"
        if slurm_recover_node "$HOSTNAME"; then
            [[ "$EXPLAIN" -eq 1 ]] || { NODE_INFO=""; NODE_ASKED=0; node_info; }
            ensure_file_owned "$RECOVER_LOG"
            trace "state after recovery=$(printf '%s' "$state" | tr '\n' ',')"
        fi
    else
        ## Named rather than skipped quietly: the tell for a deployment predating
        ## the file, whose absence is otherwise invisible -- nodes just stay drained.
        trace "WARNING: $home/slurm-recovery.sh is missing -- drains set by Slurm itself (prolog, rogue process, no reason) will not be cleared. Stale deployment?"
    fi
}


## ── The in-flight gate ────────────────────────────────────────────────────
##
## Four answers, and only the last costs a query. Every branch prefers waiting
## to submitting. See docs/explanation/sequencing.md#one-job-at-a-time.
if inflight_read; then
    if_file=$(result_file "$IF_JOB" "$IF_RUN" "$IF_TOTAL")
    if_age=$(( $(date +%s) - IF_EPOCH ))

    ## Asked once and remembered: the answer is used twice below, and even a
    ## local query is a process spawn per node per cycle.
    if_running=0; job_running_locally "$IF_JOBID" && if_running=1

    if [[ "$if_running" -eq 1 && "$if_age" -lt $(( MAX_JOB_HOURS * 3600 )) ]]; then
        if yield_job "$IF_JOBID"; then
            ## The result file is left where it is: an interrupted run is
            ## already INCOMPLETE, and the resubmission archives it as the
            ## previous attempt like any other. See
            ## docs/explanation/sequencing.md#getting-out-of-the-way.
            inflight_clear
            trace "EXIT: $IF_JOB run $IF_RUN (job $IF_JOBID) cancelled after ${if_age}s to free $HOSTNAME; it is re-queued once the node is free again"
            exit 0
        fi
        trace "EXIT: $IF_JOB run $IF_RUN (job $IF_JOBID) running here for ${if_age}s -- ${YIELD_TRACE:-slurmctld not asked}"
        exit 0
    elif [[ "$if_running" -eq 1 ]]; then
        ## Still going, but past the limit. The only branch that reads on: the
        ## drain needs the node state, which costs the one query below.
        ## See docs/explanation/sequencing.md#retry-and-drain-behaviour.
        inflight_overrun="job timeout after $(( if_age / 3600 ))h (RUNNING, job $IF_JOBID)"
    elif result_complete "$if_file"; then
        trace "$IF_JOB run $IF_RUN (job $IF_JOBID) finished after ${if_age}s: $VERDICT_STATUS${VERDICT_REASON:+ -- $VERDICT_REASON}"
        inflight_clear
    elif [[ "$if_age" -lt $(( INFLIGHT_GRACE_MINUTES * 60 )) ]]; then
        ## Not started yet, most likely queued behind somebody. Believed without
        ## asking: the alternative is a query per node per cycle while it waits.
        ## Recovery still runs -- a drain on this node is why it may never start.
        recover_slurm_drains
        trace "EXIT: $IF_JOB run $IF_RUN (job $IF_JOBID) submitted ${if_age}s ago, not running here yet -- waiting; slurmctld not asked"
        exit 0
    elif [[ "$EXPLAIN" -eq 1 ]]; then
        trace "WOULD ASK squeue about job $IF_JOBID -- $IF_JOB run $IF_RUN is ${if_age}s old, past the ${INFLIGHT_GRACE_MINUTES}m grace"
        inflight_clear
    else
        ## The one place the controller is asked on a quiet node, and the only
        ## thing that can tell "queued behind a long job" from "gone".
        ## %r last: a Slurm reason is free text with spaces in it. stderr is
        ## kept rather than discarded, because it carries the only thing that
        ## tells "this job is gone" from "the controller did not answer", and
        ## both print nothing on stdout.
        ## See docs/explanation/sequencing.md#when-the-controller-does-not-answer.
        if_queued=$(squeue -h -j "$IF_JOBID" -o '%T %r' 2>&1)
        if_rc=$?
        if [[ "$if_rc" -ne 0 || "$if_queued" == *"error:"* ]]; then
            if [[ "$if_queued" == *"Invalid job id"* ]]; then
                ## Slurm has forgotten the job entirely: it is gone, and the
                ## branch below is the right one.
                if_queued=""
            else
                recover_slurm_drains
                trace "EXIT: 'squeue -j $IF_JOBID' would not answer, so it is not known whether $IF_JOB run $IF_RUN is still queued -- the marker is kept and nothing is archived or resubmitted: ${if_queued:-<no output>}"
                exit 0
            fi
        fi
        if [[ -n "$if_queued" ]]; then
            ## A job held after a failed launch reads as PENDING at priority 0
            ## and never starts, so waiting on it waits forever. Ours by
            ## construction -- the marker holds the id we submitted.
            ## See docs/explanation/sequencing.md#jobs-the-scheduler-has-given-up-on.
            if [[ -n "$LAUNCH_FAILED_HELD" && "$if_queued" == *"$LAUNCH_FAILED_HELD"* ]]; then
                if_out=$(scancel "$IF_JOBID" 2>&1)
                trace "CANCELLED $IF_JOBID -- $IF_JOB run $IF_RUN held after a failed launch ('$LAUNCH_FAILED_HELD') for ${if_age}s; the next cycle resubmits${if_out:+ -- $if_out}"
                inflight_clear
            else
                recover_slurm_drains
                trace "EXIT: $IF_JOB run $IF_RUN (job $IF_JOBID) still queued after ${if_age}s -- left alone ($if_queued); 'scancel $IF_JOBID && rm $inflight' to give up on it"
                exit 0
            fi
        else
        ## Gone without finishing its result file: cancelled, killed, or the
        ## node was drained under it. Archived so the slot is free and the
        ## attempt is still on disk. See docs/explanation/sequencing.md#when-a-marker-goes-stale.
            trace "$IF_JOB run $IF_RUN (job $IF_JOBID) is gone from the queue after ${if_age}s with no end marker -- archiving the partial result and moving on"
            [[ -f "$if_file" ]] && archive_result "$if_file" fail
            inflight_clear
        fi
    fi
fi

## Every path that leaves the gate without exiting arrives here.
recover_slurm_drains

## ── Pause ─────────────────────────────────────────────────────────────────
##
## A pause has to reach the queue too, or it is not a pause: pending jobs are
## cancelled, a running one is left to finish, and only our two job names are
## ever touched. `--explain` reads through it -- see
## docs/reference/settings.md#pause-switches.
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

    ## Its own names, not `state`: this loop is at the top level, and `$state`
    ## is the node's, read above and relied on by the drain gate further down.
    ## Reading through this block under --explain is what made that reachable.
    while read -r paused_id paused_state paused_elapsed; do
        [[ "$paused_state" == "RUNNING" ]] || continue
        trace "PAUSE_JOBS: job $paused_id still RUNNING for $paused_elapsed -- left to finish; 'scancel $paused_id' to stop it now"
    done <<<"$paused_queue"

    [[ "$FORCE" -eq 1 ]] &&
        trace "--force does not override PAUSE_JOBS: it is a site switch, not a timing gate. Set PAUSE_JOBS=no in ${SETTINGS_FILE:-SETTINGS} to sweep."

    ## --explain reads on: every write below it is already guarded, and the
    ## question it answers -- what would a sweep do here -- is one worth being
    ## able to ask precisely when the sweep is stopped.
    if [[ "$EXPLAIN" -eq 1 ]]; then
        trace "PAUSE_JOBS=$PAUSE_JOBS in ${SETTINGS_FILE:-<no settings file found>} -- explaining anyway; nothing below would run while it is set"
    else
        trace "EXIT: PAUSE_JOBS=$PAUSE_JOBS in ${SETTINGS_FILE:-<no settings file found>} -- no submissions, no drains"
        exit 0
    fi
fi

## Drain only a node that is currently usable; anything already drained is left
## alone. DRAIN_AFTER_FAILED_BENCHMARK=no suppresses every drain here, including
## the timeout one, but still traces it. See docs/reference/settings.md#drains.
drain_node() {
    local reason="$1"
    ## A hand-run of a job the fleet is not judged on cannot take the node out.
    ## See docs/how-to/run-a-job-by-hand.md#running-a-job-that-is-not-in-the-list.
    [[ -n "$TEST_LIST" ]] && {
        trace "drain suppressed by --test: $reason"
        return 0
    }
    setting_enabled "$DRAIN_AFTER_FAILED_BENCHMARK" || {
        trace "drain suppressed by DRAIN_AFTER_FAILED_BENCHMARK=$DRAIN_AFTER_FAILED_BENCHMARK: $reason"
        return 0
    }
    ## No answer is not an answer. A busy controller returns nothing, and draining
    ## on that would take out a node on no information -- and overwrite an
    ## operator's drain reason with ours. The failure this guards against is real
    ## and observed: under load the same query makes `sinfo -N -n` return empty.
    ## See docs/explanation/sequencing.md#when-the-controller-does-not-answer.
    if ! node_info; then
        trace "drain skipped, the controller did not answer 'scontrol show node $HOSTNAME' -- not draining on an unknown state: $reason"
        return 0
    fi
    case "$state" in
        *DRAIN*|*DOWN*|*FAIL*|*MAINT*) trace "drain skipped, already $state: $reason"; return 0 ;;
    esac
    trace "DRAIN: $reason"
    [[ "$EXPLAIN" -eq 1 ]] && return 0
    scontrol update nodename="$HOSTNAME" state=DRAIN reason="$reason"
}

## Clear only our own drain — the marker is what makes this safe.
resume_node() {
    local current
    current=$(node_reason)
    [[ "$current" == *"$DRAIN_MARKER"* ]] || return 0
    trace "RESUME: clearing own drain ($current)"
    [[ "$EXPLAIN" -eq 1 ]] && return 0
    scontrol update nodename="$HOSTNAME" state=RESUME
}

## The job that outran MAX_JOB_HOURS in the in-flight gate above. Drained here
## because drain_node needs both its own definition and the node state, and
## neither exists that early. See docs/explanation/sequencing.md#retry-and-drain-behaviour.
if [[ -n "${inflight_overrun:-}" ]]; then
    drain_node "$inflight_overrun"
    exit 0
fi

## Anything running here that is not our own marker's id is somebody else's.
## `squeue -w` was asking slurmctld for what slurmd already knew.
foreign=$(local_job_ids | grep -vx "${IF_JOBID:--}" | tr '\n' ' ')
foreign="${foreign% }"

if [[ -n "$foreign" ]]; then
    trace "EXIT: job(s) not ours running on $HOSTNAME ($foreign) -- leaving the node to them"
    exit 0
fi

## Reaching here means the marker said nothing is out, so both lists are idle by
## construction. The variables survive because quick-view.txt still distinguishes
## a job in flight from one merely waiting its turn.
bench_busy=0
burnin_busy=0

## ── Survey what has and has not passed ────────────────────────────────────
## A job passes when verdict() returns DONE for every run. The verdict is
## re-derived from the log on every sweep rather than read from a marker the
## sbatch left, so a result that passed an older, looser gate does not keep its
## pass forever. See the header of verdict.sh.

declare -a pending_jobs=()
declare -a failed_jobs=()
declare -a surveyed_jobs=()
declare -A fail_reasons=()
newest_result=0
swept=1
## Survey one list. pending_jobs / failed_jobs / swept reset on each call;
## fail_reasons and newest_result accumulate, being keyed by job or
## properties of the node.
##
## $2 is whether this list is in the queue. If it is, the survey still runs --
## quick-view has to say something about every job -- but its per-run failure
## lines are not traced: "INCOMPLETE" once a cycle for six hours reads as a node
## failing when it is a node working. See docs/explanation/sequencing.md#two-lists.
survey() {
    local list="$1" busy="${2:-0}" job launch totalRuns passed attempted failed r file mtime

    pending_jobs=()
    failed_jobs=()
    surveyed_jobs=()
    swept=1

for job in $list; do
    ## A listed benchmark with no launcher behind it drops out of the sweep
    ## entirely and would otherwise never show up as missing. Worth a line --
    ## including the case where the .sh is there but carries no job_launch=host,
    ## which looks identical from the outside and is the likelier mistake.
    launch=$(job_launcher "$job") || {
        if [[ -f "$JOBS_DIR/$job.sh" ]]; then
            trace "skip $job: $JOBS_DIR/$job.sh has no 'job_launch=host' line -- a .sh without it is read as a sourced helper, not a job."
        else
            trace "skip $job: no $JOBS_DIR/$job.sbatch or $JOBS_DIR/$job.sh"
        fi
        continue
    }
    ## What --all can re-queue. Built here rather than from $list, so a forced
    ## sweep cannot pend a job that has nothing to submit.
    surveyed_jobs+=("$job")

    totalRuns=$(job_total_runs "$launch")

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
## Set only once something has actually been submitted, so "IN FLIGHT" in
## quick-view.txt means a job id exists and the marker records it.
IN_FLIGHT_JOB=""
write_quickview() {
    local job reason
    ## The file describes the BENCHMARKS and BURNIN lists, which a --test run
    ## has not surveyed -- writing it here would report every real column as
    ## QUEUED. See docs/how-to/run-a-job-by-hand.md#running-a-job-that-is-not-in-the-list.
    [[ -n "$TEST_LIST" ]] && return 0
    {
        for job in $BENCHMARKS; do
            if [[ "$job" == "$IN_FLIGHT_JOB" ]]; then
                echo "$job: IN FLIGHT"
            elif ! in_list "$job" "${bench_pending[@]}"; then
                echo "$job: DONE"
            else
                reason="${fail_reasons[$job]:-${forced_reason}}"
                echo "$job: QUEUED${reason:+  <- $reason}"
            fi
        done
        for job in $BURNIN; do
            if ! setting_enabled "$RUN_BURNIN"; then
                echo "$job: BURN-IN OFF  <- RUN_BURNIN=$RUN_BURNIN"
            elif [[ "$job" == "$IN_FLIGHT_JOB" ]]; then
                echo "$job: IN FLIGHT"
            elif ! in_list "$job" "${burn_pending[@]}"; then
                echo "$job: DONE"
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
## rather than a gate. See docs/explanation/sequencing.md#two-lists.
##
## --all widens `pending` to every job in the list, and only that -- the failure
## and sweep bookkeeping keeps reading the results on disk, so a forced re-sweep
## neither invents a failure nor clears one.
##
## --test replaces the list outright rather than adding to it, so a run asked
## for one job submits one job. See
## docs/how-to/run-a-job-by-hand.md#running-a-job-that-is-not-in-the-list.
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

## The "waiting on our own queue" gate that used to sit here is gone: the
## in-flight marker answers that question above, before any query, and a node
## that has a job out never reaches this far.

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
## See docs/explanation/sequencing.md#retry-and-drain-behaviour.

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

## Every job of ours the controller is holding, in one call: this node's two
## names gate the submission below, and the fleet-wide count of both prefixes
## gates it against MAX_QUEUED_JOBS. Still one query, which is the number that
## costs. See docs/explanation/sequencing.md#the-guard-before-a-submission.
##
## Sets QUEUED_OURS rather than printing it, and so must never be called as
## $(queued_ours) -- a subshell would cache the answer in a child and ask again.
## Same reason verdict() works the way it does.
##
## Returns 1 when the controller would not answer. A refused query prints
## nothing, which is indistinguishable from an empty queue at exactly the moment
## it matters -- and reading it as "nothing of ours is out" is what puts a second
## job on a node that already has one.
## See docs/explanation/sequencing.md#when-the-controller-does-not-answer.
QUEUED_OURS=""
QUEUED_FLEET=0
QUEUED_ASKED=0
QUEUED_FAILED=""
queued_ours() {
    [[ "$QUEUED_ASKED" -eq 1 ]] && { [[ -z "$QUEUED_FAILED" ]]; return; }
    QUEUED_ASKED=1
    local queue rc
    queue=$(squeue -h -o '%i %j' 2>&1)
    rc=$?
    if [[ "$rc" -ne 0 || "$queue" == *"error:"* ]]; then
        QUEUED_FAILED="${queue:-<no output>}"
        return 1
    fi
    QUEUED_OURS=$(awk -v b="$JOB_NAME_BENCH" -v u="$JOB_NAME_BURNIN" \
                      '$2 == b || $2 == u { print $1 }' <<<"$queue" | sort -u)
    QUEUED_FLEET=$(awk -v p="${JOB_NAME_BENCH%"$HOSTNAME"}" -v q="${JOB_NAME_BURNIN%"$HOSTNAME"}" \
                       '$2 ~ "^(" p "|" q ")" { n++ } END { print n+0 }' <<<"$queue")
    return 0
}

## ── The next job, and only the next one ───────────────────────────────────
##
## Cadence is per job, not per node: eligible means not passed, and its own
## result missing or older than RETRY_INTERVAL_HOURS. The sweep advances as fast
## as jobs finish while no one job re-runs inside the hour.
## See docs/explanation/sequencing.md#one-job-at-a-time.
##
## With RETRY_BACKOFF on that window widens by an hour per failure already on
## disk, up to RETRY_BACKOFF_MAX_HOURS. It delays and never gives up; what takes
## a node out is the drain, which is a separate decision and does not read this.
## See docs/explanation/sequencing.md#backing-off-a-job-that-keeps-failing.
##
## Sets RETRY_WINDOW and RETRY_FAILS rather than printing them: a subshell would
## lose the count the trace reports. Same reason verdict() works the way it does.
RETRY_WINDOW=0
RETRY_FAILS=0
RETRY_BACKOFF_WARNED=0
retry_window() {
    local file="$1" base cap
    RETRY_WINDOW=$(( RETRY_INTERVAL_HOURS * 3600 ))
    RETRY_FAILS=0
    setting_enabled "$RETRY_BACKOFF" || return 0

    cap=0
    [[ "$RETRY_BACKOFF_MAX_HOURS" =~ ^[0-9]+$ ]] && cap=$(( RETRY_BACKOFF_MAX_HOURS * 3600 ))
    if [[ "$cap" -lt "$RETRY_WINDOW" ]]; then
        [[ "$RETRY_BACKOFF_WARNED" -eq 0 ]] &&
            trace "WARNING: RETRY_BACKOFF=$RETRY_BACKOFF but RETRY_BACKOFF_MAX_HOURS='$RETRY_BACKOFF_MAX_HOURS' in ${SETTINGS_FILE:-<no settings file found>} is not a whole number of hours at or above RETRY_INTERVAL_HOURS=$RETRY_INTERVAL_HOURS -- backoff ignored, and every job keeps the flat ${RETRY_INTERVAL_HOURS}h window."
        RETRY_BACKOFF_WARNED=1
        return 0
    fi

    ## The attempt history is the archives plus the failure on disk now -- the
    ## file this was called for, which next_eligible has already judged not DONE.
    ## ls|grep for the same reason as archive_result().
    base=$(basename "$file" .txt)
    # shellcheck disable=SC2010
    RETRY_FAILS=$(( $(ls "$logs" 2>/dev/null | grep -cE "^${base}\.fail[0-9]+\.txt$") + 1 ))
    RETRY_WINDOW=$(( RETRY_WINDOW + (RETRY_FAILS - 1) * 3600 ))
    [[ "$RETRY_WINDOW" -gt "$cap" ]] && RETRY_WINDOW=$cap
    return 0
}

## Named here so both surveys accumulate into one line, whichever list holds the
## job that was held back.
declare -a backoff_held=()

NEXT_JOB=""; NEXT_RUN=""; NEXT_TOTAL=""
next_eligible() {
    local list="$1" job launch total r file mtime now
    now=$(date +%s)
    for job in $list; do
        launch=$(job_launcher "$job") || continue
        total=$(job_total_runs "$launch")
        for ((r = 1; r <= total; r++)); do
            file=$(result_file "$job" "$r" "$total")
            if [[ -f "$file" ]]; then
                verdict "$job" "$file"
                [[ "$VERDICT_STATUS" == "DONE" && "$FORCE_ALL" -eq 0 ]] && continue
                mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
                if [[ "$FORCE" -eq 0 ]]; then
                    retry_window "$file"
                    if [[ $(( now - mtime )) -lt "$RETRY_WINDOW" ]]; then
                        [[ "$RETRY_FAILS" -gt 1 ]] &&
                            backoff_held+=("$job run $r after $RETRY_FAILS failures: $(( RETRY_WINDOW / 3600 ))h window, $(( (RETRY_WINDOW - now + mtime + 59) / 60 ))m left")
                        continue
                    fi
                fi
            fi
            NEXT_JOB="$job"; NEXT_RUN="$r"; NEXT_TOTAL="$total"
            return 0
        done
    done
    return 1
}

## ── Queue every non-passing job, in listed order ──────────────────────────

## No drain check here any more: it existed to stop a whole list landing on a
## node the moment an operator resumed it, and one job is not a dump. A job sent
## to a drained node pends, and the stale branch says why.
## See docs/explanation/sequencing.md#what-the-node-can-answer-by-itself.
resume_node

## Queue priority is NOT set here: each job carries its own `#SBATCH --nice`, so
## a hand-submitted job sits where a sequencer-submitted one would. This script
## decides only *what* to submit. See docs/reference/jobs.md#queue-priority.
##
## One run of one job, and the id it was given is the whole point of the return:
## it is what the marker records and what the next cycle asks slurmstepd about.
SUBMITTED_ID=""
submit_one() {
    local jname="$1" job="$2" r="$3" totalRuns="$4"
    local launch file submit out rc kind name pre_ids extra
    SUBMITTED_ID=""
    launch=$(job_launcher "$job") || return 1
    file=$(result_file "$job" "$r" "$totalRuns")

    ## Two launchers for one name is a half-finished conversion, and the loser
    ## is otherwise dropped in silence. See docs/explanation/sequencing.md#host-launched-jobs.
    [[ "$launch" == *.sbatch && -f "$JOBS_DIR/$job.sh" ]] &&
        trace "NOTE: $job has both a .sbatch and a .sh -- the .sbatch is what runs."

    ## The job file wins when both name a variable, which is right -- but the
    ## override was invisible, so a SETTINGS line that did nothing looked exactly
    ## like one that worked. See docs/explanation/sequencing.md#the-job-file-wins.
    for name in "${JOB_ENV_NAMES[@]}"; do
        grep -qE "^[[:space:]]*export[[:space:]]+$name=" "$launch" &&
            trace "NOTE: JOB_ENV sets $name, but ${launch##*/} exports its own -- the job file's value is what runs."
    done

    ## Under --all the verdict still decides which suffix the existing result is
    ## kept under, even though it no longer decides whether to run. See
    ## archive_result.
    kind=fail
    verdict "$job" "$file"
    [[ "$VERDICT_STATUS" == "DONE" ]] && kind=prev

    ## -J must be passed here, not as an #SBATCH line -- those are comments, not
    ## shell, and would not expand $HOSTNAME. A host-launched job submits itself,
    ## so it is handed the same things by environment instead, and its id read
    ## back from the queue. See docs/explanation/sequencing.md#host-launched-jobs.
    if [[ "$launch" == *.sh ]]; then
        submit="source /etc/profile.d/modules.sh; module load slurm; \
mkdir -p $logs && SBATCH_JOB_NAME=$jname RESULT_FILE=$file$SITE_ARGS \
${JOB_ENV_PAIRS[*]} bash $launch"
    else
        submit="source /etc/profile.d/modules.sh; module load slurm; \
mkdir -p $logs && sbatch -w $HOSTNAME -J $jname \
--export=ALL,RESULT_FILE=$file$JOB_ENV_ARGS$SITE_EXPORT --output=$file $launch"
    fi

    ## The guard above already asked what was queued under our names, and the
    ## answer is cached -- this is the same question, not a second call.
    pre_ids=""
    [[ "$launch" == *.sh ]] && { queued_ours; pre_ids="$QUEUED_OURS"; }

    if [[ "$EXPLAIN" -eq 1 ]]; then
        trace "WOULD SUBMIT $job run $r$([[ -f "$file" ]] && printf ' (existing %s result kept as .%s<N>.txt)' "$VERDICT_STATUS" "$kind"): $([[ "$EUID" -eq 0 ]] && printf 'su - %s -c ' "$JOB_USER")\"$submit\""
        return 1
    fi

    archive_result "$file" "$kind"

    ## stderr is merged and kept: every way this fails looks identical from
    ## outside, and sbatch's own diagnosis is what tells them apart. Only how we
    ## arrive at $JOB_USER differs. See docs/how-to/run-a-job-by-hand.md.
    if [[ "$EUID" -eq 0 ]]; then
        out=$(su - "$JOB_USER" -c "$submit" 2>&1); rc=$?
    elif [[ "$(id -un)" == "$JOB_USER" ]]; then
        out=$(bash -lc "$submit" 2>&1); rc=$?
    else
        trace "SUBMIT FAILED $job run $r: running as $(id -un), which is neither root nor $JOB_USER -- 'su - $JOB_USER' would ask for a password. Run as root or as $JOB_USER."
        return 1
    fi

    if [[ "$launch" == *.sh ]]; then
        ## The id of what this launcher just submitted, by difference against
        ## what was queued under the name a moment ago. `head -1` here picked
        ## arbitrarily among everything sharing the name, which is how a stale
        ## job's id ended up in the marker.
        ## See docs/explanation/sequencing.md#getting-the-job-id-right.
        SUBMITTED_ID=$(comm -13 <(printf '%s' "${pre_ids:+$pre_ids$'\n'}") \
                                <(squeue -h -n "$jname" -o '%i' 2>/dev/null | sort -u))
        ## More than one is a launcher that submitted twice, or a leftover the
        ## snapshot missed. The extras are ours by name and unwanted either way.
        if [[ "$(grep -c . <<<"$SUBMITTED_ID")" -gt 1 ]]; then
            trace "WARNING: $launch left $(grep -c . <<<"$SUBMITTED_ID") jobs named $jname ($(tr '\n' ' ' <<<"$SUBMITTED_ID")) -- keeping the first and cancelling the rest, which would otherwise run this benchmark more than once"
            for extra in $(tail -n +2 <<<"$SUBMITTED_ID"); do scancel "$extra" 2>/dev/null; done
        fi
        SUBMITTED_ID=$(head -1 <<<"$SUBMITTED_ID")
        if [[ -n "$SUBMITTED_ID" ]]; then
            trace "submitted $job run $r (host-launched): job $SUBMITTED_ID${JOB_ENV_ARGS:+ (JOB_ENV:${JOB_ENV_ARGS//,/ })}"
            return 0
        fi
        trace "SUBMIT FAILED $job run $r: $launch exited $rc with no job named $jname in the queue -- if it submitted under its own name, that job is invisible to this node's gates and has to be scancelled by hand. Output: ${out:-<none>}"
        return 1
    fi

    if [[ "$out" == *"Submitted batch job"* ]]; then
        ## Not a trailing-digit strip: with -M the line ends "on cluster <name>",
        ## and warnings can follow the success line.
        SUBMITTED_ID=$(grep -oE 'Submitted batch job [0-9]+' <<<"$out" | tail -1 | grep -oE '[0-9]+$')
        ## The environment goes in the trace, not just the job id: when a result
        ## is questioned weeks later, SETTINGS says whatever it says then, so
        ## what the run was given has to be written down now.
        trace "submitted $job run $r: job $SUBMITTED_ID${JOB_ENV_ARGS:+ (JOB_ENV:${JOB_ENV_ARGS//,/ })}"
        return 0
    fi
    trace "SUBMIT FAILED $job run $r: ${out:-<no output>}"
    return 1
}

## Benchmarks first, then burn-in -- and only ever one. BENCHMARKS order is the
## run order now that nothing queues behind anything.
if next_eligible "${TEST_LIST:-$BENCHMARKS}"; then
    submit_target=bench
elif [[ -z "$TEST_LIST" ]] && setting_enabled "$RUN_BURNIN" && [[ -n "${BURNIN// /}" ]] &&
     [[ "${#bench_pending[@]}" -eq 0 ]] && next_eligible "$BURNIN"; then
    submit_target=burnin
else
    submit_target=""
fi

## One line for both lists, and only when a job is actually waiting out more
## than the flat window: a job held for 12h is otherwise indistinguishable from
## one nobody has listed. See docs/explanation/sequencing.md#backing-off-a-job-that-keeps-failing.
if [[ "${#backoff_held[@]}" -gt 0 ]]; then
    held=$(printf '%s; ' "${backoff_held[@]}")
    trace "backing off: ${held%; }"
fi

## Reaching here means no marker said a job was out. Asked once, immediately
## before submitting, because a marker can be missing while a job is not: a cycle
## killed between sbatch returning and the marker being written leaves one, and
## so does a marker deleted by hand. The job is PENDING at that point, so it is
## invisible to `scontrol listjobs` and only the controller knows.
## See docs/explanation/sequencing.md#the-guard-before-a-submission.
if [[ -n "$submit_target" && "$EXPLAIN" -eq 0 ]]; then
    if ! queued_ours; then
        ## The guard is the last thing between a lost marker and two jobs on one
        ## node, so a query that failed is a stop, not a pass.
        trace "EXIT: the queue could not be read, so it is not known whether a job of ours is already out -- $NEXT_JOB run $NEXT_RUN stays eligible rather than being submitted on a guess: $QUEUED_FAILED"
        write_quickview
        exit 0
    fi
    if [[ -n "$QUEUED_OURS" ]]; then
        queued_list="${QUEUED_OURS//$'\n'/ }"
        trace "EXIT: no marker, but $(grep -c . <<<"$QUEUED_OURS") job(s) of ours are already queued ($queued_list) -- not submitting $NEXT_JOB on top of one. Untracked, so it is left to finish; 'scancel $queued_list' to clear it."
        write_quickview
        exit 0
    fi
fi

## The fleet-wide ceiling. The gate above bounds this node to one job; nothing
## bounded every node holding one at once, which is what saturates slurmctld.
## See docs/explanation/sequencing.md#the-fleet-wide-cap.
if [[ -n "$submit_target" && -n "${MAX_QUEUED_JOBS// /}" && "$MAX_QUEUED_JOBS" != 0 ]]; then
    if [[ ! "$MAX_QUEUED_JOBS" =~ ^[0-9]+$ ]]; then
        trace "WARNING: MAX_QUEUED_JOBS='$MAX_QUEUED_JOBS' in ${SETTINGS_FILE:-<no settings file found>} is not a whole number -- ignored, and this cycle submits as if uncapped."
    else
        queued_ours
        if [[ "$QUEUED_FLEET" -ge "$MAX_QUEUED_JOBS" ]]; then
            cap_msg="MAX_QUEUED_JOBS=$MAX_QUEUED_JOBS reached -- $QUEUED_FLEET of our jobs are queued or running fleet-wide, so $NEXT_JOB run $NEXT_RUN stays eligible and is offered again next cycle."
            [[ "$FORCE" -eq 1 ]] && cap_msg="$cap_msg --force does not override it: it is a site switch, not a timing gate."
            if [[ "$EXPLAIN" -eq 1 ]]; then
                trace "$cap_msg -- explaining anyway; a real cycle would stop here"
            else
                trace "EXIT: $cap_msg"
                write_quickview
                exit 0
            fi
        else
            trace "fleet cap open: $QUEUED_FLEET of $MAX_QUEUED_JOBS jobs of ours queued or running"
        fi
    fi
fi

if [[ -n "$submit_target" ]]; then
    jname="$JOB_NAME_BENCH"
    [[ "$submit_target" == burnin ]] && jname="$JOB_NAME_BURNIN"
    if submit_one "$jname" "$NEXT_JOB" "$NEXT_RUN" "$NEXT_TOTAL"; then
        ## Checked before it is written, not after it is read back. A marker
        ## holding an unusable id is discarded next cycle, which leaves the node
        ## looking idle while the job is still out -- and it submits a second
        ## copy over the first. See docs/explanation/sequencing.md#getting-the-job-id-right.
        if [[ "$SUBMITTED_ID" =~ ^[0-9]+$ ]]; then
            inflight_write "$SUBMITTED_ID" "$NEXT_JOB" "$NEXT_RUN" "$NEXT_TOTAL" "$(date +%s)"
            IN_FLIGHT_JOB="$NEXT_JOB"
        else
            trace "WARNING: $NEXT_JOB run $NEXT_RUN was submitted but its job id did not parse ('$SUBMITTED_ID') -- no marker written. It will read as somebody else's job once it starts and hold the node until it ends; 'scancel -n $jname' to clear it."
        fi
    fi
else
    trace "nothing eligible to submit: everything is passing or inside its own retry window (${RETRY_INTERVAL_HOURS}h$(setting_enabled "$RETRY_BACKOFF" && printf ', plus an hour per failure to at most %sh' "$RETRY_BACKOFF_MAX_HOURS"))"
fi

## Reflect the newly queued state. Queued lines carry the reason the previous
## attempt was rejected, so this file answers "why is this node still being
## retested" on its own.
write_quickview
