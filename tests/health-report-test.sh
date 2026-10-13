#!/bin/bash
#
# Checks how report_health.sh sorts a node once it has the verdict: failing,
# passing, never checked, or drained for something else. Every one of those is a
# node somebody acts on, and putting a node in the wrong one is silent -- the
# report still reads as a report.
#
# The pairing that matters is a node that is both failing and drained. It is one
# node, and counting it in both places inflates every total on the page.
#
# The real script is run against a stub tree, not a copy of its logic.
# See docs/reference/scripts.md#report_healthsh--cluster-wide-health-summary.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fails=0
check() {
    local label="$1" want="$2" got="$3"
    if [[ "$got" == *"$want"* ]]; then
        printf 'ok       %-46s %s\n' "$label" "$want"
    else
        printf 'FAILED   %-46s wanted [%s] in:\n%s\n' "$label" "$want" "$got"
        fails=$((fails + 1))
    fi
}
absent() {
    local label="$1" unwanted="$2" got="$3"
    if [[ "$got" != *"$unwanted"* ]]; then
        printf 'ok       %-46s no %s\n' "$label" "$unwanted"
    else
        printf 'FAILED   %-46s did not want [%s] in:\n%s\n' "$label" "$unwanted" "$got"
        fails=$((fails + 1))
    fi
}

mkdir -p "$work"/{bin,checks,valid-config/baseline,logs}
for f in settings.sh report-format.sh reason-map.sh health-scan.sh report_health.sh; do
    cp "$home/$f" "$work/$f"
done
cat > "$work/SETTINGS" <<EOF
HEALTHCHECKS=checks
JOB_USER=$(id -un)
EXCLUDE_NODES=""
DRAIN_AFTER_FAILED_HEALTH_CHECK=no
EOF
mv "$work/checks" "$work/health-checks-tmp"
mkdir -p "$work/health-checks"
mv "$work/health-checks-tmp" "$work/health-checks/checks"
for c in 10-alpha 20-beta; do
    printf '#!/bin/bash\n# banner: b\n' > "$work/health-checks/checks/$c.sh"
done
for c in alpha beta; do printf 'b\ngood\n' > "$work/valid-config/baseline/$c"; done
ln -sfn baseline "$work/valid-config/default"

## node01 fails and is in the queue, node02 fails and is drained for it,
## node03 is drained over a check it now passes, node04 is an operator drain,
## node05 passes, node06 has never been checked, node07-08 are one rack event.
for n in node01 node02 node03 node05; do
    mkdir -p "$work/logs/$n"
    for c in alpha beta; do printf 'b\ngood\n' > "$work/logs/$n/$c"; done
done
printf 'b\nBAD\n' > "$work/logs/node01/alpha"
printf 'b\nBAD\n' > "$work/logs/node01/beta"
printf 'b\nBAD\n' > "$work/logs/node02/alpha"

cat > "$work/bin/sinfo" <<'EOF'
#!/bin/bash
cat <<'OUT'
node01|idle|none
node02|drained|alpha
node03|drained|beta
node04|drained|Kill task failed
node05|idle|none
node06|idle|none
node07|down|Node unexpectedly rebooted
node08|down|Node unexpectedly rebooted
OUT
EOF
chmod 755 "$work/bin/sinfo"

## Enough of `scontrol show hostnames` for the node filter: comma lists and one
## trailing [a-b] range. Everything else is unanswered, so compress() falls back
## to the raw list exactly as it does on a host without scontrol.
cat > "$work/bin/scontrol" <<'EOF'
#!/bin/bash
[[ "$1 $2" == "show hostnames" ]] || exit 1
IFS=',' read -ra parts <<< "$3"
for p in "${parts[@]}"; do
    if [[ "$p" =~ ^(.*)\[([0-9]+)-([0-9]+)\]$ ]]; then
        pre="${BASH_REMATCH[1]}"; a="${BASH_REMATCH[2]}"; b="${BASH_REMATCH[3]}"
        for ((i = 10#$a; i <= 10#$b; i++)); do printf '%s%0*d\n' "$pre" "${#a}" "$i"; done
    else
        printf '%s\n' "$p"
    fi
done
EOF
chmod 755 "$work/bin/scontrol"

run() { ( cd "$work" && PATH="$work/bin:$PATH" COLUMNS=100 BRINGUP_DATA="$work" bash report_health.sh "$@" 2>&1 ); }

## ── The default report ────────────────────────────────────────────────────

report=$(run)

## Eight nodes, and each counted once. node02 is failing *and* drained; the
## drained sections must not claim it as well.
check "every node in exactly one count" \
    "8 nodes — 2 failing, 1 passing, 1 never checked, 4 other drains" "$report"

check "a failing node in the queue is failing" "node01" "$report"
check "a failing node that is drained is still failing" "node02" "$report"
absent "and is not an 'other' drain too" "drained        alpha" "$report"

## The reason this report exists: with drains off, node01 is failing and Slurm
## has not been told, so it is still being scheduled onto.
check "the banner counts the undrained failures" \
    "jobs are still being scheduled onto 1 of the" "$report"

## A drain over logs that now match is a repaired node nobody resumed. It is
## not a failure and must not be counted as one.
check "a stale health drain is marked" "(logs now match) beta" "$report"
check "and explained" "drains nothing supports any more" "$report"

## ── --drained ─────────────────────────────────────────────────────────────
## sinfo -R grouped: one line per reason, including the health drains the
## default report leaves out because it counted those nodes as failures.

drained=$(run --drained)

check "every drained node, failing or not" "DRAINED — 5 of 8 nodes" "$drained"
check "one line for a rack-wide event" "Node unexpectedly rebooted" "$drained"
check "and the rack under it" "node07,node08" "$drained"
check "the health drain the report counted as a failure" "drained        alpha" "$drained"
check "the operator drain" "Kill task failed" "$drained"
check "the stale one, still marked" "(logs now match) beta" "$drained"
absent "nothing in the queue" "node05" "$drained"
absent "and no health grouping" "FAILED HEALTH CHECKS" "$drained"

## The state is part of the key: down and drained over the same text are two
## situations, and folding them together hides one of them.
check "state leads each line" "down " "$drained"

## ── --by-state ────────────────────────────────────────────────────────────
## The flat roll-up counts a node already drained the same as one still taking
## work, so it cannot say how much of a check a drain would take out.

flat=$(run --summary)
split=$(run --by-state)

check "the flat roll-up pools the states" "    alpha                      2 nodes" "$flat"
absent "and names none of them" "Slurm state:" "$flat"

check "--by-state implies --summary" "── HEALTH CHECKS ──" "$split"
check "one block per state, largest first" \
    "Slurm state: drained — 1 node" "$split"
check "the other state" "Slurm state: idle — 1 node" "$split"
check "the check is counted inside its state" "    alpha                      1 node" "$split"
absent "and never pooled across them" "    alpha                      2 nodes" "$split"

## Once per node, not once per check it failed: node01 fails two checks and is
## one node.
absent "a node is counted once in its block header" "Slurm state: idle — 2 nodes" "$split"

## ── --individual ──────────────────────────────────────────────────────────
## Groups nodes by the whole check file rather than by pass/fail, so the values
## the fleet actually carries are visible. beta splits 3 good against 1 bad.

ind=$(run --individual beta)

check "every node with that check file" "beta — 4 nodes" "$ind"

## Identical files group together however far apart the nodes sort, and the
## group carries the file that produced it.
check "the matching nodes are one group" $'3 nodes\n  node02,node03,node05' "$ind"
check "and the odd one out is its own" $'1 node\n  node01' "$ind"
check "the file content is under each group" "BAD" "$ind"

## Largest first, so the value most of the fleet carries leads.
order=$(grep -E '^[0-9]+ nodes?$' <<< "$ind" | paste -sd, -)
check "largest group first" "3 nodes,1 node" "$order"

## The logs are the whole input: no Slurm state is read, so nothing about
## drains can appear here.
absent "no Slurm state is read" "drained" "$ind"
absent "and no failure grouping" "FAILED HEALTH CHECKS" "$ind"

## The node pattern is the second argument, the check name the first.
narrowed=$(run --individual beta 'node0[12]')
check "the node pattern still filters" "beta — 2 nodes" "$narrowed"

## Both of these are silent as an empty report, so both are named.
check "a check name is required" "rc=2" "$(run --individual >/dev/null 2>&1; echo "rc=$?")"
check "an unknown check says so" "No logs/<node>/nosuch found" "$(run --individual nosuch)"

## ── --diff ────────────────────────────────────────────────────────────────
## Which checks are diffed comes from the logs, not from the drain reason, so
## a node nothing drained still explains itself. This is the whole reason the
## diff moved off sync-check.sh, which read the reason field and so printed
## nothing at all with DRAIN_AFTER_FAILED_HEALTH_CHECK=no.

## node01 fails both checks and is in the queue -- no drain, no reason.
d1=$(run --diff node01)

check "an undrained node still diffs" "2 of 2 checks differ" "$d1"
check "the failing check is diffed" "--- alpha" "$d1"
check "and so is the other one" "--- beta" "$d1"

## The direction is the thing most likely to be misread: reversing it turns one
## bad baseline into a fleet of bad nodes.
check "the node side is labelled" "<  this node" "$d1"
check "and the baseline side" ">  baseline" "$d1"

## node02 is drained naming alpha, but only alpha actually differs -- beta
## matches. The count is over the gated checks, not over the reason.
d2=$(run --diff node02)
check "the drain is shown as context" "node02  (drained: alpha)" "$d2"
check "and only the differing check is diffed" "1 of 2 checks differ" "$d2"
absent "a matching check is not diffed" "--- beta" "$d2"

## --all widens it to every gated check and names the ones that match, which is
## what to reach for when the baseline itself is suspect.
d2all=$(run --diff --all node02)
check "--all names the matching checks" "Matching:  beta" "$d2all"

## A node with nothing wrong says so rather than printing an empty report.
check "a clean node is explicit" "0 of 2 checks differ" "$(run --diff node05)"

## Both of these are silent as an empty report, so both are named.
check "an unknown node says so" "nothing to diff" "$(run --diff nosuchnode 2>&1)"
check "--diff is its own report" "rc=2" \
    "$(run --diff node01 --summary >/dev/null 2>&1; echo "rc=$?")"

## --all steers only --diff, so accepting it elsewhere would read as a filter
## that quietly did nothing.
check "--all alone is refused" "rc=2" \
    "$(run --all node01 >/dev/null 2>&1; echo "rc=$?")"

## ── The two roll-ups are reports, not filters ─────────────────────────────

both=$(run --summary --drained; echo "rc=$?")
check "--summary and --drained do not combine" "rc=2" "$both"

## --individual reads its first argument as a check name, so combining it would
## silently reinterpret the caller's pattern.
check "--individual does not combine either" "rc=2" \
    "$(run --individual beta --summary >/dev/null 2>&1; echo "rc=$?")"

## ── --explain and --refresh against the heartbeat ─────────────────────────
##
## Both are read on the head node from files the node writes, so a node whose
## agent has stopped still parses: the stamp is there, the due time arrives, and
## the sentinel is queued and never consumed. That is the output being tested.
## See docs/explanation/health-cadence.md#a-due-time-assumes-a-live-node.

now=$(date +%s)
mkdir -p "$work"/results/{node01,node02,node03,node05,node06}
touch "$work/results/node01/.heartbeat" "$work/results/node05/.heartbeat" \
      "$work/results/node06/.heartbeat"
touch -d '2 hours ago' "$work/results/node02/.heartbeat"
## node03 is armed and cycling; node02 stopped; node09 was never armed at all,
## which reads identically to a stopped one from here.
touch "$work/results/node03/.heartbeat"
mkdir -p "$work/logs/node09"
for c in alpha beta; do printf 'b\ngood\n' > "$work/logs/node09/$c"; done
printf '%s\tclean\n'  "$(( now - 600 ))"   > "$work/logs/node05/.last-check"
printf '%s\tfailed\n' "$(( now - 86400 ))" > "$work/logs/node01/.last-check"
printf '%s\tfailed\n' "$(( now - 86400 ))" > "$work/logs/node02/.last-check"

explain=$(run --explain)

check "a cycling node gets a due time"        "node05" "$explain"
check "and it is a time"                      "in 1" "$explain"
check "a cycling node past its interval"      "overdue by 23h" "$explain"
check "a stopped node is not given one"       "not cycling — no check re-runs here" "$explain"
check "and the footer counts them"            "node(s) have written no heartbeat" "$explain"
check "a node with no stamp and no heartbeat" "not cycling — no agent to run them" "$explain"
check "a node with no stamp that is cycling"  "next agent cycle" "$explain"

## The queued sentinel must not read as progress on a node that cannot consume
## it: "refresh queued" alone is the line that sent an operator looking at the
## cadence for a fault that was in the agent.
touch "$work/logs/node02/refresh" "$work/logs/node05/refresh"
queued=$(run --explain)
check "a sentinel on a cycling node"      "refresh queued" "$queued"
check "a sentinel on a stopped one"       "refresh queued — not cycling, so nothing picks it up" "$queued"
rm -f "$work/logs/node02/refresh" "$work/logs/node05/refresh"

## --refresh still writes it -- the sentinel is valid the moment the node comes
## back -- and says in the same breath that nothing will pick it up yet.
queue_live=$(run --refresh node05)
queue_dead=$(run --refresh node02)
check "queueing on a cycling node"  "Refresh queued for node05" "$queue_live"
absent "and does not warn"          "has not cycled" "$queue_live"
check "queueing on a stopped node"  "has not cycled in 10m" "$queue_dead"
check "and the sentinel is written anyway" "yes" \
    "$([[ -f "$work/logs/node02/refresh" ]] && echo yes)"
rm -f "$work/logs/node02/refresh" "$work/logs/node05/refresh"

## Every other mode takes a glob, so an unquoted one reaches --refresh as a
## literal name and matches no directory. Refused with the nodeset it meant,
## rather than reported as a node that will run on its next cycle -- which is
## what it used to say, about a name that is not a node at all.
glob=$(run --refresh 'node0*')
check "a glob is refused"            "not globs" "$glob"
check "and counted"                  "5 nodes under" "$glob"
check "and spelled as a nodeset"     "--refresh 'node0" "$glob"
## Both spellings, because nodeset is ClusterShell's and a pdsh site has none.
check "with the group-expansion form" 'refresh $(nodeset -e @IDLE)' "$glob"
check "and its Slurm equivalent"      'sinfo -h -t idle -o %N' "$glob"
check "with a non-zero status"       "rc=2" \
    "$(run --refresh 'node0*' >/dev/null 2>&1; echo "rc=$?")"
absent "and queues nothing at all"   "yes" \
    "$([[ -f "$work/logs/node05/refresh" ]] && echo yes)"

## A glob nothing matches still names the form rather than going quiet.
check "a glob matching nothing"      "Nothing under" "$(run --refresh 'zzz*')"

## A name with no logs/ is a node that has never checked or a typo, and this
## cannot tell them apart -- so it must not promise a cycle for either.
missing=$(run --refresh node99)
check "an unknown name queues nothing" "Nothing queued for node99" "$missing"
check "and does not promise a cycle"   "if it is a typo, nothing will" "$missing"

## ── The node filter ───────────────────────────────────────────────────────
## Names, Slurm nodelists and globs in one argument list, over one report. The
## loop it replaces printed one report per node, so a fleet-wide fix read as
## one incident per node. See docs/reference/scripts.md#the-node-filter.

check "two names are one report" \
    "2 nodes — 1 failing, 1 passing, 0 never checked, 0 other drains" \
    "$(run node01 node05)"
check "a comma list is a nodelist" \
    "2 nodes — 1 failing, 1 passing" "$(run node01,node05)"
check "and so is a range" \
    "2 nodes — 2 failing, 0 passing" "$(run 'node0[1-2]')"

## Brackets are the nodelist spelling, so a glob has to carry a * or a ?.
check "a glob still matches anywhere"  "2 nodes — 2 failing" "$(run 'node0[12]*')"
check "a bare string is still a prefix" "8 nodes" "$(run node0)"

## The per-check tally is built before the filter, so it has to be narrowed too
## -- a header that disagrees with its body reads as a fleet-wide fault.
check "the roll-up narrows with it" "    alpha                      1 node" \
    "$(run --summary node02)"

## An argument nothing answers to is a typo or a node that has never reported,
## and dropping it silently makes both read as a clean node.
missed=$(run node01 node99)
check "a name nothing matched is named" "nothing matched: node99" "$missed"
check "and the rest is still reported"  "1 node — 1 failing" "$missed"

## The modes that take their own arguments take the filter after them.
multi=$(run --diff node01 node02)
check "--diff walks every named node"   "node01  (idle)" "$multi"
check "and the second one too"          "node02  (drained: alpha)" "$multi"
check "--explain takes the filter"      "node05" "$(run --explain node01 node05)"
absent "and nothing else"               "node03" "$(run --explain node01 node05)"
check "--individual takes it after the check" "beta — 2 nodes" \
    "$(run --individual beta node01 node05)"

## The agent writes service.log into the same directory as the check output. It is
## a log, not a check: a drain whose reason names it is an operator's drain, never a
## health drain whose logs now match (which is what a check name would make it).
## Last, with its own sinfo, so the counts above are untouched.
mkdir -p "$work/logs/node09"
for c in alpha beta; do printf 'b\ngood\n' > "$work/logs/node09/$c"; done
printf 'NODE-AGENT cycle\n' > "$work/logs/node09/service.log"
printf '#!/bin/bash\necho "node09|drained|service.log"\n' > "$work/bin/sinfo"
svc=$(run node09)
absent "service.log is not read as a check" "(logs now match) service.log" "$svc"
check "its drain is an operator drain" "service.log" "$svc"

echo
if [[ "$fails" -eq 0 ]]; then
    echo "all checks passed"
else
    echo "$fails failed"
    exit 1
fi
