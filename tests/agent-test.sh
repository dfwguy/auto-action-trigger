#!/bin/bash
#
# agent/node-agent.sh: the heartbeat, the busy gate and the one-cycle-at-a-time
# lock. Both halves are invisible from outside -- a cycle that does work on a
# node running somebody's benchmark perturbs a measurement nobody will question,
# and a heartbeat written after a gate rather than before it makes the watchdog
# ssh into two hundred healthy nodes.
# See docs/explanation/the-agent-and-the-watchdog.md#what-the-heartbeat-means.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stub="$work/bin"
tree="$work/tree"
mkdir -p "$stub" "$tree/actions" "$tree/agent"

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }

## STUB_LISTJOBS is verbatim `scontrol listjobs` output; STUB_LISTJOBS_RC makes
## the query fail, which must read as busy rather than as idle.
cat > "$stub/scontrol" <<'EOF'
#!/bin/bash
if [[ "$1" == "listjobs" ]]; then
    [[ -n "$STUB_LISTJOBS" ]] && printf '%s\n' "$STUB_LISTJOBS"
    exit "${STUB_LISTJOBS_RC:-0}"
fi
exit 0
EOF
cat > "$stub/systemctl" <<'EOF'
#!/bin/bash
## A compute node: slurmd installed, slurmctld not. node_self_excluded reads
## both halves, so this decides the agent runs at all.
[[ "$1" == "list-unit-files" ]] && { echo "slurmd.service enabled"; exit 0; }
exit 0
EOF
chmod 755 "$stub"/*

cp "$home/settings.sh" "$home/priv.sh" "$tree/"
cp "$home/agent/node-agent.sh" "$tree/agent/"
cat > "$tree/SETTINGS" <<EOF
JOB_USER=$(id -un)
BRINGUP_HOME=$tree
BRINGUP_DATA=$tree
GET_OUT_OF_THE_WAY=no
EOF

## Each step records that it ran, so "did the busy gate stop everything" is a
## question about files rather than about output.
for step in file_copy node_health launch_job; do
    cat > "$tree/actions/$step.sh" <<EOF
#!/bin/bash
printf '%s\n' "$step \$*" >> "$tree/steps.ran"
exit 0
EOF
done
chmod 755 "$tree/actions"/*.sh

NODE=testnode
beat="$tree/results/$NODE/.heartbeat"
agentlog="$tree/results/$NODE/agent.log"

run_cycle() {
    rm -f "$tree/steps.ran"
    ( export PATH="$stub:$PATH" HOSTNAME="$NODE" AGENT_HOME="$tree" \
             STUB_LISTJOBS="${1:-}" STUB_LISTJOBS_RC="${2:-0}"
      "$tree/agent/node-agent.sh" --quiet >/dev/null 2>&1 )
}

steps_ran()  { [[ -s "$tree/steps.ran" ]]; }
last_line()  { tail -1 "$agentlog" 2>/dev/null; }

echo "== an idle node runs everything =="

run_cycle ""
if ! steps_ran; then
    bad "no step ran on an idle node: $(last_line)"
elif [[ "$(wc -l < "$tree/steps.ran")" -ne 3 ]]; then
    bad "not every step ran: $(tr '\n' ' ' < "$tree/steps.ran")"
else
    ok "all three steps ran, in order: $(cut -d' ' -f1 "$tree/steps.ran" | tr '\n' ' ')"
fi
[[ "$(cut -d' ' -f1 "$tree/steps.ran" | tr '\n' ' ')" == "file_copy node_health launch_job " ]] &&
    ok "the order is file_copy, node_health, launch_job" ||
    bad "the order changed: $(cut -d' ' -f1 "$tree/steps.ran" | tr '\n' ' ')"
[[ -f "$beat" ]] && ok "the heartbeat was written" || bad "no heartbeat on an idle cycle"
grep -q 'idle: no job here' <<<"$(last_line)" &&
    ok "the cycle said what it did: $(last_line)" ||
    bad "the idle cycle wrote no summary line: $(last_line)"

echo "== the busy gate =="

## The assertion that matters: not one step may run.
run_cycle "JOBID
130938"
if steps_ran; then
    bad "a step ran with a job on the node: $(tr '\n' ' ' < "$tree/steps.ran")"
else
    ok "no step ran with a job on the node"
fi
grep -q 'BUSY: job(s) 130938 running here' <<<"$(last_line)" &&
    ok "the busy line names the job: $(last_line)" ||
    bad "the busy line does not name the job: $(last_line)"

## A neighbour's job stops the cycle exactly as one of ours does -- the gate
## deliberately does not ask whose it is.
run_cycle "JOBID
999001
999002"
steps_ran && bad "a step ran with two foreign jobs on the node" ||
    ok "two jobs, still nothing run: $(last_line)"

echo "== an inconclusive answer reads as busy =="

## The direction that cannot interrupt a running benchmark. The opposite is a
## copy and a health run landing on top of somebody's measurement.
run_cycle "" 1
if steps_ran; then
    bad "a failed 'scontrol listjobs' was read as an idle node"
else
    ok "a failed query stopped the cycle: $(last_line)"
fi
grep -q "BUSY: 'scontrol listjobs' exited 1" <<<"$(last_line)" &&
    ok "and said why rather than looking like a real job" ||
    bad "the failure was not distinguished from a real job: $(last_line)"

echo "== the heartbeat is written above every gate =="

## This is what stops the watchdog arming a node that is working perfectly well.
rm -f "$beat"
run_cycle "JOBID
130938"
[[ -f "$beat" ]] &&
    ok "a busy cycle still wrote the heartbeat" ||
    bad "a busy cycle wrote no heartbeat -- the watchdog would ssh into a working node"

rm -f "$beat"
run_cycle "" 1
[[ -f "$beat" ]] &&
    ok "a cycle that could not read the queue still wrote it" ||
    bad "no heartbeat when the queue could not be read"

## Issue #9: RUN_JOBS is read inside launch_job.sh, well below this script's
## own heartbeat touch -- node-agent.sh never reads it at all. Pausing must not
## read as the timer having stopped. See docs/reference/settings.md#run-switches.
printf 'RUN_JOBS=no\n' >> "$tree/SETTINGS"
rm -f "$beat"
run_cycle ""
if [[ -f "$beat" ]]; then
    ok "RUN_JOBS=no still wrote the heartbeat"
else
    bad "RUN_JOBS=no stopped the heartbeat -- the watchdog would read this node as DOWN"
fi
steps_ran &&
    ok "  ... and node-agent.sh still ran its steps -- RUN_JOBS is launch_job.sh's gate to read, not this script's" ||
    bad "  ... but node-agent.sh itself stopped a step on RUN_JOBS, which is not its gate to read"
sed -i '/^RUN_JOBS=no$/d' "$tree/SETTINGS"

echo "== one cycle at a time =="

if ! command -v flock >/dev/null 2>&1; then
    printf '  skip %s\n' "flock is not installed here"
else
    lock=/tmp/.bringup-agent.lock
    exec 8>>"$lock"
    if flock -n 8; then
        run_cycle ""
        if steps_ran; then
            bad "a second cycle ran while the lock was held"
        else
            ok "a held lock stops the cycle: $(last_line)"
        fi
        grep -q 'still holds' <<<"$(last_line)" &&
            ok "and says how long the running one has been going" ||
            bad "the contention was not explained: $(last_line)"
        flock -u 8
    else
        printf '  skip %s\n' "$lock is already held by something else"
    fi
    exec 8>&-
fi

echo "== --explain changes nothing =="

rm -f "$beat"
( export PATH="$stub:$PATH" HOSTNAME="$NODE" AGENT_HOME="$tree" STUB_LISTJOBS=""
  rm -f "$tree/steps.ran"
  "$tree/agent/node-agent.sh" --explain >/dev/null 2>&1 )
[[ -f "$beat" ]] && bad "--explain touched the heartbeat" ||
    ok "--explain wrote no heartbeat"
if grep -q '^file_copy --explain --\(verbose\|quiet\)$' "$tree/steps.ran" 2>/dev/null; then
    ok "--explain was passed to the container copy"
else
    bad "--explain did not reach the container copy: $(cat "$tree/steps.ran" 2>/dev/null)"
fi
grep -q -- '--explain' "$tree/steps.ran" 2>/dev/null &&
    ok "and handed the flag to every step" ||
    bad "--explain was not passed down: $(cat "$tree/steps.ran" 2>/dev/null)"

echo "== a host that is not a compute node =="

## Above the results directory: a results/<host> holding only an agent trace
## puts the head node back into every report.
## See docs/explanation/sequencing.md#a-host-that-is-not-a-compute-node.
cat > "$stub/systemctl" <<'EOF'
#!/bin/bash
[[ "$1" == "list-unit-files" ]] && { echo "slurmctld.service enabled"; exit 0; }
exit 0
EOF
chmod 755 "$stub/systemctl"
rm -rf "$tree/results/headnode"
( export PATH="$stub:$PATH" HOSTNAME=headnode AGENT_HOME="$tree" STUB_LISTJOBS=""
  rm -f "$tree/steps.ran"
  "$tree/agent/node-agent.sh" --quiet >/dev/null 2>&1 )
if [[ -d "$tree/results/headnode" ]]; then
    bad "the head node got a results/ directory, which puts it back in every report"
elif steps_ran; then
    bad "the head node ran the steps"
else
    ok "a host running slurmctld and no slurmd does nothing and leaves no directory"
fi

echo "== cycle.sh sends each host to the right script =="

## One unit for both roles, because $HOME is NFS-shared and a unit that differs
## by role -- or is *enabled* by role -- is shared with the whole fleet.
## See docs/explanation/the-agent-and-the-watchdog.md#one-unit-for-both-roles.
cp "$home/agent/cycle.sh" "$tree/agent/"
printf '#!/bin/bash\necho SUPERVISOR\n' > "$tree/agent/supervisor.sh"
printf '#!/bin/bash\nprintf "%%s|%%s\\n" "${SSH_AUTH_SOCK-unset}" "${GPG_AGENT_INFO-unset}" > "$AGENT_HOME/agent-env"\necho NODE-AGENT\n' > "$tree/agent/node-agent.sh"
chmod 755 "$tree/agent"/*.sh

dispatch() {
    ( export PATH="$stub:$PATH" HOSTNAME="${2:-testnode}" AGENT_HOME="$tree" STUB_UNITS="$1"
      "$tree/agent/cycle.sh" --verbose 2>/dev/null )
}
cat > "$stub/systemctl" <<'EOF'
#!/bin/bash
[[ "$1" == "is-active" ]] && exit 3
[[ "$1" == "list-unit-files" ]] && { for u in $STUB_UNITS; do echo "$u enabled"; done; exit 0; }
exit 0
EOF
chmod 755 "$stub/systemctl"

[[ "$(dispatch 'slurmd.service')" == "NODE-AGENT" ]] &&
    ok "a host with slurmd runs the node agent" ||
    bad "a compute node did not get the node agent: $(dispatch 'slurmd.service')"
[[ "$(dispatch 'slurmctld.service')" == "SUPERVISOR" ]] &&
    ok "a host with slurmctld and no slurmd runs the watchdog" ||
    bad "the head node did not get the watchdog: $(dispatch 'slurmctld.service')"
## The case the fleet actually hit: a management host with neither unit.
[[ "$(dispatch '')" == "SUPERVISOR" ]] &&
    ok "a host with no slurmd at all runs the watchdog -- nothing can be scheduled to it" ||
    bad "a host with no slurmd was sent to the node agent: $(dispatch '')"

( export PATH="$stub:$PATH" HOSTNAME="testnode" AGENT_HOME="$tree" STUB_UNITS="slurmd.service"
  export SSH_AUTH_SOCK="/run/user/test/gnupg/S.gpg-agent.ssh" GPG_AGENT_INFO="interactive"
  "$tree/agent/cycle.sh" --quiet )
grep -q NODE-AGENT "$tree/logs/testnode/service.log" &&
    ok "a quiet cycle keeps child output in the per-node service log" ||
    bad "quiet output was not routed to logs/testnode/service.log"
[[ "$(cat "$tree/agent-env")" == "unset|unset" ]] &&
    ok "a quiet cycle does not inherit interactive agent sockets" ||
    bad "quiet child inherited agent state: $(cat "$tree/agent-env")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
