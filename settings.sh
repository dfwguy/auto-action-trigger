#!/bin/bash
#
# Loads the framework settings: SETTINGS if it exists, else SETTINGS.default,
# then backfills any key neither set. See docs/reference/settings.md.
#
# Set `home` (or SETTINGS_HOME) before sourcing. SETTINGS_FILE is left holding
# the path that was read, or empty if neither was found -- not fatal, since the
# defaults below are a complete working configuration on their own.

## Tree root, unconditional -- JOBS_DIR/HEALTHCHECKS_DIR/PARSERS_DIR below
## always derive from this, never from wherever SETTINGS was found.
home="${home:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

SETTINGS_FILE=""
site_override=0
if [[ -n "${SETTINGS_HOME:-}" ]]; then
    ## Existing override, unchanged: a directory, same two-file lookup as
    ## always. The test suites are the only callers.
    site_override=1
    [[ -f "$SETTINGS_HOME/SETTINGS" ]] && SETTINGS_FILE="$SETTINGS_HOME/SETTINGS"
    [[ -z "$SETTINGS_FILE" && -f "$SETTINGS_HOME/SETTINGS.default" ]] &&
        SETTINGS_FILE="$SETTINGS_HOME/SETTINGS.default"
elif [[ -f "$home/SETTINGS_HOME" ]]; then
    ## A site's own pointer, not the shipped default -- naming nothing real
    ## is a misconfiguration to report, not a reason to fall back quietly.
    site_override=1
    candidate=$(grep -vE '^[[:space:]]*(#|$)' "$home/SETTINGS_HOME" | head -1)
    [[ -f "$candidate" ]] && SETTINGS_FILE="$candidate"
elif [[ -f "$home/SETTINGS_HOME.default" ]]; then
    candidate=$(grep -vE '^[[:space:]]*(#|$)' "$home/SETTINGS_HOME.default" | head -1)
    [[ -f "$candidate" ]] && SETTINGS_FILE="$candidate"
fi
## Only when nothing above named a specific intent: no override at all, or
## the shipped default pointer not populated yet -- same as SETTINGS.default
## always being the safety net when a site has not written SETTINGS itself.
if [[ -z "$SETTINGS_FILE" && "$site_override" -eq 0 ]]; then
    if [[ -f "$home/SETTINGS" ]]; then
        SETTINGS_FILE="$home/SETTINGS"
    elif [[ -f "$home/SETTINGS.default" ]]; then
        SETTINGS_FILE="$home/SETTINGS.default"
    fi
fi

# shellcheck source=/dev/null
[[ -n "$SETTINGS_FILE" ]] && source "$SETTINGS_FILE"

## Defaults for anything the settings file did not set, matching what
## SETTINGS.default ships. What each key means is documented there.
: "${JOBS:=nvl72}"
: "${HEALTHCHECKS:=nvl72}"
: "${PARSERS:=nvl72}"
: "${BENCHMARKS:=dcgmi-r1 dcgmi-r3 dcgmi-r4 nvbandwidth allreduce allreduce-forcesharp alltoall allreduce-nonvlink alltoall-nonvlink llm-pretrain llm-pretrain-solo}"
## NCCL bandwidth floors, GB/s. Every other gate stays in the parser.
## See docs/reference/settings.md#benchmark-pass-floors.
: "${VERDICT_MIN_PEAK_BW_ALLREDUCE:=683}"
: "${VERDICT_MIN_PEAK_BW_ALLREDUCE_FORCESHARP:=665}"
: "${VERDICT_MIN_PEAK_BW_ALLTOALL:=623}"
: "${VERDICT_MIN_PEAK_BW_ALLREDUCE_NONVLINK:=93}"
: "${VERDICT_MIN_PEAK_BW_ALLTOALL_NONVLINK:=83}"
## Median step time ceilings for the LLM jobs, milliseconds. `=` not `:=`:
## an explicit 0 means "no band" and skips the check, which is a real answer.
## See docs/reference/settings.md#llm-step-time-ceilings.
: "${VERDICT_MAX_STEP_MS_LLM_PRETRAIN=3480}"
: "${VERDICT_MAX_STEP_MS_LLM_SOLO=3510}"
: "${VERDICT_MAX_STEP_MS_DEEPSEEK_V3_PROXY=0}"
## `=` not `:=`: an empty BURNIN means "no burn-in" and is a real answer.
## See docs/reference/settings.md#burn-in.
: "${BURNIN=mnubergemm}"
## Shared campaign target, hours. See docs/reference/settings.md#burn-in.
: "${BURNIN_HOURS:=24}"
## `=` not `:=`: empty is a real "off" answer, same as BURNIN.
## See docs/reference/settings.md#continuous-re-runs.
: "${CONTINUE_RUNNING_JOBS=}"
: "${CONTINUE_RUNNING_FREQUENCY:=6}"
## Image versions. See docs/reference/settings.md#image-versions.
: "${HPC_BENCHMARKS_TAG:=26.02}"
: "${NVBANDWIDTH_VERSION:=v0.9}"
: "${NVLOOM_VERSION:=v2.0.0}"
: "${MNUBERGEMM_VERSION:=26.03-v1.17}"
: "${NEMO_TAG:=26.04.01}"
: "${PYTORCH_TAG:=26.08}"
## 0 disables the cadence. See docs/explanation/health-cadence.md.
: "${HEALTH_INTERVAL_HOURS:=4}"
: "${HEALTH_RETRY_INTERVAL_HOURS:=1}"
## Run and drain switches, all defaulting on (RUN_BURNIN is the one
## exception, opt-in) so an empty or unreadable value carries on rather than
## stopping the fleet or draining it. See docs/reference/settings.md#run-switches
## and docs/reference/settings.md#drains.
: "${RUN_JOBS:=yes}"
: "${RUN_HEALTH_CHECKS:=yes}"
: "${RUN_CONTAINER_COPY:=yes}"
## Independent of RUN_JOBS: stopping the sweep and stopping drains being
## cleared are different decisions. See docs/reference/settings.md#run-switches.
: "${RUN_RECOVERY:=yes}"
## Stops the watchdog arming nodes; agents already running are left alone.
## See docs/reference/settings.md#run-switches.
: "${RUN_ARMING:=yes}"
: "${RUN_BURNIN:=no}"
## BCM-specific: wait for the command daemon, Slurm daemon and job identity
## before submitting after a reboot. Off unless the site explicitly opts in.
: "${REQUIRE_BCM_BOOTSTRAP_READY:=no}"
: "${BCM_BOOTSTRAP_PROBE_TIMEOUT_SECS:=5}"
: "${DRAIN_AFTER_FAILED_HEALTH_CHECK:=no}"
: "${DRAIN_AFTER_FAILED_BENCHMARK:=no}"
## Recovery of drains Slurm set itself. On by default, unlike the switches
## above: this one puts nodes back. RECOVER_REASONS is a case-insensitive ERE
## and must stay narrow -- it is the only discriminator left when an admin
## drains as root. See docs/explanation/drain-recovery.md.
: "${RECOVER_SLURM_DRAINS:=yes}"
: "${RECOVER_REASONS:=prolog|epilog|rogue ?process|batch job complete failure|Kill task failed|node unexpectedly rebooted|node was stopped|not responding|duplicate jobid|gres/gpu count|low socket|low cpus}"
: "${RECOVER_EMPTY_REASON:=yes}"
: "${RECOVER_SETTERS:=slurm root}"
: "${RECOVER_MAX_ATTEMPTS:=3}"
: "${RECOVER_WINDOW_HOURS:=24}"
## Both restarts ship on: the code only reaches them on a node that is up,
## drained and idle, and neither drain they clear can clear itself.
## See docs/explanation/drain-recovery.md#restarting-slurmd.
: "${RECOVER_RESTART_SLURMD:=yes}"
: "${RECOVER_REREGISTER:=yes}"
: "${RECOVER_SLURMD_WAIT:=30}"
## Nothing is judged mid-boot: every count below is a moving number until the
## node has finished coming up. 0 disables the uptime floor.
## See docs/explanation/drain-recovery.md#nothing-is-judged-mid-boot.
: "${RECOVER_MIN_UPTIME_SECS:=300}"
## Where the pre-job health check writes what it objected to -- the only place
## a rogueprocess drain names its process. Empty disables that check.
## See docs/explanation/drain-recovery.md#a-rogue-process-drain-names-its-process.
: "${RECOVER_PREJOB_LOGS:=/cm/local/apps/slurm/var/pre-post-job-logs/failed-pre-jobs}"
: "${RECOVER_PREJOB_SLACK_SECS:=900}"
## Off by default: marking a node DOWN releases whatever allocation it holds.
## See docs/explanation/drain-recovery.md#a-step-that-outlives-its-own-kill.
: "${RECOVER_DOWN_UNKILLABLE:=no}"
: "${RECOVER_UNKILLABLE_REASONS:=Kill task failed|unkillable}"
: "${RECOVER_UNKILLABLE_AFTER_SECS:=3600}"
## `=` not `:=`: empty is the shipped answer and a real one -- it means "one
## worker per core". See docs/reference/settings.md#reporting.
: "${SCAN_JOBS=}"
## Empty is a real answer here too: it means every node. See
## docs/reference/settings.md#restricting-which-nodes-run-jobs.
: "${NODE_FILTER=}"
## Hosts that are not compute nodes at all. Empty leaves the self-detection in
## node_self_excluded as the only judge.
## See docs/reference/settings.md#hosts-that-are-not-compute-nodes.
: "${EXCLUDE_NODES=}"
: "${RETRY_INTERVAL_HOURS:=1}"
## On by default, and backfilled, so an existing site gets the ramp without
## editing anything. See docs/explanation/sequencing.md#backing-off-a-job-that-keeps-failing.
: "${RETRY_BACKOFF:=yes}"
: "${RETRY_BACKOFF_MAX_HOURS:=12}"
## Submission failures are not workload failures: no result file exists to put
## them behind the retry window above. Persist and spread their own retry, and
## let the watchdog stop a fleet-wide storm when the same failure is widespread.
## See docs/explanation/sequencing.md#when-sbatch-refuses-a-submission.
: "${SUBMIT_RETRY_BASE_MINUTES:=2}"
: "${SUBMIT_RETRY_MAX_MINUTES:=30}"
: "${SUBMIT_CIRCUIT_FAILURES:=10}"
: "${SUBMIT_CIRCUIT_WINDOW_MINUTES:=5}"
: "${SUBMIT_CIRCUIT_HOLD_MINUTES:=10}"
: "${MAX_JOB_HOURS:=7}"
## On by default: a job Slurm will not schedule sits PENDING in everybody's
## squeue. See docs/explanation/sequencing.md#submitting-only-to-an-idle-node.
: "${SUBMIT_ONLY_WHEN_IDLE:=yes}"
## Experimental, and off: the head-node watchdog uses this to cancel a job of
## ours that is working. A compute node never makes this decision or calls
## scancel. See docs/explanation/sequencing.md#getting-out-of-the-way.
: "${GET_OUT_OF_THE_WAY:=no}"
: "${GET_OUT_OF_THE_WAY_AFTER_MINUTES:=5}"
: "${GET_OUT_OF_THE_WAY_POLL_MINUTES:=5}"
: "${DRAIN_WINDOW_MINUTES:=15}"
: "${INFLIGHT_GRACE_MINUTES:=30}"
: "${DRAIN_MARKER:=auto-retry}"
## ── The agent and the watchdog ────────────────────────────────────────────
## The cycle the node runs on, the cycle the head node watches on, and how long
## a heartbeat may go unwritten before the node is armed again.
## See docs/explanation/the-agent-and-the-watchdog.md#choosing-the-three-numbers.
: "${AGENT_INTERVAL_MINUTES:=2}"
: "${SUPERVISOR_INTERVAL_MINUTES:=2}"
: "${HEARTBEAT_STALE_MINUTES:=10}"
## The most nodes one watchdog cycle will reach at once. Every arm is an ssh,
## and a fleet that stops cycling makes every node stale in the same instant.
## 0 is no cap. See docs/explanation/the-agent-and-the-watchdog.md#arming-is-bounded.
: "${ARM_BATCH:=200}"
## A node that cannot be armed is reported rather than sshed into every cycle,
## on the same shape as RECOVER_MAX_ATTEMPTS.
: "${ARM_RETRY_MINUTES:=10}"
: "${ARM_MAX_ATTEMPTS:=3}"
: "${ARM_WINDOW_HOURS:=24}"
## `=` not `:=`: empty means three watchdog cycles, floored at five minutes.
: "${SLURM_SNAPSHOT_MAX_AGE_MINUTES=}"
## Empty means whichever host claims it first and keeps refreshing the claim.
## Name one to settle it deterministically where two hosts read as head.
## See docs/explanation/the-agent-and-the-watchdog.md#only-one-watchdog.
: "${SUPERVISOR_HOST=}"
## sudo, or direct for a site that gave JOB_USER Slurm AdminLevel=Operator.
## See docs/explanation/running-unprivileged.md#draining-without-root.
: "${PRIV_SCONTROL:=sudo}"
## How more than one node is reached: auto prefers clush and falls back to pdsh.
## See docs/explanation/architecture.md#reaching-nodes-is-clush-or-pdsh.
: "${FANOUT_TOOL:=auto}"
## Seconds. 0 on either means no limit, which is what both tools do unasked.
## See docs/explanation/architecture.md#a-fan-out-is-bounded.
: "${FANOUT_CONNECT_TIMEOUT:=10}"
: "${FANOUT_COMMAND_TIMEOUT:=60}"
## `=` not `:=`: empty is the shipped answer and a real one.
## Deliberately not exported -- launch_job.sh is the only reader and hands it
## to sbatch --export. See docs/reference/settings.md#extra-environment-for-every-job.
: "${JOB_ENV=}"
## The only account name in the tree; the paths derive from it.
## See docs/reference/settings.md#accounts-and-paths.
: "${JOB_USER:=cmods}"
: "${BRINGUP_HOME:=/cluster/bringup}"
## Where results, logs, container images and the health baseline live --
## independent of BRINGUP_HOME so the checkout and the data it produces can
## sit on different filesystems. See docs/reference/settings.md#accounts-and-paths.
: "${BRINGUP_DATA:=/cluster/bringup-data}"
: "${RESULTS_DIR:=$BRINGUP_DATA/results}"
: "${HEALTH_LOG_DIR:=$BRINGUP_DATA/logs}"
## Its own share, and the _HEAD pair is the head node's mount point for it.
## See docs/explanation/containers.md#one-share-two-mount-points.
: "${CONTAINER_DIR:=$BRINGUP_DATA/containers}"
: "${CONTAINER_DIR_HEAD:=$CONTAINER_DIR}"
: "${CONTAINER_STAGE_DIR:=$BRINGUP_DATA/container-src}"
: "${CONTAINER_STAGE_DIR_HEAD:=$CONTAINER_STAGE_DIR}"
## Node-local cache file_copy.sh rsyncs CONTAINER_DIR into. See docs/explanation/containers.md#one-share-two-mount-points.
: "${NODE_CONTAINER_DIR:=/opt/containers}"
## The health baseline captured by admin_set-baseline.sh. See
## docs/reference/settings.md#accounts-and-paths.
: "${VALID_CONFIG_DIR:=$BRINGUP_DATA/valid-config}"
: "${LLM_HF_HOME=}"
## `=` not `:=`: empty means no llmb install.
## See docs/explanation/llmb.md#where-the-install-lives.
: "${LLMB_INSTALL=/home/$JOB_USER/llmb}"
: "${LLMB_REF=v26.06.01}"
## `=` not `:=`: empty means "search for it", which is how an install this tree
## did not build is adopted. llmb_check.py owns the search order.
## See docs/explanation/llmb.md#adopting-an-existing-install.
: "${LLMB_BIN=}"
: "${LLMB_CONFIG=}"
: "${LLMB_IMAGES=}"
: "${LLMB_HF=}"

## The only place these paths are built; no caller should rebuild them by hand.
## Always under the tree root, never wherever SETTINGS was actually read from.
## See docs/reference/settings.md#which-set-of-things-to-run.
##
## SC2034: read by the scripts that source this file, which shellcheck cannot
## see from here. Repeated because it covers only the next assignment.
# shellcheck disable=SC2034
JOBS_DIR="$home/jobs/$JOBS"
# shellcheck disable=SC2034
HEALTHCHECKS_DIR="$home/health-checks/$HEALTHCHECKS"
# shellcheck disable=SC2034
PARSERS_DIR="$home/parsers/$PARSERS"

## Read a yes/no setting. Anything not affirmative is off, including a typo and
## including empty. See docs/reference/settings.md#drains.
setting_enabled() {
    case "${1,,}" in
        yes|true|1|on) return 0 ;;
        *)             return 1 ;;
    esac
}

## The inverse, not `! setting_enabled`: a RUN_* switch has to fail toward
## running when its value is a typo or empty, the same direction the PAUSE_*
## switches these replaced already had -- so only a clear "no" disables.
## See docs/reference/settings.md#run-switches.
setting_disabled() {
    case "${1,,}" in
        no|false|0|off) return 0 ;;
        *)              return 1 ;;
    esac
}

## True if $SETTINGS_FILE still sets $1 as text -- a name nothing reads any
## more sets no shell variable, so this is the only way to notice it is still
## there. See docs/reference/settings.md#run-switches.
old_setting_present() {
    [[ -n "$SETTINGS_FILE" ]] && grep -qE "^[[:space:]]*$1[[:space:]]*=" "$SETTINGS_FILE"
}

## ── Hosts that are not compute nodes ──────────────────────────────────────
## Read docs/explanation/sequencing.md#a-host-that-is-not-a-compute-node before
## changing any of this: the obvious test, `sinfo -N -n`, is the one that was
## removed for reporting 981 real nodes as gone.

## The site's list. Shell globs and whitespace separated, like NODE_FILTER.
##
## `read -a`, not `for pat in $EXCLUDE_NODES`: callers set `nullglob`, which
## deletes every pattern matching no file in the CWD -- the whole list.
node_excluded() {
    local pat pats
    [[ -z "${EXCLUDE_NODES// /}" ]] && return 1
    read -r -a pats <<< "$EXCLUDE_NODES"
    for pat in "${pats[@]}"; do
        # shellcheck disable=SC2053  # a glob on the right is the whole point here
        [[ "$1" == $pat ]] && return 0
    done
    return 1
}

## Asked of the local systemd, which answers from installed unit files and
## contacts nothing. Both halves must agree, so an unreadable systemd says
## nothing rather than retiring a node.
node_self_excluded() {
    local units
    command -v systemctl >/dev/null 2>&1 || return 1
    units=$(systemctl list-unit-files slurmd.service slurmctld.service --no-legend 2>/dev/null)
    [[ "$units" == *slurmctld.service* && "$units" != *slurmd.service* ]]
}

## What the node writes down for the reports, which run on the head node and can
## ask neither another node's systemd nor slurmctld.
NOT_COMPUTE_MARKER=".not-a-compute-node"

node_mark_excluded() {
    [[ -d "$1" ]] || return 1
    printf '%s\n' "$2" > "$1/$NOT_COMPUTE_MARKER" 2>/dev/null
}

node_unmark_excluded() { rm -f "$1/$NOT_COMPUTE_MARKER" 2>/dev/null; }

## The one question every script that walks results/*/ asks.
node_out_of_reporting() {
    node_excluded "$2" && return 0
    [[ -f "$1/$2/$NOT_COMPUTE_MARKER" ]]
}

## ── Which role this host plays ────────────────────────────────────────────
## Asked at run time, not baked into a unit file: $HOME is NFS-shared at most
## sites, so every host reads the same units and the same `systemctl --user
## enable` state. A unit that differs by role cannot survive that.
## See docs/explanation/the-agent-and-the-watchdog.md#one-unit-for-both-roles.
## Sets AGENT_ROLE and AGENT_ROLE_WHY rather than printing them: a caller that
## took the role from $(agent_role) would lose the reason to the subshell, and
## the reason is the whole point of saying which role was chosen.
##
## SC2034: read by the callers, which shellcheck cannot see from here.
# shellcheck disable=SC2034
AGENT_ROLE=""
# shellcheck disable=SC2034
AGENT_ROLE_WHY=""
agent_role() {
    if node_excluded "$HOSTNAME"; then
        AGENT_ROLE_WHY="EXCLUDE_NODES matches $HOSTNAME"; AGENT_ROLE="head"; return 0
    fi
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet slurmctld 2>/dev/null; then
            AGENT_ROLE_WHY="slurmctld is running here"; AGENT_ROLE="head"; return 0
        fi
        if node_self_excluded; then
            AGENT_ROLE_WHY="slurmctld is installed here and slurmd is not"; AGENT_ROLE="head"; return 0
        fi
        ## Whatever else it is, Slurm can schedule nothing to a host with no
        ## slurmd, so it is not a compute node.
        if [[ -z "$(systemctl list-unit-files slurmd.service --no-legend 2>/dev/null)" ]]; then
            AGENT_ROLE_WHY="there is no slurmd unit here, so nothing can be scheduled to this host"
            AGENT_ROLE="head"; return 0
        fi
        AGENT_ROLE_WHY="slurmd is installed here and slurmctld is not running"
    else
        # shellcheck disable=SC2034
        AGENT_ROLE_WHY="systemctl is not installed, so nothing here could say otherwise"
    fi
    # shellcheck disable=SC2034
    AGENT_ROLE="node"
}

## ── Has this node stopped cycling ─────────────────────────────────────────
## The agent touches this every cycle whatever it then decides, so a stale one
## means the timer is not firing -- and a report judged from files nobody is
## refreshing reads exactly like one that is up to date.
## See docs/explanation/the-agent-and-the-watchdog.md#what-the-heartbeat-means.
HEARTBEAT_MARKER=".heartbeat"
HEARTBEAT_NOW=""
heartbeat_stale() {
    local mtime
    [[ -n "$HEARTBEAT_NOW" ]] || HEARTBEAT_NOW=$(date +%s)   ## one fork, not one per node
    mtime=$(stat -c %Y "$1/$2/$HEARTBEAT_MARKER" 2>/dev/null) || return 0
    [[ $(( HEARTBEAT_NOW - mtime )) -ge $(( HEARTBEAT_STALE_MINUTES * 60 )) ]]
}
