#!/bin/bash
#
# Usage: trigger-debug.sh [node-pattern]
#
# Answers "why is nothing running?" by walking the chain from BCM down to
# sbatch, in order, and stopping to say which link is broken. Run on the head
# node. Read-only -- it submits nothing, drains nothing, changes nothing.
#
#   pattern  optional node filter, same rules as status-check.sh: a bare
#            string matches by prefix, globs are honored as written. Only
#            affects the per-node sections.
#
# The chain, and what breaks at each link:
#
#   1. action registered in BCM      -- cm_replace failed, or was never run
#   2. trigger registered + enabled  -- same, or someone set disabled yes
#   3. trigger has the action bound  -- the failure create-action-trigger.sh
#                                       warns about: object exists, runs nothing
#   4. script exists on the node     -- NFS not mounted, or wrong path
#   5. script decides to submit      -- read trigger.log, or run --explain
#   6. sbatch accepts the job        -- partition, account, node state
#   7. slurm can write the result    -- output path not writable by cmods
#
# Link 7 is the one with no symptom of its own: BCM fires, the script submits,
# sbatch returns a job id, and the job dies before it writes a byte. Nothing
# in slurm's accounting distinguishes that from a benchmark that never ran.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
results_dir="$home/results"

pattern="$1"
if [[ -z "$pattern" ]]; then
    pattern='*'
elif [[ "$pattern" != *[\*\?\[]* ]]; then
    pattern="${pattern}*"
fi

ACTIONS="node_health_action file_copy_action launch_job_action"
TRIGGERS="NodeHealthTrigger:node_health_action FileCopyTrigger:file_copy_action LaunchJobTrigger:launch_job_action"

problems=0
note()  { printf '  %s\n' "$*"; }
bad()   { printf '  ** %s\n' "$*"; problems=$((problems + 1)); }
hdr()   { printf '\n=== %s ===\n' "$*"; }

##############################################################################
hdr "1-3. BCM actions and triggers"
##############################################################################

if ! command -v cmsh >/dev/null 2>&1; then
    note "cmsh not on PATH -- skipping BCM checks (run this on the head node)"
else
    action_list=$(cmsh -c "monitoring action; list" 2>&1)
    for a in $ACTIONS; do
        if grep -qw "$a" <<<"$action_list"; then
            script=$(cmsh -c "monitoring action; use $a; get script" 2>&1 | tr -d '\r')
            note "action $a -> $script"
            [[ -f "$script" ]] || bad "  script does not exist on the head node: $script"
            [[ -x "$script" ]] || bad "  script is not executable: $script"
        else
            bad "action $a is NOT registered -- run pre-post/create-action-trigger.sh"
        fi
    done

    trigger_list=$(cmsh -c "monitoring trigger; list" 2>&1)
    for spec in $TRIGGERS; do
        t="${spec%%:*}"; want="${spec##*:}"
        if ! grep -qw "$t" <<<"$trigger_list"; then
            bad "trigger $t is NOT registered -- run pre-post/create-action-trigger.sh"
            continue
        fi
        show=$(cmsh -c "monitoring trigger; use $t; show" 2>&1)
        disabled=$(awk -F'  +' '/^Disabled/ {print $NF}' <<<"$show" | tr -d '[:space:]')
        during=$(awk -F'  +' '/^During actions/ {print $NF}' <<<"$show")
        note "trigger $t: disabled=${disabled:-?} duringactions=${during:-<none>}"
        [[ "$disabled" == "no" ]] || bad "  $t is disabled -- it will never fire"
        ## The failure create-action-trigger.sh calls out by name: the trigger
        ## object exists and looks healthy, but has no action bound, so it
        ## fires on every cycle and does nothing.
        grep -q "$want" <<<"$during" || bad "  $t has no '$want' bound -- fires but runs nothing"
    done
fi

##############################################################################
hdr "4. Node reachability and script presence"
##############################################################################

## A node in down* is not running slurmd, so BCM may still fire the trigger
## there but nothing will ever be scheduled onto it. Separate that population
## out first -- otherwise "nothing is running" gets blamed on the trigger.
if command -v sinfo >/dev/null 2>&1; then
    while read -r state count; do
        [[ -z "$state" ]] && continue
        case "$state" in
            *'*') bad "$count nodes in '$state' -- slurmd not responding; the trigger cannot help these" ;;
            idle) note "$count nodes idle -- these SHOULD be picking up work" ;;
            *)    note "$count nodes in '$state'" ;;
        esac
    done < <(sinfo -h -o '%T %D' | sort -k2 -rn)
else
    note "sinfo not on PATH -- skipping slurm state summary"
fi

##############################################################################
hdr "5. What the script decided, per node"
##############################################################################

## launch_job.sh appends a line per monitoring cycle to results/<node>/trigger.log
## explaining what it did or why it stopped. No log at all means the script is
## not being run on that node -- which points back at links 1-4, not at slurm.
shopt -s nullglob
nodes=("$results_dir"/$pattern/)
if [[ "${#nodes[@]}" -eq 0 ]]; then
    bad "no node directories under $results_dir match '${1:-*}'"
    note "if you just cleared results/, this is expected until the trigger fires again"
else
    silent=0
    for node_dir in "${nodes[@]}"; do
        node=$(basename "$node_dir")
        if [[ -f "$node_dir/trigger.log" ]]; then
            printf '  %s: %s\n' "$node" "$(tail -1 "$node_dir/trigger.log")"
        else
            silent=$((silent + 1))
        fi
    done
    [[ "$silent" -gt 0 ]] && bad "$silent node dir(s) have no trigger.log -- script is not running there"
fi

##############################################################################
hdr "6-7. Ownership of the result path"
##############################################################################

## BCM runs launch_job.sh as root on the node, so root recreates results/ and
## results/<node>. sbatch then runs as cmods with --output into that directory.
## If root's copy is mode 755, cmods cannot create the result file: sbatch
## still returns a job id, slurm still schedules it, and the job dies at
## startup with nowhere to write. The node goes back to idle with no result
## file, no failure, and no archive -- indistinguishable from never having run.
##
## launch_job.sh now repairs this itself on every monitoring cycle, so a
## root-owned directory here means either no cycle has run since the tree was
## created, or the script is not reaching this node at all -- check section 5.
if [[ -d "$results_dir" ]]; then
    owner=$(stat -c '%U %a' "$results_dir")
    note "results/ owned by $owner"
    case "$owner" in
        cmods*) ;;
        *) bad "results/ is not owned by cmods -- sbatch --output will fail for cmods-run jobs" ;;
    esac
    rootowned=0
    while IFS= read -r d; do
        [[ "$(stat -c '%U' "$d")" == "cmods" ]] || rootowned=$((rootowned + 1))
    done < <(find "$results_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    if [[ "$rootowned" -gt 0 ]]; then
        bad "$rootowned node dir(s) not owned by cmods -- jobs there cannot write results"
        note "these self-heal on the next monitoring cycle; to fix now:"
        note "  chown -R cmods:cmods $results_dir"
    fi
else
    bad "$results_dir does not exist"
fi

##############################################################################
hdr "Summary"
##############################################################################

if [[ "$problems" -eq 0 ]]; then
    echo "  No broken links found in the trigger chain."
else
    echo "  $problems problem(s) flagged above."
fi
cat <<EOF

Next step -- ask one node directly, without waiting for a monitoring cycle:

  pdsh -w <node> '/home/cmods/bringup/actions/launch_job.sh --explain'

That prints every gate the script evaluates and the sbatch commands it would
run, as a dry run: it submits nothing, drains nothing, and archives nothing,
so it is safe while the trigger is live.
EOF
