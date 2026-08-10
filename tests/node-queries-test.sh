#!/bin/bash
#
# Nothing that runs on a compute node may ask slurmctld anything. Two thousand
# agents on a two-minute cycle turn one query into seventeen a second, sustained,
# and the reason each of these was removed is invisible in a diff that adds one
# back. See docs/explanation/the-fleet-snapshot.md.
#
# This is a grep, not a run: the failure it catches is a query being *written*,
# and a suite that stubbed Slurm would pass either way.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$home" || exit 1

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }

## Everything a node's own cycle reaches. slurm-snapshot.sh is on both sides --
## it is sourced by the node and by the watchdog -- so its writer half is
## checked separately below.
NODE_SIDE=(
    agent/node-agent.sh
    agent/cycle.sh
    actions/launch_job.sh
    actions/node_health.sh
    actions/file_copy.sh
    slurm-recovery.sh
)

## `scontrol listjobs` asks the local slurmstepds and costs the controller
## nothing; `scontrol update` is a write, not a query, and fires only on failure.
## Everything else in this list is a question for slurmctld.
BANNED='squeue|sinfo|sacct|sacctmgr|sprio|sshare|sdiag|scancel|scontrol[[:space:]]+show'

echo "== no compute node asks slurmctld anything =="
for f in "${NODE_SIDE[@]}"; do
    [[ -f "$f" ]] || { bad "$f is missing -- the list in this test has drifted"; continue; }
    ## Comments and the operator-facing strings scripts *print* are fine: a trace
    ## line telling somebody to run `scancel 123` by hand is not this node doing
    ## it. Strip both, then look at what is left.
    hits=$(sed -e 's/^[[:space:]]*#.*$//' -e "s/\"[^\"]*\"//g" -e "s/'[^']*'//g" "$f" |
           grep -nE "(^|[^[:alnum:]_./-])($BANNED)([^[:alnum:]_-]|$)")
    if [[ -n "$hits" ]]; then
        bad "$f runs a controller query -- it must read the node view instead:"
        printf '         %s\n' "$hits"
    else
        ok "$f asks the controller nothing"
    fi
done

echo
echo "== the watchdog is the one host that does ask =="
for tool in squeue sinfo; do
    if grep -qE "(^|[^[:alnum:]_])$tool " slurm-snapshot.sh; then
        ok "slurm-snapshot.sh is where the fleet's $tool lives"
    else
        bad "slurm-snapshot.sh no longer runs $tool -- if the query moved, this test has to move with it"
    fi
done

## The count that matters. One of each, for the whole fleet, per watchdog cycle.
for tool in squeue sinfo; do
    n=$(grep -cE "^[[:space:]]*[A-Z_]+=\\\$\($tool " slurm-snapshot.sh)
    case "$tool:$n" in
        squeue:1) ok "one squeue for the fleet" ;;
        sinfo:2)  ok "two sinfo for the fleet -- state and reason, then the hardware counts" ;;
        *)        bad "$n $tool call(s) in slurm-snapshot.sh; every one is multiplied by the watchdog's cadence, not the fleet's -- confirm that is intended and update this test" ;;
    esac
done

echo
echo "== the yield decision left the node =="
if grep -qE '(^|[^[:alnum:]_])(squeue|scancel)([^[:alnum:]_-]|$)' get-out-of-the-way.sh &&
   grep -q 'agent/supervisor.sh' get-out-of-the-way.sh; then
    ok "get-out-of-the-way.sh still cancels, and says it is the watchdog's"
else
    bad "get-out-of-the-way.sh no longer reads as a head-node library"
fi
if grep -q 'get-out-of-the-way.sh' actions/launch_job.sh; then
    bad "actions/launch_job.sh sources the yield library again -- that is a pending-queue dump per node per poll"
else
    ok "no node sources the yield library"
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
