#!/bin/bash
#
#

#[[ "$CMD_CATEGORY" == "spcx-hosts" ]] || exit 0

## Active single-node benchmark list. Everything without a passing result is
## queued once an hour, in the order listed here.
##
## Available single-node jobs in jobs/ (AI Factory Testing Plan, SNT tiers):
##   dcgm-r2                TTM DCGM gate      (dcgmi diag -r 2)
##   dcgm                   Hybrid DCGM gate   (dcgmi diag -r 3)
##   dcgm-r4                Exhaustive gate    (dcgmi diag -r 4)
##   nvbandwidth            HBM / PCIe / NVLink bandwidth
##   allreduce alltoall     NCCL single node, NVLink scope
##   allreduce-nonvlink     NCCL single node, no NVLink (HCA loopback)
##   alltoall-nonvlink      NCCL single node, no NVLink (HCA loopback)
##   nvsm                   NVSM stress (Hybrid / Exhaustive, DGX only)
##   stream memtester       CPU memory bandwidth + DRAM integrity (Exhaustive)
##   stress-ng              CPU stress (Exhaustive)
##   stressapptest          extended memory integrity (Exhaustive)
##   fio                    local NVMe / shared storage (Exhaustive)
##   ethr                   north-south management + storage NIC (Exhaustive)
##   nvloom                 MNNVL fabric (Exhaustive, optional/exploratory)
##   mnubergemm             burn-in (Hybrid / Exhaustive)
##   llm-pretrain           single-node LLM pre-training workload gate
##   hpl cublasmatmul       remediation-only single-node GEMM -- run by hand
##
## Pick the set matching the delivery methodology for the site.
## Default list holds only jobs whose dependencies are always available: dcgm
## uses a host binary, and the NCCL jobs use the hpc-benchmarks image, which
## build_containers.sh pulls from the public catalog. Jobs whose image has to be
## built or obtained (nvbandwidth, nvloom, mnubergemm) are covered in
## docs/containers.md and are added here once their image exists.
##
## nvsm is deliberately NOT in the default list: it is a DGX-only tool. It ships
## with DGX OS and only carries platform definition files for DGX platforms, so
## on anything else it exits before doing any work ("Failed to find a matching
## definition file for this platform") and fails identically on every node of
## that platform. In the list, that is a whole-cluster drain for a tool that was
## never going to run -- GPU stress is already covered by dcgm and mnubergemm.
##
## Add it back on a DGX site, where it also needs a passwordless sudoers grant
## on every compute node. Put it between the NVLink NCCL jobs and the no-NVLink
## ones so a fabric problem does not push a GPU stress test to the back of the
## queue -- nvsm has no fabric dependency and should report early:
##
##   benchmarks="dcgm allreduce alltoall nvsm allreduce-nonvlink alltoall-nonvlink"
##
## See docs/nvsm.md for both requirements.
benchmarks="dcgm allreduce alltoall allreduce-nonvlink alltoall-nonvlink"
MAX_JOB_HOURS=6

## Retry policy.
##
## Once an hour, every benchmark in the list above that does not have a passing
## result is queued, in listed order. Slurm runs them back to back on the node.
## There is no retry limit -- a node keeps being re-tested until it passes or an
## operator intervenes.
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
## Keep this above the BCM monitoring interval, or the drain is missed
## entirely, and well below RETRY_INTERVAL_HOURS.
RETRY_INTERVAL_HOURS=1
DRAIN_WINDOW_MINUTES=15
DRAIN_MARKER="auto-retry"

## set paths
home=/home/cmods/bringup
logs="$home/results/$HOSTNAME"
quickview="$logs/quick-view.txt"
tracelog="$logs/trigger.log"

## The account slurm jobs are submitted as. BCM runs this script as root on the
## node, so anything root creates under results/ has to be handed over -- see
## ensure_owned below.
JOB_USER=cmods

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
## `touch /home/cmods/bringup/NODRAIN` disables every drain this script would
## issue, including the MAX_JOB_HOURS timeout drain. Testing continues exactly
## as before — results are still recorded and failures still retry hourly — the
## node is just never taken out of service. Remove the file to re-enable.
drain_node() {
    local reason="$1"
    [[ -f "$home/NODRAIN" ]] && { trace "drain suppressed by NODRAIN: $reason"; return 0; }
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

## If a job is actively running or pending on this node, wait.
## Check elapsed time against MAX_JOB_HOURS and drain if stuck.
job_info=$(squeue -h -w "$HOSTNAME" -o '%M %T' 2>/dev/null | head -1)
if [[ -n "$job_info" ]]; then
    elapsed="${job_info%% *}"
    job_state="${job_info##* }"

    # Parse elapsed time — squeue formats: MM:SS, HH:MM:SS, D-HH:MM:SS
    elapsed_hours=0
    if [[ "$elapsed" =~ ^([0-9]+)-([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        elapsed_hours=$(( ${BASH_REMATCH[1]} * 24 + ${BASH_REMATCH[2]} ))
    elif [[ "$elapsed" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        elapsed_hours=${BASH_REMATCH[1]}
    fi

    if [[ "$elapsed_hours" -ge "$MAX_JOB_HOURS" ]]; then
        drain_node "benchmark timeout after ${elapsed_hours}h (${job_state})"
    fi
    trace "EXIT: job already on node, ${job_state} for ${elapsed} (limit ${MAX_JOB_HOURS}h)"
    exit 0
fi

## ── Survey what has and has not passed ────────────────────────────────────
## A job passes when verdict() returns DONE for every one of its runs. Anything
## else — FAIL, truncated output from a crashed node, or no file at all — is not
## a pass and gets queued again on the next sweep.
##
## The verdict is derived from the log here, on every sweep, rather than read
## from a marker the sbatch wrote at run time. That is deliberate: a result
## judged by an older, looser gate is re-judged by the current one instead of
## keeping its original pass forever. See the header of verdict.sh.

if [[ ! -f "$home/verdict.sh" ]]; then
    trace "EXIT: $home/verdict.sh is missing -- it carries the pass/fail rule for"
    trace "      every job, and without it nothing can be judged. Refusing to run,"
    trace "      because treating that as 'no results yet' would requeue the whole"
    trace "      benchmark list on every node, every hour, forever."
    exit 0
fi
source "$home/verdict.sh"

declare -a pending_jobs=()
declare -a failed_jobs=()
declare -A job_runs=()
declare -A fail_reasons=()
newest_result=0
swept=1

for job in $benchmarks; do
    launch="$home/jobs/$job.sbatch"
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
        ## No job is running on this node by the time we get here -- the squeue
        ## check above exits early if one is -- so an unterminated file is a
        ## dead job, not one still being written.
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

## ── Everything passing — nothing left to do ───────────────────────────────

trace "survey: pending=[${pending_jobs[*]}] failed=[${failed_jobs[*]}] swept=$swept"

if [[ "${#pending_jobs[@]}" -eq 0 ]]; then
    printf '%s: DONE\n' $benchmarks > "$quickview"
    resume_node
    trace "EXIT: every benchmark passing"
    exit 0
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
if [[ "$swept" -eq 1 && "${#failed_jobs[@]}" -gt 0 && \
      "$age" -ge 0 && "$age" -lt $(( DRAIN_WINDOW_MINUTES * 60 )) ]]; then
    first_reason="${fail_reasons[${failed_jobs[0]}]}"
    drain_node "${failed_jobs[*]} FAIL${first_reason:+: $first_reason} ($DRAIN_MARKER)"
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

for job in "${pending_jobs[@]}"; do
    launch="$home/jobs/$job.sbatch"
    totalRuns=${job_runs["$job"]}

    for ((r = 1; r <= totalRuns; r++)); do
        file=$(result_file "$job" "$r" "$totalRuns")
        ## Judged by the current gate, not by whatever marker the sbatch left
        ## behind. A run that passed an older, looser gate is re-queued here --
        ## which is the whole point, and is what the old `tail -1 == DONE` test
        ## structurally could not do.
        verdict "$job" "$file"
        [[ "$VERDICT_STATUS" == "DONE" ]] && continue

        ## Every benchmark for a node is submitted under one shared Slurm job
        ## name so --dependency=singleton serializes them: a job waits until
        ## every earlier job of the same name and user has terminated. Without
        ## it the whole batch is eligible at once, and a GPU job landing on top
        ## of dcgm's stress plugins fails on buffer allocation -- nccl-tests
        ## reports that as `Cuda failure 2 'out of memory'` after NCCL init has
        ## already succeeded. The CPU-only jobs (stream, stressapptest) skew
        ## collective timings the same way without ever touching a GPU.
        ##
        ## The hostname belongs in the name. Singleton matches on name alone,
        ## cluster-wide, so a bare `bringup` would serialize every node in the
        ## rack against every other and turn a parallel bringup into a queue of
        ## one. This also has to be passed here rather than as an #SBATCH line:
        ## those are comments, not shell, and would not expand $HOSTNAME.
        submit="source /etc/profile.d/modules.sh; module load slurm; \
mkdir -p $logs && sbatch -w $HOSTNAME -J bringup-$HOSTNAME --dependency=singleton \
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

## Reflect the newly queued state for anyone reading quick-view directly
## Queued lines carry the reason the previous attempt was rejected, so this file
## answers "why is this node still being retested" on its own.
{
    for job in $benchmarks; do
        if printf '%s\n' "${pending_jobs[@]}" | grep -Fxq "$job"; then
            reason="${fail_reasons[$job]}"
            echo "$job: QUEUED${reason:+  <- $reason}"
        else
            echo "$job: DONE"
        fi
    done
} > "$quickview"
