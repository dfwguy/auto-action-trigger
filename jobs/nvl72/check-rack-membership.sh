#!/bin/bash
# See docs/reference/jobs.md#nvloom-rack-preflight.

readonly EXPECTED_NODES=18

fail() {
    echo "preflight: $*" >&2
    exit 1
}

validate_rack_membership() {
    local -A seen_nodes=()
    local node uuid extra
    local rack_uuid='' node_count=0

    while read -r node uuid extra; do
        if [[ -z $node || -z $uuid || -n $extra ]]; then
            fail "invalid rack probe record: $node $uuid $extra"
        fi
        if [[ -n ${seen_nodes[$node]:-} ]]; then
            fail "duplicate rack probe from $node"
        fi

        seen_nodes[$node]=1
        node_count=$((node_count + 1))
        echo "preflight: $node ClusterUUID=$uuid"

        if [[ -n $rack_uuid && $uuid != "$rack_uuid" ]]; then
            fail "$node belongs to a different rack ($uuid != $rack_uuid)"
        fi
        rack_uuid=$uuid
    done

    if [[ $node_count -ne $EXPECTED_NODES ]]; then
        fail "expected $EXPECTED_NODES distinct rack nodes, received $node_count"
    fi
    echo "preflight: $EXPECTED_NODES nodes share ClusterUUID=$rack_uuid"
}

probe_node_rack() {
    local node report uuids uuid
    local rack_uuid=''
    local uuid_pattern='^[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}$'

    if [[ ${SLURM_JOB_NUM_NODES:-} != "$EXPECTED_NODES" ]]; then
        fail "expected $EXPECTED_NODES allocated nodes, got ${SLURM_JOB_NUM_NODES:-unknown}"
    fi

    node=${SLURMD_NODENAME:-$(hostname)}
    if ! report=$(nvidia-smi -q); then
        fail "$node: cannot query GPU ClusterUUID"
    fi

    uuids=$(awk -F: '
        /^[[:space:]]*ClusterUUID[[:space:]]*:/ {
            value = $2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
        }
    ' <<<"$report")
    if [[ -z $uuids ]]; then
        fail "$node: no GPU ClusterUUID reported"
    fi

    while IFS= read -r uuid; do
        if [[ ! $uuid =~ $uuid_pattern ]]; then
            fail "$node: invalid GPU ClusterUUID '$uuid'"
        fi
        if [[ $uuid == 00000000-0000-0000-0000-000000000000 ]]; then
            fail "$node: GPU ClusterUUID is unset (all zeros)"
        fi

        uuid=${uuid,,}
        if [[ -n $rack_uuid && $uuid != "$rack_uuid" ]]; then
            fail "$node: GPUs have different ClusterUUID values"
        fi
        rack_uuid=$uuid
    done <<<"$uuids"

    printf '%s %s\n' "$node" "$rack_uuid"
}

if [[ ${1:-} == --validate ]]; then
    validate_rack_membership
elif [[ $# -eq 0 ]]; then
    probe_node_rack
else
    fail "usage: bash check-rack-membership.sh [--validate]"
fi
