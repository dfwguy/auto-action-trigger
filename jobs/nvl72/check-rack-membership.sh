#!/bin/bash
# See docs/reference/jobs.md#nvloom-rack-preflight.

fail() {
    echo "preflight: $*" >&2
    exit 1
}

if [[ ${1:-} == --validate ]]; then
    declare -A seen=()
    rack_uuid=
    count=0
    while read -r node uuid extra; do
        [[ -n $node && -n $uuid && -z $extra ]] || fail "invalid rack probe record: $node $uuid $extra"
        [[ -z ${seen[$node]:-} ]] || fail "duplicate rack probe from $node"
        seen[$node]=1
        count=$((count + 1))
        echo "preflight: $node ClusterUUID=$uuid"
        [[ -z $rack_uuid || $uuid == "$rack_uuid" ]] || fail "$node belongs to a different rack ($uuid != $rack_uuid)"
        rack_uuid=$uuid
    done
    [[ $count -eq 18 ]] || fail "expected 18 distinct rack nodes, received $count"
    echo "preflight: 18 nodes share ClusterUUID=$rack_uuid"
    exit 0
fi

[[ $# -eq 0 ]] || fail "usage: bash check-rack-membership.sh [--validate]"
[[ ${SLURM_JOB_NUM_NODES:-} == 18 ]] || fail "expected 18 allocated nodes, got ${SLURM_JOB_NUM_NODES:-unknown}"
node=${SLURMD_NODENAME:-$(hostname)}
report=$(nvidia-smi -q) || fail "$node: cannot query GPU ClusterUUID"
uuids=$(awk -F: '/^[[:space:]]*ClusterUUID[[:space:]]*:/ {
    value=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value
}' <<<"$report")
[[ -n $uuids ]] || fail "$node: no GPU ClusterUUID reported"
rack_uuid=
while IFS= read -r uuid; do
    [[ $uuid =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || fail "$node: invalid GPU ClusterUUID '$uuid'"
    [[ ${uuid//[-0]/} != '' ]] || fail "$node: GPU ClusterUUID is unset (all zeros)"
    uuid=${uuid,,}
    [[ -z $rack_uuid || $uuid == "$rack_uuid" ]] || fail "$node: GPUs have different ClusterUUID values"
    rack_uuid=$uuid
done <<<"$uuids"
printf '%s %s\n' "$node" "$rack_uuid"
