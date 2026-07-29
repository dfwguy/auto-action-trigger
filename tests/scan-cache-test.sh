#!/bin/bash
#
# Usage: tests/scan-cache-test.sh
#
# Checks that the verdict cache under results/.result_cache.* can only ever
# return the answer a full scan would have returned.
#
# Every other suite here checks something that fails loudly. This one exists
# because a cache fails QUIETLY: a stale hit prints DONE for a node that would
# now fail, in a report that looks exactly like a correct one, and nothing on
# the cluster contradicts it. The framework's central rule is that a verdict is
# derived and never stored -- see docs/benchmarks.md#where-a-pass-is-decided --
# and a cache is the one thing in the tree that comes close to storing one. What
# makes it legitimate is that its key covers everything a verdict depends on.
# These cases are that claim, written down.
#
# The one that matters most is `gate edit re-judges`: the repo lowers benchmark
# floors as it learns the platform, and if a floor change did not invalidate the
# cache, every node already judged would keep its old answer silently.
#
# Builds its own results tree in a temp directory from tests/fixtures/ and needs
# no cluster, no slurm and no network.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0
fail=0
ok()  { printf 'ok       %-42s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL     %-42s %s\n' "$1" "$2"; fail=$((fail + 1)); }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

## A copy of the tree, so a case can edit a floor without touching the checkout.
cp -a "$home" "$tmp/tree" || exit 1
tree="$tmp/tree"
rm -rf "$tree/results"
mkdir -p "$tree/results"

## Four nodes is enough: the cases are about which nodes get re-judged, and one
## node changing while three do not is the whole shape.
F="$home/tests/fixtures"
for n in node01 node02 node03 node04; do
    d="$tree/results/$n"
    mkdir -p "$d"
    cp "$F/dcgm__pass.txt"                       "$d/dcgm.txt"
    cp "$F/nvbandwidth__good.txt"                "$d/nvbandwidth.txt"
    cp "$F/allreduce__good-nvlink.txt"           "$d/allreduce.txt"
    cp "$F/allreduce__good-nvlink.txt"           "$d/allreduce-forcesharp.txt"
    cp "$F/allreduce__good-nvlink.txt"           "$d/alltoall.txt"
    cp "$F/allreduce-nonvlink__ib-below-floor.txt" "$d/allreduce-nonvlink.txt"
    cp "$F/alltoall-nonvlink__container-blind.txt" "$d/alltoall-nonvlink.txt"
done

## mtime has to move for a rewrite to be seen, and these cases rewrite files
## within the same second. Real results are minutes apart at best; the cache
## uses nanosecond mtime, but the fixtures are copied faster than that.
rewrite() {
    cp "$1" "$2"
    touch -d "$(date -d '+1 hour')" "$2"
}

run()  { ( cd "$tree" && ./status-check.sh "$@" 2>/dev/null ); }

cached_run_count() {
    ## How many nodes a run actually judged, read from the cache's own records
    ## rather than inferred from timing.
    grep -c "^N" "$tree/results/.result_cache.10" 2>/dev/null || echo 0
}

# ── The cache is transparent ──────────────────────────────────────────────────

cold=$(run)
warm=$(run)
if [[ "$cold" == "$warm" ]]; then
    ok "cold and warm runs agree" "$(wc -l <<<"$warm") lines"
else
    bad "cold and warm runs agree" "the cached report differs from the computed one"
fi

nocache=$(run --no-cache)
if [[ "$nocache" == "$warm" ]]; then
    ok "--no-cache agrees with the cached run" "bypass returns the same report"
else
    bad "--no-cache agrees with the cached run" "bypassing the cache changes the report"
fi

if [[ -f "$tree/results/.result_cache.10" ]]; then
    ok "cache file is written under results/" ".result_cache.10"
else
    bad "cache file is written under results/" "no cache file after two runs"
fi

# ── The key covers the gate ───────────────────────────────────────────────────
# The case this suite exists for.

before=$(grep -c 'allreduce: DONE' <<<"$warm")
sed -i 's/^VERDICT_MIN_PEAK_BW_ALLREDUCE=683/VERDICT_MIN_PEAK_BW_ALLREDUCE=700/' \
    "$tree/parsers/nvl72/verdict.sh"
after_edit=$(run)
after=$(grep -c 'allreduce: DONE' <<<"$after_edit")
rejected=$(grep -c 'allreduce: FAIL -- peak busbw below floor 700 GB/s' <<<"$after_edit")

if [[ "$rejected" -gt 0 && "$after" -lt "$before" ]]; then
    ok "gate edit re-judges the fleet" "$before DONE -> $after, $rejected now below the new floor"
else
    bad "gate edit re-judges the fleet" \
        "raising a floor left $after DONE and rejected $rejected -- the cache is STALE"
fi

sed -i 's/^VERDICT_MIN_PEAK_BW_ALLREDUCE=700/VERDICT_MIN_PEAK_BW_ALLREDUCE=683/' \
    "$tree/parsers/nvl72/verdict.sh"
if [[ "$(run)" == "$warm" ]]; then
    ok "restoring the gate restores the report" "no residue from the edited run"
else
    bad "restoring the gate restores the report" "the report did not come back"
fi

# ── The key covers each result file ───────────────────────────────────────────

rewrite "$F/allreduce__fell-to-socket.txt" "$tree/results/node02/allreduce.txt"
changed=$(run)
if grep -q '^node02: allreduce: FAIL' <<<"$changed"; then
    ok "changed result re-judges its node" "node02 allreduce now FAIL"
else
    bad "changed result re-judges its node" "node02 still reads from the cache"
fi
if [[ "$(grep -v '^node02:' <<<"$changed")" == "$(grep -v '^node02:' <<<"$warm")" ]]; then
    ok "one node changing leaves the rest alone" "node01, node03, node04 unchanged"
else
    bad "one node changing leaves the rest alone" "unrelated nodes moved"
fi

## A rewrite of EXACTLY the same length, on a node nothing else has touched:
## the busbw at the largest message size goes 694.24 -> 094.24, six characters
## for six, which takes it under the 683 floor. Size cannot see this, so it is
## the case that says mtime has to be in the key as well. Done on node04
## deliberately -- on a node an earlier case has already resized, the size check
## would catch it and this would prove nothing.
sed 's/ 694\.24 / 094.24 /' "$F/allreduce__good-nvlink.txt" > "$tmp/samesize.txt"
if [[ "$(stat -c %s "$tmp/samesize.txt")" != "$(stat -c %s "$F/allreduce__good-nvlink.txt")" ]]; then
    bad "same-size rewrite re-judges" "the fixture edit changed the length; the case cannot run"
else
    rewrite "$tmp/samesize.txt" "$tree/results/node04/allreduce.txt"
    if grep -q '^node04: allreduce: FAIL -- peak busbw below floor' <<<"$(run)"; then
        ok "same-size rewrite re-judges" "identical length, mtime moved, node re-read"
    else
        bad "same-size rewrite re-judges" "a rewrite of equal length was served from the cache"
    fi
fi

## Deletion. The per-file check only sees files that exist, so this is the case
## that needs the count to be part of the comparison.
rm "$tree/results/node03/nvbandwidth.txt"
if grep -q '^node03: nvbandwidth: NOT_RUN' <<<"$(run)"; then
    ok "deleted result re-judges its node" "node03 nvbandwidth now NOT_RUN"
else
    bad "deleted result re-judges its node" "a removed file was served from the cache"
fi

## An archive appearing changes a cell without changing any file the cell was
## previously read from -- NOT_RUN becomes RETRY.
cp "$F/allreduce__fell-to-socket.txt" "$tree/results/node03/nvbandwidth.fail1.txt"
if grep -q '^node03: nvbandwidth: RETRY' <<<"$(run)"; then
    ok "new archive re-judges its node" "node03 nvbandwidth now RETRY"
else
    bad "new archive re-judges its node" "the archive fallback was not reconsidered"
fi

if [[ "$(cached_run_count)" -gt 0 ]]; then
    ok "cache records the nodes it scanned" "$(cached_run_count) nodes"
else
    bad "cache records the nodes it scanned" "no N records in the cache"
fi

# ── Live state is never cached ────────────────────────────────────────────────
# RUNNING comes from squeue, not from disk, so a node with a job on it has to be
# re-read every time -- its answer can change with NO file changing at all. This
# is the one case the file-based key cannot see, which is why running nodes are
# forced past the cache rather than checked by it.

## A partial result and no job: INCOMPLETE. This is what gets cached.
cp "$F/alltoall__truncated.txt" "$tree/results/node01/alltoall.txt"
incomplete=$(run)
if grep -q '^node01: alltoall: INCOMPLETE' <<<"$incomplete"; then
    ok "partial result with no job reads INCOMPLETE" "cached in that state"
else
    bad "partial result with no job reads INCOMPLETE" "setup for the running case failed"
fi

## Now the same node, same files, byte for byte -- but slurm says a job is on
## it. Nothing on disk moved, so a cache that only watched files would replay
## INCOMPLETE and report a live job as one that died.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/squeue" <<'EOF'
#!/bin/bash
echo 'bringup-node01|RUNNING'
EOF
chmod 755 "$tmp/bin/squeue"

running=$(PATH="$tmp/bin:$PATH" run)
if grep -q '^node01: alltoall: RUNNING' <<<"$running"; then
    ok "a running node is never served from cache" "same files, now reads RUNNING"
else
    bad "a running node is never served from cache" \
        "$(grep '^node01: alltoall:' <<<"$running") -- a live job reported from stale cache"
fi

## And back: the job ends, no file has changed, and it is INCOMPLETE again
## rather than stuck on the RUNNING that was true a moment ago.
if grep -q '^node01: alltoall: INCOMPLETE' <<<"$(run)"; then
    ok "the node returns to INCOMPLETE once the job is gone" "RUNNING was not cached either"
else
    bad "the node returns to INCOMPLETE once the job is gone" "RUNNING outlived the job"
fi

# ── A damaged cache is never trusted ──────────────────────────────────────────
# Truncation, a half-written file, a key from another tree: none of it may
# change the report. The cache has no authority -- it can only agree.

expected=$(run)

printf 'garbage not a cache\n' > "$tree/results/.result_cache.10"
if [[ "$(run)" == "$expected" ]]; then
    ok "corrupt cache is ignored" "report unchanged"
else
    bad "corrupt cache is ignored" "a damaged cache changed the report"
fi

head -c 200 < <(cat "$tree/results/.result_cache.10") > "$tree/results/.result_cache.10.part"
mv "$tree/results/.result_cache.10.part" "$tree/results/.result_cache.10"
if [[ "$(run)" == "$expected" ]]; then
    ok "truncated cache is ignored" "report unchanged"
else
    bad "truncated cache is ignored" "a partial cache changed the report"
fi

rm -f "$tree/results/.result_cache.10"
if [[ "$(run)" == "$expected" ]]; then
    ok "missing cache rebuilds" "report unchanged"
else
    bad "missing cache rebuilds" "the report depends on the cache existing"
fi

## The cache lives under results/, which both reports also scan for node
## directories. A dotfile is skipped by the globs; if that ever stops being
## true, the cache becomes a node.
if ! grep -q 'result_cache' <<<"$(run)"; then
    ok "cache file is not mistaken for a node" "no result_cache rows in the report"
else
    bad "cache file is not mistaken for a node" "the cache appeared as a node"
fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
