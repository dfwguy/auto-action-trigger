#!/bin/bash
#
# Checks the one-line report report_overall.sh prints by default: one line per
# node saying whether it is cycling, what Slurm calls it, and what is not
# passing on it -- with PASS under a half that has nothing outstanding.
#
# The failure this exists for is a node reading PASS for the wrong reason. An
# empty half is exactly what a pass looks like, so anything nothing ever judged
# has to put names on the line anyway or it disappears into that shape -- a
# column with no result file, a node with no logs/<node>, and a head node with
# no baseline to compare anything against. A line that says PASS is a line
# nobody reads twice, so none of the three may reach one.
#
# The rest is that the line stays names. A status word on it splits one group of
# sixty into six of ten, which is the ungrouped report with extra furniture.
#
# The real script is run against a stub tree, not a copy of its logic.
# See docs/reference/scripts.md#report_overallsh--the-fleet-in-one-line-per-node.

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

for f in settings.sh report-format.sh reason-map.sh health-scan.sh \
         verdict-scan.sh fanout.sh report_overall.sh; do
    cp "$home/$f" "$work/$f"
done
mkdir -p "$work"/{jobs/j,parsers/p,health-checks/c,valid-config/baseline,results,logs}

cat > "$work/SETTINGS" <<EOF
JOBS=j
PARSERS=p
HEALTHCHECKS=c
BENCHMARKS="allreduce hpl"
BURNIN=""
RUN_BURNIN=no
JOB_USER=$(id -un)
EXCLUDE_NODES=""
EOF
touch "$work/jobs/j/allreduce.sbatch" "$work/jobs/j/hpl.sbatch"

## The gate the fixtures are judged by. Deliberately trivial: this suite is
## about how a verdict is rendered, not about how one is reached.
cat > "$work/parsers/p/verdict.sh" <<'EOF'
verdict_job_name() { local c="$1"; printf '%s' "${c%-run[0-9]*}"; }
verdict() {
    if [[ ! -f "$2" ]]; then VERDICT_STATUS=NOT_RUN; VERDICT_REASON="no result file"; return; fi
    if grep -q PASS "$2"; then VERDICT_STATUS=DONE; VERDICT_REASON=""
    else VERDICT_STATUS=FAIL; VERDICT_REASON="below the floor"; fi
}
EOF

for c in 10-bios 20-kernel; do printf '#!/bin/bash\necho b\n' > "$work/health-checks/c/$c.sh"; done
for c in bios kernel; do printf 'good\n' > "$work/valid-config/baseline/$c"; done
ln -sfn baseline "$work/valid-config/default"

## node01 passes everything; node02 and node03 fail the same column and the same
## check, so they are one group; node04 has never run anything and has no
## logs/<node> at all.
for n in node01 node02 node03 node04; do
    mkdir -p "$work/results/$n"
    touch "$work/results/$n/.heartbeat"
done
for n in node01 node02 node03; do
    mkdir -p "$work/logs/$n"
    printf 'good\n' > "$work/logs/$n/bios"
    printf 'good\n' > "$work/logs/$n/kernel"
done
## The Slurm field, from the one sinfo the report runs. node03 is drained, so
## it leaves the group it would otherwise share with node02 -- a drained node
## and a cycling one are not one incident even when they fail the same column.
mkdir -p "$work/bin"
cat > "$work/bin/sinfo" <<'EOF'
#!/bin/bash
printf '%s\n' 'node01|idle|none|Unknown|' 'node02|mixed|none|Unknown|' \
               'node03|drained|root|2026-08-10T09:00:00|Prolog error'
EOF
chmod 755 "$work/bin/sinfo"
## A pass-through clubak, so a real one on the developer's PATH cannot group the
## lines this suite asserts one per node.
printf '#!/bin/bash\ncat\n' > "$work/bin/clubak"
chmod 755 "$work/bin/clubak"
export PATH="$work/bin:$PATH"

for n in node01 node02 node03; do echo PASS > "$work/results/$n/allreduce.txt"; done
echo PASS > "$work/results/node01/hpl.txt"
echo NOPE > "$work/results/node02/hpl.txt"
echo NOPE > "$work/results/node03/hpl.txt"
printf 'bad\n' > "$work/logs/node02/bios"
printf 'bad\n' > "$work/logs/node03/bios"

cd "$work" || exit 1
export BRINGUP_DATA="$work"

## Ungrouped: clubak is not installable in CI, and what this suite asserts is
## the content of each line rather than how the grouping tool folds them. The
## fallback is exercised by construction, and it is the same lines either way.
out=$(bash report_overall.sh 2>&1)

check "a clean node says so under each half" \
      'node01: UP **** IDLE **** tests - PASS **** healthchecks - PASS' "$out"
check "names only, both halves always spelled out" \
      'node02: UP **** MIXED **** tests - hpl **** healthchecks - bios' "$out"
check "a node that never ran is not passing either" \
      'node04: UP **** UNKNOWN **** tests - allreduce hpl' "$out"
check "the Slurm state comes from sinfo" \
      'node03: UP **** DRAINED **** tests - hpl' "$out"
check "one line per node" "4" "$(grep -c '^node0' <<< "$out")"

## The line is names. A status word on it splits one group of sixty into six of
## ten, which is the ungrouped report with extra furniture.
absent "no status word on the line" 'FAIL'    "$out"
absent "no status word on the line" 'NOT_RUN' "$out"

## The legend carries what the line does not, so it has to be there.
check "the header explains the tests half"  'tests - <benchmark columns'   "$out"
check "the header explains the checks half" 'healthchecks - <checks'       "$out"
check "the header explains the heartbeat"   'UP / DOWN - whether'          "$out"
check "the header explains the state"       "sinfo's state for it"        "$out"

## The default is the one-line report, so none of the long report's furniture
## may appear in it -- and its four section headers are how you would tell.
absent "no BENCHMARKS section by default"  '── BENCHMARKS'    "$out"
absent "no NODES section by default"       '── NODES'         "$out"

## Column order, not the order the workers happened to finish in, so the same
## two failures are the same string on every node and fold into one group.
mixed=$(cd "$work" && rm -f results/node02/allreduce.txt && bash report_overall.sh 2>&1)
check "columns are named in column order" \
      'node02: UP **** MIXED **** tests - allreduce hpl' "$mixed"
echo PASS > "$work/results/node02/allreduce.txt"

## A node nothing has ever compared has no passing check, so it carries the
## same names a node failing all of them would. An empty half is what a pass
## looks like, and neither of these is one.
check "a never-checked node names every check" \
      'node04: UP **** UNKNOWN **** tests - allreduce hpl **** healthchecks - bios kernel' "$out"

## Whether the node is still cycling comes first, because everything after it
## on the line is the last thing written rather than what is true now.
touch -d '2 hours ago' "$work/results/node04/.heartbeat"
down=$(cd "$work" && bash report_overall.sh 2>&1)
check "a stale heartbeat reads DOWN"      'node04: DOWN **** UNKNOWN' "$down"
check "a cycling node still reads UP"     'node01: UP **** IDLE'      "$down"
check "and the count is above the groups" 'written no heartbeat'     "$down"
touch "$work/results/node04/.heartbeat"

rm -f "$work/valid-config/default"
nobase=$(cd "$work" && bash report_overall.sh 2>&1)
check "no baseline names every check, on every node" \
      'node01: UP **** IDLE **** tests - PASS **** healthchecks - bios kernel' "$nobase"
absent "no baseline never reads as a pass" 'healthchecks - PASS' "$nobase"
ln -sfn baseline "$work/valid-config/default"

## --details is the old report, unchanged, and --full still implies it.
## The live trace can rotate before an operator asks for the report.  The
## recovery record preserves the named pre-job check, so it is a useful and
## safe fallback for a Prolog error rather than sending the operator to the
## node-local BCM log again.
printf '%s\tmoment\tmachine\tdrained\tslurm\tProlog error\tdmesg\n' "$(date +%s)" \
    > results/node03/recover.log
det=$(cd "$work" && bash report_overall.sh --details 2>&1)
check "--details prints the long report"   '── BENCHMARKS'    "$det"
check "--details prints the node blocks"   '── NODES'         "$det"
absent "--details is not the one-line one" ' **** '           "$det"
check "--details retains a prolog cause from recovery" \
      'prolog   the pre-job check failed on [dmesg] (results/node03/recover.log)' "$det"

fullo=$(cd "$work" && bash report_overall.sh --full 2>&1)
check "--full implies --details" '── NODES' "$fullo"

## A pattern narrows the fleet here the same way it does everywhere else.
one=$(cd "$work" && bash report_overall.sh node02 2>&1)
check "a pattern narrows the report" 'node02: UP **** MIXED **** tests - hpl' "$one"
absent "a pattern excludes the rest"  'node01:'                "$one"

## --csv is the same four fields as columns, for the nodes that are not fine.
## A node that is UP, idle or allocated and passing both halves is off it: the
## point of the format is that what is left is what has to be acted on.
csv=$(cd "$work" && bash report_overall.sh --csv 2>&1)
check "--csv names its columns"          'node,heartbeat,slurm,tests,healthchecks' "$csv"
check "--csv is comma separated"         'node02,UP,MIXED,hpl,bios'                "$csv"
check "--csv keeps a list space separated" 'node04,UP,UNKNOWN,allreduce hpl,bios kernel' "$csv"
check "--csv keeps a drained node"       'node03,UP,DRAINED,hpl,bios'              "$csv"
absent "--csv drops a passing idle node" 'node01'                                  "$csv"
absent "--csv has no legend"             '****'                                    "$csv"
absent "--csv has no notes"              'NOTE:'                                   "$csv"
check "--csv prints only the exceptions" "4" "$(grep -c ',' <<< "$csv")"

## ALLOCATED is a node doing work, not a node with something wrong with it, so
## it is dropped on the same terms as IDLE.
cat > "$work/bin/sinfo" <<'EOF'
#!/bin/bash
printf '%s\n' 'node01|allocated|none|Unknown|' 'node02|mixed|none|Unknown|' \
               'node03|drained|root|2026-08-10T09:00:00|Prolog error'
EOF
alloc=$(cd "$work" && bash report_overall.sh --csv 2>&1)
absent "--csv drops a passing allocated node" 'node01' "$alloc"
check  "--csv keeps the rest"                 'node02,UP,MIXED'  "$alloc"

## A node that is passing but not cycling stays on: everything after the first
## field is the last thing written rather than what is true now.
touch -d '2 hours ago' "$work/results/node01/.heartbeat"
stale=$(cd "$work" && bash report_overall.sh --csv 2>&1)
check "--csv keeps a DOWN node that passes" 'node01,DOWN,ALLOCATED,PASS,PASS' "$stale"
touch "$work/results/node01/.heartbeat"

## The two reports are different shapes of the same scan, and asking for both
## is asking for neither.
both=$(cd "$work" && bash report_overall.sh --csv --details 2>&1)
check "--csv and --details refuse together" 'ERROR:' "$both"

## The burn-in section goes through the same grouping tool as the main block,
## in both reports. A stub clubak marks the output, since the real one is not
## installable in CI. See docs/explanation/burn-in-waveform.md.
printf 'totalRuns=1\nSTEP_TIMELIMIT=02:00:00\n' > "$work/jobs/j/burn.sbatch"
printf '#!/bin/bash\necho GROUPED\ncat\n' > "$work/bin/clubak"
echo DONE > "$work/results/node01/burn.txt"
sed -i 's/^BURNIN=.*/BURNIN="burn"/; s/^RUN_BURNIN=.*/RUN_BURNIN=yes/' "$work/SETTINGS"
printf 'BURNIN_HOURS=48\n' >> "$work/SETTINGS"
printf 'verdict() { if [[ -f "$2" ]] && grep -qE "PASS|DONE" "$2"; then VERDICT_STATUS=DONE; else VERDICT_STATUS=NOT_RUN; fi; VERDICT_REASON=""; }\nverdict_job_name() { printf %%s "${1%%-run[0-9]*}"; }\n' \
    > "$work/parsers/p/verdict.sh"
burn=$(cd "$work" && bash report_overall.sh 2>&1)
check "brief burn-in is grouped"   $'BURN-IN\nGROUPED'     "$burn"
check "brief burn-in carries hours" 'node01: 2H/48H'         "$burn"
burn=$(cd "$work" && bash report_overall.sh --details 2>&1)
check "details burn-in is grouped" $'BURN-IN\nGROUPED'     "$burn"

echo
if [[ "$fails" -eq 0 ]]; then
    echo "all checks passed"
else
    echo "$fails check(s) failed"
fi
[[ "$fails" -eq 0 ]]
