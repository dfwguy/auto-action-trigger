#!/bin/bash
#
# Usage: tests/scan-cache-test.sh
#
# Checks that the verdict cache can only return the answer a full scan would
# have. Every other suite here checks something that fails loudly; this one
# exists because a stale cache hit is SILENT -- it prints a clean report for a
# cluster that is not clean, and nothing contradicts it.
#
# The case that matters most is `gate edit re-judges`: floors move as the
# platform is learned, and a cache that survived that would keep every node's
# old answer. See docs/explanation/verdicts-and-the-cache.md#the-verdict-cache.
#
# Builds its own results tree from tests/fixtures/ in a temp directory. No
# cluster, no slurm, no network.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0
fail=0
ok()  { printf 'ok       %-42s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL     %-42s %s\n' "$1" "$2"; fail=$((fail + 1)); }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

## A copy of the tree: a case edits a floor, and must not touch the checkout.
cp -a "$home" "$tmp/tree" || exit 1
tree="$tmp/tree"
rm -rf "$tree/results"
mkdir -p "$tree/results"
## Keep results/ inside this copy rather than the real /cluster/bringup-data
## default -- whichever file settings.sh actually reads. Appended after
## SETTINGS.default's own RESULTS_DIR=$BRINGUP_DATA/results line, so overriding
## BRINGUP_DATA alone would not cascade; RESULTS_DIR is set directly instead.
if [[ -f "$tree/SETTINGS" ]]; then
    printf 'RESULTS_DIR=%s/results\n' "$tree" >> "$tree/SETTINGS"
else
    printf 'RESULTS_DIR=%s/results\n' "$tree" >> "$tree/SETTINGS.default"
fi

## Four is enough: one node changing while three do not is the whole shape.
F="$home/tests/fixtures"
for n in node01 node02 node03 node04; do
    d="$tree/results/$n"
    mkdir -p "$d"
    cp "$F/dcgmi-r3__pass.txt"                   "$d/dcgmi-r1.txt"
    cp "$F/dcgmi-r3__pass.txt"                   "$d/dcgmi-r3.txt"
    cp "$F/nvbandwidth__good.txt"                "$d/nvbandwidth.txt"
    cp "$F/allreduce__good-nvlink.txt"           "$d/allreduce.txt"
    cp "$F/allreduce__good-nvlink.txt"           "$d/allreduce-forcesharp.txt"
    cp "$F/allreduce__good-nvlink.txt"           "$d/alltoall.txt"
    cp "$F/allreduce-nonvlink__ib-below-floor.txt" "$d/allreduce-nonvlink.txt"
    cp "$F/alltoall-nonvlink__container-blind.txt" "$d/alltoall-nonvlink.txt"
    ## Not a result: launch_job.sh rewrites it every cycle, so on a real node it
    ## is the newest .txt in the directory almost all of the time. Pinned ahead
    ## of every rewrite() below so that is certain here, because it is what the
    ## live-column probe has to look past.
    ## See docs/reference/scripts.md.
    printf 'alltoall: IN QUEUE\n' > "$d/quick-view.txt"
    touch -d "$(date -d '+2 hours')" "$d/quick-view.txt"
done

## mtime must move for a rewrite to be seen, and these cases rewrite within the
## same nanosecond. Real results are minutes apart at best.
rewrite() {
    cp "$1" "$2"
    touch -d "$(date -d '+1 hour')" "$2"
}

## A pass-through clubak, so a real one on the developer's PATH cannot group the
## one-line-per-node rows these cases grep.
mkdir -p "$tmp/stub"
printf '#!/bin/bash\ncat\n' > "$tmp/stub/clubak"
chmod 755 "$tmp/stub/clubak"
export PATH="$tmp/stub:$PATH"

run()  { ( cd "$tree" && ./report_job-status.sh "$@" 2>/dev/null ); }

cached_run_count() {
    ## From the cache's own records, not inferred from timing.
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

## A shared results/ tree is written by whoever ran the report last, not one
## account -- 664 keeps the next writer, in a different group member's
## account, from hitting the unwritable check in scan_fleet().
mode=$(stat -c '%a' "$tree/results/.result_cache.10" 2>/dev/null)
if [[ "$mode" == "664" ]]; then
    ok "cache file is group-writable" "mode $mode"
else
    bad "cache file is group-writable" "mode $mode, want 664"
fi

# ── The key covers the gate: the case this suite exists for ──────────────────

## Appended to whichever file settings.sh reads, not substituted: a site's
## SETTINGS may not name the key, and a sed matching nothing would pass here.
sf="$tree/SETTINGS"
[[ -f "$sf" ]] || sf="$tree/SETTINGS.default"
cp "$sf" "$tmp/settings.orig"

before=$(grep -c 'allreduce: DONE' <<<"$warm")
printf 'VERDICT_MIN_PEAK_BW_ALLREDUCE=700\n' >> "$sf"
after_edit=$(run)
after=$(grep -c 'allreduce: DONE' <<<"$after_edit")
rejected=$(grep -c 'allreduce: FAIL -- peak busbw below floor 700 GB/s' <<<"$after_edit")

if [[ "$rejected" -gt 0 && "$after" -lt "$before" ]]; then
    ok "gate edit re-judges the fleet" "$before DONE -> $after, $rejected now below the new floor"
else
    bad "gate edit re-judges the fleet" \
        "raising a floor left $after DONE and rejected $rejected -- the cache is STALE"
fi

cp "$tmp/settings.orig" "$sf"
if [[ "$(run)" == "$warm" ]]; then
    ok "restoring the gate restores the report" "no residue from the edited run"
else
    bad "restoring the gate restores the report" "the report did not come back"
fi

cp "$F/deepseek-v3-proxy__good.txt" "$tree/results/node01/deepseek-v3-proxy.txt"
printf 'BENCHMARKS="deepseek-v3-proxy"\nVERDICT_MAX_STEP_MS_DEEPSEEK_V3_PROXY=0\n' >> "$sf"
proxy_cold=$(run)
proxy_warm=$(run)
printf 'VERDICT_MAX_STEP_MS_DEEPSEEK_V3_PROXY=100\n' >> "$sf"
proxy_rejected=$(run)
if [[ "$proxy_cold" == "$proxy_warm" ]] &&
   grep -q '^node01: deepseek-v3-proxy: DONE' <<<"$proxy_warm" &&
   grep -q '^node01: deepseek-v3-proxy: FAIL -- step time above 100 ms' <<<"$proxy_rejected" &&
   [[ "$proxy_rejected" == "$(run --no-cache)" ]]; then
    ok "DeepSeek ceiling invalidates warm cache" "unchanged result re-judged after threshold edit"
else
    bad "DeepSeek ceiling invalidates warm cache" "$proxy_warm -> $proxy_rejected"
fi
cp "$tmp/settings.orig" "$sf"
rm "$tree/results/node01/deepseek-v3-proxy.txt"
warm=$(run)

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

## Exactly the same length: busbw 694.24 -> 094.24, six characters for six,
## under the 683 floor. Size cannot see this, so it is what says mtime must be
## in the key too. node04 deliberately -- on a node an earlier case resized, the
## size check would catch it and this would prove nothing.
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

## Deletion: the per-file check only sees files that exist, so the count has to
## be compared too.
rm "$tree/results/node03/nvbandwidth.txt"
if grep -q '^node03: nvbandwidth: NOT_RUN' <<<"$(run)"; then
    ok "deleted result re-judges its node" "node03 nvbandwidth now NOT_RUN"
else
    bad "deleted result re-judges its node" "a removed file was served from the cache"
fi

## An archive changes a cell without touching any file it was read from.
cp "$F/allreduce__fell-to-socket.txt" "$tree/results/node03/nvbandwidth.fail1.txt"
if grep -q '^node03: nvbandwidth: FAIL' <<<"$(run)"; then
    ok "new archive re-judges its node" "node03 nvbandwidth now FAIL"
else
    bad "new archive re-judges its node" "the archive fallback was not reconsidered"
fi

## The other archive kind, and the reason the gap is not one status: a passing
## result --all asked for again is nothing to act on.
## See docs/explanation/verdicts-and-the-cache.md#a-column-between-two-attempts.
rm "$tree/results/node03/nvbandwidth.fail1.txt"
cp "$F/nvbandwidth__good.txt" "$tree/results/node03/nvbandwidth.prev1.txt"
if grep -q '^node03: nvbandwidth: RERUNNING' <<<"$(run)"; then
    ok ".prev archive reads as RERUNNING" "a re-queued pass is not a failure"
else
    bad ".prev archive reads as RERUNNING" "$(run | grep '^node03: nvbandwidth:')"
fi

if [[ "$(cached_run_count)" -gt 0 ]]; then
    ok "cache records the nodes it scanned" "$(cached_run_count) nodes"
else
    bad "cache records the nodes it scanned" "no N records in the cache"
fi

# ── Live state is never cached ────────────────────────────────────────────────
# The one case a file-based key cannot see: RUNNING comes from squeue, so the
# answer changes with no file changing at all.

## A partial result and no job: INCOMPLETE. This is what gets cached.
cp "$F/alltoall__truncated.txt" "$tree/results/node01/alltoall.txt"
incomplete=$(run)
if grep -q '^node01: alltoall: INCOMPLETE' <<<"$incomplete"; then
    ok "partial result with no job reads INCOMPLETE" "cached in that state"
else
    bad "partial result with no job reads INCOMPLETE" "setup for the running case failed"
fi

## Same node, same files byte for byte, but slurm says a job is on it. A cache
## that only watched files would report a live job as one that died.
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

## And back: the job ends, no file changed, so RUNNING must not have been kept.
if grep -q '^node01: alltoall: INCOMPLETE' <<<"$(run)"; then
    ok "the node returns to INCOMPLETE once the job is gone" "RUNNING was not cached either"
else
    bad "the node returns to INCOMPLETE once the job is gone" "RUNNING outlived the job"
fi

# ── A damaged cache is never trusted ──────────────────────────────────────────
# The cache has no authority. It can only agree.

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

## Both reports scan results/ for node directories. A dotfile is skipped by the
## globs; if that stops being true, the cache becomes a node.
if ! grep -q 'result_cache' <<<"$(run)"; then
    ok "cache file is not mistaken for a node" "no result_cache rows in the report"
else
    bad "cache file is not mistaken for a node" "the cache appeared as a node"
fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
