#!/bin/bash
#
# Loads the framework settings: SETTINGS if it exists, else SETTINGS.default,
# then backfills any key neither set. See docs/reference/settings.md.
#
# Set `home` (or SETTINGS_HOME) before sourcing. SETTINGS_FILE is left holding
# the path that was read, or empty if neither was found -- not fatal, since the
# defaults below are a complete working configuration on their own.

_settings_home="${SETTINGS_HOME:-${home:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}}"

SETTINGS_FILE=""
if [[ -f "$_settings_home/SETTINGS" ]]; then
    SETTINGS_FILE="$_settings_home/SETTINGS"
elif [[ -f "$_settings_home/SETTINGS.default" ]]; then
    SETTINGS_FILE="$_settings_home/SETTINGS.default"
fi

# shellcheck source=/dev/null
[[ -n "$SETTINGS_FILE" ]] && source "$SETTINGS_FILE"

## Defaults for anything the settings file did not set, matching what
## SETTINGS.default ships. What each key means is documented there.
: "${JOBS:=nvl72}"
: "${HEALTHCHECKS:=nvl72}"
: "${PARSERS:=nvl72}"
: "${BENCHMARKS:=dcgmi-r1 dcgmi-r3 nvbandwidth allreduce allreduce-forcesharp alltoall allreduce-nonvlink alltoall-nonvlink}"
## NCCL bandwidth floors, GB/s. Every other gate stays in the parser.
## See docs/reference/settings.md#benchmark-pass-floors.
: "${VERDICT_MIN_PEAK_BW_ALLREDUCE:=683}"
: "${VERDICT_MIN_PEAK_BW_ALLREDUCE_FORCESHARP:=665}"
: "${VERDICT_MIN_PEAK_BW_ALLTOALL:=623}"
: "${VERDICT_MIN_PEAK_BW_ALLREDUCE_NONVLINK:=93}"
: "${VERDICT_MIN_PEAK_BW_ALLTOALL_NONVLINK:=83}"
## Median step time ceilings for the two LLM jobs, milliseconds. `=` not `:=`:
## an explicit 0 means "no band" and skips the check, which is a real answer.
## See docs/reference/settings.md#llm-step-time-ceilings.
: "${VERDICT_MAX_STEP_MS_LLM_PRETRAIN=3480}"
: "${VERDICT_MAX_STEP_MS_LLM_SOLO=3510}"
## `=` not `:=`: an empty BURNIN means "no burn-in" and is a real answer.
## See docs/reference/settings.md#burn-in.
: "${RUN_BURNIN:=no}"
: "${BURNIN=mnubergemm}"
## `=` not `:=`: an empty CONTAINERS means "build nothing" and is a real
## answer. See docs/reference/settings.md#container-images.
: "${CONTAINERS=hpc-benchmarks nvbandwidth mnubergemm}"
## Image versions. See docs/reference/settings.md#image-versions.
: "${HPC_BENCHMARKS_TAG:=26.02}"
: "${NVBANDWIDTH_VERSION:=v0.9}"
: "${NVLOOM_VERSION:=v2.0.0}"
: "${MNUBERGEMM_VERSION:=26.03-v1.17}"
: "${NEMO_TAG:=26.04.01}"
## 0 disables the cadence. See docs/explanation/health-cadence.md.
: "${HEALTH_INTERVAL_HOURS:=4}"
: "${HEALTH_RETRY_INTERVAL_HOURS:=1}"
## Pause and drain switches, all defaulting off so an empty or unreadable value
## carries on rather than stopping the fleet or draining it. See
## docs/reference/settings.md#pause-switches and docs/reference/settings.md#drains.
: "${PAUSE_JOBS:=no}"
: "${PAUSE_HEALTH_CHECKS:=no}"
: "${PAUSE_CONTAINER_COPY:=no}"
## Independent of PAUSE_JOBS: stopping the sweep and stopping drains being
## cleared are different decisions. See docs/reference/settings.md#pause-switches.
: "${PAUSE_RECOVERY:=no}"
## Stops the watchdog arming nodes; agents already running are left alone.
## See docs/reference/settings.md#pause-switches.
: "${PAUSE_ARMING:=no}"
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
## `=` not `:=`, like CONTAINERS: empty is the shipped answer and a real one --
## it means "one worker per core". See docs/reference/settings.md#reporting.
: "${SCAN_JOBS=}"
## Empty is a real answer here too: it means every node. See
## docs/reference/settings.md#restricting-which-nodes-run-jobs.
: "${NODE_FILTER=}"
## Hosts that are not compute nodes at all. Empty leaves the self-detection in
## node_self_excluded as the only judge.
## See docs/reference/settings.md#hosts-that-are-not-compute-nodes.
: "${EXCLUDE_NODES=}"
## 0 is no cap. See docs/explanation/sequencing.md#the-fleet-wide-cap.
: "${MAX_QUEUED_JOBS:=500}"
: "${RETRY_INTERVAL_HOURS:=1}"
## On by default, and backfilled, so an existing site gets the ramp without
## editing anything. See docs/explanation/sequencing.md#backing-off-a-job-that-keeps-failing.
: "${RETRY_BACKOFF:=yes}"
: "${RETRY_BACKOFF_MAX_HOURS:=12}"
: "${MAX_JOB_HOURS:=7}"
## Experimental, and off: it is the one setting that cancels a job of ours that
## is working. See docs/explanation/sequencing.md#getting-out-of-the-way.
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
## A node that cannot be armed is reported rather than sshed into every cycle,
## on the same shape as RECOVER_MAX_ATTEMPTS.
: "${ARM_RETRY_MINUTES:=10}"
: "${ARM_MAX_ATTEMPTS:=3}"
: "${ARM_WINDOW_HOURS:=24}"
## sudo, or direct for a site that gave JOB_USER Slurm AdminLevel=Operator.
## See docs/explanation/running-unprivileged.md#draining-without-root.
: "${PRIV_SCONTROL:=sudo}"
## How more than one node is reached: auto prefers clush and falls back to pdsh.
## See docs/explanation/architecture.md#reaching-nodes-is-clush-or-pdsh.
: "${FANOUT_TOOL:=auto}"
## `=` not `:=`, like CONTAINERS: empty is the shipped answer and a real one.
## Deliberately not exported -- launch_job.sh is the only reader and hands it
## to sbatch --export. See docs/reference/settings.md#extra-environment-for-every-job.
: "${JOB_ENV=}"
## The only account name in the tree; the paths derive from it.
## See docs/reference/settings.md#accounts-and-paths.
: "${JOB_USER:=cmods}"
: "${BRINGUP_HOME:=/home/$JOB_USER/bringup}"
## Its own share, and the _HEAD pair is the head node's mount point for it.
## See docs/explanation/containers.md#one-share-two-mount-points.
: "${CONTAINER_DIR:=$BRINGUP_HOME/containers}"
: "${CONTAINER_DIR_HEAD:=$CONTAINER_DIR}"
: "${CONTAINER_STAGE_DIR:=$BRINGUP_HOME/container-src}"
: "${CONTAINER_STAGE_DIR_HEAD:=$CONTAINER_STAGE_DIR}"
## `=` not `:=`, like CONTAINERS: empty means no llmb install.
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
## See docs/reference/settings.md#which-set-of-things-to-run.
##
## SC2034: read by the scripts that source this file, which shellcheck cannot
## see from here. Repeated because it covers only the next assignment.
# shellcheck disable=SC2034
JOBS_DIR="$_settings_home/jobs/$JOBS"
# shellcheck disable=SC2034
HEALTHCHECKS_DIR="$_settings_home/health-checks/$HEALTHCHECKS"
# shellcheck disable=SC2034
PARSERS_DIR="$_settings_home/parsers/$PARSERS"

## Read a yes/no setting. Anything not affirmative is off, including a typo and
## including empty. See docs/reference/settings.md#drains.
setting_enabled() {
    case "${1,,}" in
        yes|true|1|on) return 0 ;;
        *)             return 1 ;;
    esac
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
