#!/bin/bash
#
# Runs the sequencer twice under two different accounts and requires the two
# traces to be the same text once the account name is substituted out. The
# scripts under test are the real ones, invoked from inside two stub trees.
#
# The suite exists because every other one sets JOB_USER=$(id -un), so the case
# the tree is actually deployed in -- root running a cycle that submits as
# somebody else -- was never covered, and neither was a second name. What that
# hid is in docs/explanation/architecture.md#one-account-name.
#
# A hardcoded account survives every unit test, because a name that is wrong
# everywhere is still consistent. The differential is what catches it: the two
# runs diverge only where something did not follow JOB_USER.

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

NODE=testnode

## Same length, so anything that pads a column to the name's width lines up in
## both runs and the diff stays about paths rather than whitespace.
USER_A=useraaa
USER_B=userbbb

pass=0
fail=0
ok()  { printf '  ok   %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }

##############################################################################
echo "== the account name appears only where it is defined =="
##############################################################################

## The shipped account is a value in two files and a literal in none. Anything
## else that names it is a path or a comparison that a site changing JOB_USER
## would not change with it -- which is how the check_trigger-debug.sh ownership check
## came to pass on the prefix and fail on the exact match at the same time.
## See docs/reference/settings.md#accounts-and-paths.
allowed='^settings\.sh:: "\$\{JOB_USER:=cmods\}"$|^SETTINGS\.default:JOB_USER=cmods$'

cd "$repo" || exit 1
stray=$(git ls-files -- '*.sh' '*.sbatch' SETTINGS.default |
        grep -v '^tests/' |
        xargs grep -n 'cmods' 2>/dev/null |
        sed 's/:[0-9]*:[[:space:]]*/:/' |
        grep -Ev "$allowed")

if [[ -z "$stray" ]]; then
    ok "cmods is a setting, not a literal"
else
    bad "the account name is hardcoded outside SETTINGS:"
    printf '         %s\n' "$stray"
fi

## A job file resolves nothing for itself, so a documented `sbatch <job>.sbatch`
## with no --export is an instruction that stops at the first path. The docs
## carried three before the paths stopped being hardcoded.
## See docs/how-to/submit-a-job-file-directly.md.
bare=$(git ls-files -- '*.md' |
       xargs grep -n 'sbatch [^|]*\.sbatch' 2>/dev/null |
       grep -v -- '--export' |
       grep -v 'bash -n\|shellcheck')

if [[ -z "$bare" ]]; then
    ok "no doc hands out an sbatch without the site paths"
else
    bad "documented sbatch invocations that would stop at their first path:"
    printf '         %s\n' "$bare"
fi

##############################################################################
echo "== two accounts, two trees, one trace =="
##############################################################################

## Stubs, so nothing below reaches a real Slurm. Deliberately silent about the
## account: the point is that whatever the sequencer passes them is what the
## diff compares, so a stub that normalised a name would hide the bug.
stub="$work/bin"
mkdir -p "$stub"

cat > "$stub/scontrol" <<'EOF'
#!/bin/bash
case "$1 $2" in
    "show node")      printf 'NodeName=%s State=IDLE Reason=none\n' "$3"; exit 0 ;;
    "show hostnames") printf '%s\n' "$3"; exit 0 ;;
esac
[[ "$1" == "listjobs" ]] && printf 'JOBID\n'
exit 0
EOF

cat > "$stub/squeue" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$stub/sinfo" <<'EOF'
#!/bin/bash
printf '%s|idle|none\n' "$3"
exit 0
EOF

for t in sbatch scancel; do
    printf '#!/bin/bash\nexit 0\n' > "$stub/$t"
done

## Records who the drop was to and what it carried, then runs the command here
## rather than through a login shell -- which would rebuild PATH and lose every
## stub above. CI runs as root, so this branch is the one it takes.
cat > "$stub/su" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/su.calls"
cmd=""; prev=""
for a in "$@"; do
    [[ "$prev" == "-c" ]] && cmd="$a"
    prev="$a"
done
exec bash -c "$cmd"
EOF

## file_copy.sh detaches its rsync and returns, so the arguments are the only
## evidence of where it decided to copy from.
cat > "$stub/rsync" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/rsync.calls"
exit 0
EOF

chmod 755 "$stub"/*

## One tree per account, laid out under that account's home so the deployed
## path differs too -- BRINGUP_HOME derives from JOB_USER, and a script that
## found its tree by a literal would read the wrong one or neither.
build_tree() {
    ## Two `local` lines, not one: a single `local a=$1 b=$a` expands $a before
    ## the first assignment lands, and both trees would be the same directory.
    local user="$1"
    local tree="$work/home/$user/bringup"
    mkdir -p "$tree/actions" "$tree/jobs/nvl72" "$tree/parsers/nvl72" \
             "$tree/results/$NODE" "$tree/containers"
    cp "$repo/settings.sh" "$repo/reason-map.sh" "$repo/slurm-recovery.sh" \
       "$repo/slurm-snapshot.sh" "$repo/check_trigger-debug.sh" "$tree/"
    cp "$repo/actions/launch_job.sh" "$repo/actions/file_copy.sh" "$tree/actions/"
    cp "$repo/parsers/nvl72/verdict.sh" "$tree/parsers/nvl72/"

    printf '#!/bin/bash\n#SBATCH -t 00:20:00\necho PENDING\n' \
        > "$tree/jobs/nvl72/probe.sbatch"
    ## The watchdog's node view. Nothing on a node asks the controller any more,
    ## so without one every gate below stops before it decides anything.
    ## See docs/explanation/the-fleet-snapshot.md.
    {
        printf 'stamp\t%s\n' "$(date +%s)"
        printf 'state\tidle\nsetter\tnone\nwhen\t\n'
        printf 'gres\tgpu:gb200:4\ncputot\t72\nfleet\t0\n'
        printf 'reason\t\n'
        printf 'end\t%s\n' "$(date +%s)"
    } > "$tree/results/$NODE/.slurm-view"
    ## An image to copy, or file_copy.sh exits before naming its source.
    : > "$tree/containers/probe.sqsh"

    ## Only JOB_USER differs between the two. Everything else is identical, so
    ## any difference in the traces came from the name.
    cat > "$tree/SETTINGS" <<EOF
JOBS=nvl72
HEALTHCHECKS=nvl72
PARSERS=nvl72
BENCHMARKS="probe"
NODE_FILTER=""
RUN_BURNIN=no
BURNIN=""
CONTAINERS=""
RUN_JOBS=yes
RUN_CONTAINER_COPY=yes
RUN_RECOVERY=no
DRAIN_AFTER_FAILED_BENCHMARK=no
RECOVER_SLURM_DRAINS=no
GET_OUT_OF_THE_WAY=no
JOB_USER=$user
BRINGUP_HOME=/home/\$JOB_USER/bringup
RESULTS_DIR=$tree/results
CONTAINER_DIR=\$BRINGUP_HOME/containers
## /opt/containers, the real default, is not this sandbox's to create -- same
## as a site that has not yet handed JOB_USER write access to it. Unlike
## BRINGUP_HOME above, file_copy.sh actually mkdir's this one, so it has to
## resolve to a real writable path rather than the symbolic account home.
NODE_CONTAINER_DIR=$tree/node-containers
LLM_HF_HOME=$tree/llm-hf
LLMB_INSTALL=
EOF
    printf '%s\n' "$tree"
}

## The tree is reached by its own path, with no *_HOME override: locating it
## from the script's own location is itself what makes a moved account work,
## so a test that pointed the scripts at their tree by hand would not test it.
run_account() {
    local user="$1"
    local tree="$2"
    local out="$work/out-$user"
    (
        export PATH="$stub:$PATH" HOME="$work/home/$user" HOSTNAME="$NODE"
        export STUB_DIR="$work/home/$user"
        ## The real script detaches its rsync and returns before it runs, so
        ## there would be nothing to compare. This is the flag it sets on itself.
        export FILE_COPY_DETACHED=1
        "$tree/actions/launch_job.sh" --explain --all
        echo "--- file_copy ---"
        "$tree/actions/file_copy.sh"
        cat "$work/home/$user/rsync.calls" 2>/dev/null
        echo "--- trigger-debug ---"
        "$tree/check_trigger-debug.sh" "$NODE"
    ) > "$out" 2>&1
    printf '%s\n' "$out"
}

tree_a=$(build_tree "$USER_A")
tree_b=$(build_tree "$USER_B")
out_a=$(run_account "$USER_A" "$tree_a")
out_b=$(run_account "$USER_B" "$tree_b")

## Substituting the name also substitutes the tree path, since the path is
## built from it -- which is the property being asserted. The trace stamps each
## line with the wall clock, so the two runs differ by a second either side of
## the minute and that has to come out too.
normalise() {
    sed -e "s/$1/ACCOUNT/g" \
        -e 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/<time>/g' "$2"
}
normalise "$USER_A" "$out_a" > "$work/norm-a"
normalise "$USER_B" "$out_b" > "$work/norm-b"

if diff -q "$work/norm-a" "$work/norm-b" >/dev/null; then
    ok "the two accounts produce the same trace"
else
    bad "the traces differ once the account name is substituted out:"
    diff "$work/norm-a" "$work/norm-b" | head -30 | sed 's/^/         /'
fi

## A trace that is identical because it is empty would pass the diff above.
if grep -q 'WOULD SUBMIT' "$work/norm-a"; then
    ok "the run got as far as a submission"
else
    bad "neither run reached a WOULD SUBMIT line -- the diff above compared nothing"
    sed 's/^/         /' "$work/norm-a" | head -20
fi

## --explain returns before the submission, so the branch that actually reaches
## the cluster needs a real one. There is no privilege drop left to take: the
## cycle is the account, and anyone else is refused by name.
## See docs/how-to/run-a-job-by-hand.md.
rm -f "$work/home/$USER_B/su.calls"
(
    export PATH="$stub:$PATH" HOME="$work/home/$USER_B" HOSTNAME="$NODE"
    export STUB_DIR="$work/home/$USER_B"
    "$tree_b/actions/launch_job.sh" --force --all --verbose
) > "$work/submit-b" 2>&1

if grep -q "a job is submitted as $USER_B" "$work/submit-b"; then
    ok "uid $EUID: refused, naming the account the submission needed"
else
    bad "uid $EUID: the refusal does not name $USER_B:"
    grep -i 'submit' "$work/submit-b" | sed 's/^/         /'
fi

## Nothing drops privilege any more, whoever runs this -- including root, which
## is how every cycle used to arrive. docs/explanation/running-unprivileged.md
if [[ -s "$work/home/$USER_B/su.calls" ]]; then
    bad "uid $EUID: went through 'su - $USER_B', which nothing should do now"
else
    ok "uid $EUID: no su on the submission path"
fi

## A batch script runs from Slurm's spool copy and can neither read SETTINGS nor
## find the tree from its own path, so the paths have to arrive on --export.
## See docs/explanation/sequencing.md#what-a-submission-carries.
for var in BRINGUP_HOME CONTAINER_DIR; do
    if grep -q "$var=/home/$USER_B/bringup" "$out_b"; then
        ok "$var reaches the job on --export"
    else
        bad "$var is not in the --export list -- the job files cannot resolve it"
    fi
done

## NODE_CONTAINER_DIR does not live under /home/$USER_B/bringup like the two
## above, so it gets its own check rather than joining that loop's pattern.
if grep -q "NODE_CONTAINER_DIR=$tree_b/node-containers" "$out_b"; then
    ok "NODE_CONTAINER_DIR reaches the job on --export"
else
    bad "NODE_CONTAINER_DIR is not in the --export list -- a bare sbatch cannot resolve it"
fi

if grep -q "LLM_HF_HOME=$tree_b/llm-hf" "$out_b"; then
    ok "LLM_HF_HOME reaches the job on --export"
else
    bad "LLM_HF_HOME is not in the --export list -- the LLM jobs cannot mount their cache"
fi

##############################################################################
echo "== the images can live outside either home =="
##############################################################################

## The reason CONTAINER_DIR is its own setting rather than a subdirectory of
## BRINGUP_HOME: images are tens of gigabytes and the bulk share is usually not
## the filesystem /home is on. See docs/explanation/containers.md#one-share-two-mount-points.
shared="$work/data/images"
mkdir -p "$shared"
: > "$shared/probe.sqsh"

cat >> "$tree_b/SETTINGS" <<EOF
CONTAINER_DIR=$shared
EOF

rm -f "$work/home/$USER_B/rsync.calls"
(
    export PATH="$stub:$PATH" HOSTNAME="$NODE" STUB_DIR="$work/home/$USER_B"
    export FILE_COPY_DETACHED=1
    "$tree_b/actions/file_copy.sh"
) >/dev/null 2>&1

if grep -q "$shared/" "$work/home/$USER_B/rsync.calls" 2>/dev/null; then
    ok "the container copy reads CONTAINER_DIR, not the tree"
else
    bad "file_copy.sh did not copy from $shared: $(cat "$work/home/$USER_B/rsync.calls" 2>/dev/null || echo '<rsync never ran>')"
fi

##############################################################################
echo "== the head node can mount that share somewhere else =="
##############################################################################

## Two mount points for one directory is the normal case for a bulk share, and
## nothing can detect the mismatch: the builder writes through the head node's
## path and the jobs read through the nodes'.
## See docs/explanation/containers.md#one-share-two-mount-points.
head_view=$(
    JOB_USER=$USER_A CONTAINER_DIR=/data/images \
    CONTAINER_DIR_HEAD=/mnt/server-1-data/images \
    SETTINGS_HOME=$work/none bash -c 'source "$0"; printf "%s %s\n" "$CONTAINER_DIR" "$CONTAINER_DIR_HEAD"' "$repo/settings.sh"
)
if [[ "$head_view" == "/data/images /mnt/server-1-data/images" ]]; then
    ok "the two views are kept apart"
else
    bad "expected '/data/images /mnt/server-1-data/images', got '$head_view'"
fi

## Defaulting to matching is what keeps a site that has one mount point from
## having to know the setting exists.
same_view=$(
    JOB_USER=$USER_A CONTAINER_DIR=/data/images SETTINGS_HOME=$work/none \
    bash -c 'source "$0"; printf "%s\n" "$CONTAINER_DIR_HEAD"' "$repo/settings.sh"
)
if [[ "$same_view" == "/data/images" ]]; then
    ok "the head view defaults to the nodes'"
else
    bad "CONTAINER_DIR_HEAD defaulted to '$same_view', not /data/images"
fi

##############################################################################
echo "== changing the account moves only the llmb install =="
##############################################################################

## BRINGUP_HOME and CONTAINER_DIR are fixed under /cluster regardless of
## JOB_USER -- neither writes to a home directory by default. LLMB_INSTALL is
## the one path still named after the account. See
## docs/reference/settings.md#accounts-and-paths.
derived=$(
    JOB_USER=$USER_B SETTINGS_HOME=$work/none \
    bash -c 'source "$0"; printf "%s %s %s\n" "$BRINGUP_HOME" "$CONTAINER_DIR" "$LLMB_INSTALL"' \
        "$repo/settings.sh"
)
want="/cluster/bringup /cluster/bringup-data/containers /home/$USER_B/llmb"
if [[ "$derived" == "$want" ]]; then
    ok "BRINGUP_HOME and CONTAINER_DIR stay fixed; LLMB_INSTALL follows JOB_USER"
else
    bad "expected '$want', got '$derived'"
fi

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
