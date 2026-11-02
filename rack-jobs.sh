#!/bin/bash

## Read-only membership validation; sourced by actions/launch_rack_job.sh.
## See docs/explanation/nvloom-rack-design.md and docs/reference/settings.md#rack-validation.

rack_identifier_valid() {
    [[ "$1" =~ ^[[:alnum:]_][[:alnum:]_.-]*$ && "$1" != . && "$1" != .. ]]
}

rack_block() { RACK_ERRORS+=("$*"); }

declare -A RACK_NODE_DOMAINS=()

rack_probe_domains() {
    local canonical output line node text value first="" rc lower
    local ct cmd
    local -A counts=() exits=() selected=()
    for node in "${RACK_MEMBERS[@]}"; do selected[$node]=1; done
    read -r ct cmd < <(fanout_timeouts)
    if [[ "$ct" -eq 0 || "$cmd" -eq 0 ]]; then
        rack_block "live identity probes require positive fan-out connection and command timeouts"
        return
    fi
    if ! fanout_resolve; then
        rack_block "live identity probe unavailable: $FANOUT_WHY"
        return
    fi
    canonical=$(printf '%s\n' "${RACK_MEMBERS[@]}" | LC_ALL=C sort | paste -sd, -)
    output=$(fanout "$canonical" 'LC_ALL=C nvidia-smi -q; rack_probe_rc=$?; printf "__NVLOOM_PROBE_EXIT__=%s\n" "$rack_probe_rc"; exit "$rack_probe_rc"'); rc=$?
    [[ "$rc" -eq 0 ]] || rack_block "live identity fan-out failed (exit $rc): timeout, unreachable node or probe failure"
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if [[ ! "$line" =~ ^([^:[:space:]]+):[[:space:]]?(.*)$ ]]; then
            rack_block "unattributed live probe output: $line"
            continue
        fi
        node=${BASH_REMATCH[1]}; text=${BASH_REMATCH[2]}
        if [[ -z "${selected[$node]+set}" ]]; then
            rack_block "unexpected node or transport diagnostic in live probe output: $line"
            continue
        fi
        if [[ "$text" =~ ^__NVLOOM_PROBE_EXIT__=([0-9]+)$ ]]; then
            value=${BASH_REMATCH[1]}
            [[ -z "${exits[$node]+set}" ]] || rack_block "duplicate probe completion from $node"
            exits[$node]=$value
            [[ "$value" -eq 0 ]] || rack_block "$node: nvidia-smi probe failed (exit $value)"
            continue
        fi
        lower=${text,,}
        if [[ "$lower" =~ ^[[:space:]]*cluster[[:space:]]*uuid[[:space:]]*: ]]; then
            counts[$node]=$(( ${counts[$node]:-0} + 1 ))
            value=${lower#*:}
            value=${value#"${value%%[![:space:]]*}"}
            value=${value%"${value##*[![:space:]]}"}
            if [[ ! "$value" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ||
                  "$value" == 00000000-0000-0000-0000-000000000000 ]]; then
                rack_block "$node: missing or invalid ClusterUUID: ${value:-<empty>}"
            elif [[ -n "${RACK_NODE_DOMAINS[$node]+set}" && "${RACK_NODE_DOMAINS[$node]}" != "$value" ]]; then
                rack_block "$node: GPUs disagree on ClusterUUID (${RACK_NODE_DOMAINS[$node]} versus $value)"
            else
                RACK_NODE_DOMAINS[$node]=$value
            fi
        fi
    done <<< "$output"
    for node in "${RACK_MEMBERS[@]}"; do
        [[ -n "${exits[$node]+set}" ]] || rack_block "$node: missing successful probe completion (unreachable, timed out or incomplete output)"
        [[ "${counts[$node]:-0}" -eq 4 ]] || rack_block "$node: expected 4 GPU ClusterUUID readings; found ${counts[$node]:-0}"
        if [[ -n "${RACK_NODE_DOMAINS[$node]+set}" ]]; then
            value=${RACK_NODE_DOMAINS[$node]}
            if [[ -z "$first" ]]; then
                first=$value
            elif [[ "$value" != "$first" ]]; then
                rack_block "mixed NVLink domains: $node ClusterUUID=$value, expected $first"
            fi
        fi
    done
    [[ "${#RACK_ERRORS[@]}" -ne 0 ]] || RACK_DOMAIN=$first
}

rack_validate() {
    local expanded node live pat matched
    local -a filters=()
    local -A selected=() known=()
    RACK_ERRORS=(); RACK_MEMBERS=(); RACK_DOMAIN=""; RACK_NODE_DOMAINS=()

    rack_identifier_valid "$RACK_ID" || rack_block "RACK_ID must be a run label using letters, digits, _, . or -"
    [[ "$RACK_SAMPLES" =~ ^[1-9][0-9]*$ ]] || rack_block "RACK_SAMPLES must be a positive integer"
    if ! setting_enabled "$RUN_RACK_JOBS" && ! setting_disabled "$RUN_RACK_JOBS"; then
        rack_block "RUN_RACK_JOBS must be yes/no, true/false, on/off or 1/0"
    fi
    if ! setting_enabled "$RUN_JOBS"; then
        rack_block "RUN_JOBS=$RUN_JOBS: global pause or invalid switch blocks manual and automatic rack submission"
    fi
    [[ -z "${SBATCH_NODES:-}" ]] || rack_block "SBATCH_NODES is set: inherited allocation node-count overrides are not allowed"
    [[ -r "$JOBS_DIR/nvloom-rack-nvlink.sbatch" ]] || rack_block "missing rack launcher: $JOBS_DIR/nvloom-rack-nvlink.sbatch"

    if [[ -z "$RACK_NODES" ]]; then
        rack_block "RACK_NODES is empty: select exactly 18 nodes"
    elif ! command -v scontrol >/dev/null 2>&1; then
        rack_block "scontrol unavailable: cannot expand RACK_NODES"
    elif ! expanded=$(scontrol show hostnames "$RACK_NODES" 2>&1); then
        rack_block "node expansion failed: ${expanded:-no evidence}"
    elif [[ -z "$expanded" ]]; then
        rack_block "node expansion returned no members"
    else
        while IFS= read -r node; do
            if ! rack_identifier_valid "$node"; then
                rack_block "invalid expanded node: $node"
                continue
            fi
            RACK_MEMBERS+=("$node")
            if [[ -n "${selected[$node]+set}" ]]; then
                rack_block "duplicate selected node: $node"
            fi
            selected[$node]=1
        done <<< "$expanded"
        [[ "${#selected[@]}" -eq 18 ]] || rack_block "expected exactly 18 distinct nodes; found ${#selected[@]} (${#RACK_MEMBERS[@]} expanded entries)"
    fi

    read -r -a filters <<< "$NODE_FILTER"
    for node in "${RACK_MEMBERS[@]}"; do
        node_excluded "$node" && rack_block "excluded node: $node matches EXCLUDE_NODES"
        if [[ "${#filters[@]}" -gt 0 ]]; then
            matched=0
            for pat in "${filters[@]}"; do
                # shellcheck disable=SC2053  # NODE_FILTER is a list of shell globs.
                [[ "$node" == $pat ]] && matched=1
            done
            [[ "$matched" -eq 1 ]] || rack_block "filtered node: $node does not match NODE_FILTER"
        fi
    done
    if ! command -v sinfo >/dev/null 2>&1; then
        rack_block "Slurm inventory unavailable: sinfo is not on PATH"
    elif ! live=$(sinfo -N -h -o '%N' 2>&1); then
        rack_block "Slurm inventory query failed: ${live:-no evidence}"
    elif [[ -z "$live" ]]; then
        rack_block "Slurm inventory query returned no evidence"
    else
        while IFS= read -r node; do
            if rack_identifier_valid "$node"; then
                known[$node]=1
            else
                rack_block "inconclusive Slurm inventory record: $node"
            fi
        done <<< "$live"
        for node in "${RACK_MEMBERS[@]}"; do
            [[ -n "${known[$node]+set}" ]] || rack_block "selected node absent from Slurm inventory: $node"
        done
    fi
    if [[ "${#RACK_ERRORS[@]}" -eq 0 ]]; then rack_probe_domains; fi
    [[ "${#RACK_ERRORS[@]}" -eq 0 ]]
}

rack_explain() {
    local node reason rc=0
    rack_validate || rc=1
    printf 'Read-only NVLoom rack explanation; no files or jobs are created.\n'
    printf 'Settings: %s\nMembership source: %s\nRack label (operator supplied): %s\nNVLink domain: %s\n' \
        "${SETTINGS_FILE:-<defaults>}" "live nvidia-smi -q ClusterUUID via fanout.sh" "${RACK_ID:-<unset>}" "${RACK_DOMAIN:-<unconfirmed>}"
    printf 'RUN_JOBS=%s RUN_RACK_JOBS=%s RACK_SAMPLES=%s\n' "$RUN_JOBS" "$RUN_RACK_JOBS" "$RACK_SAMPLES"
    printf 'Automatic scheduling: '
    if setting_enabled "$RUN_RACK_JOBS"; then
        printf 'requested; not implemented in this step\n'
    else
        printf 'disabled; explicit manual validation remains available\n'
    fi
    printf 'Expanded members (%d entries):\n' "${#RACK_MEMBERS[@]}"
    for node in "${RACK_MEMBERS[@]}"; do
        printf '  %s  ClusterUUID=%s\n' "$node" "${RACK_NODE_DOMAINS[$node]:-<unconfirmed>}"
    done
    if [[ "$rc" -ne 0 ]]; then
        for reason in "${RACK_ERRORS[@]}"; do printf 'BLOCKED: %s\n' "$reason"; done
        printf 'Proposed submission: withheld because validation is blocked.\n'
        return 1
    fi
    local canonical
    canonical=$(printf '%s\n' "${RACK_MEMBERS[@]}" | LC_ALL=C sort | paste -sd, -)
    printf 'VALID: exactly 18 distinct nodes with one common live ClusterUUID.\n'
    printf 'Proposed submission (display only; run ID is a placeholder):\n  '
    printf '%q ' env "CONTAINER_DIR=$CONTAINER_DIR" "NODE_CONTAINER_DIR=$NODE_CONTAINER_DIR" \
        "RACK_SAMPLES=$RACK_SAMPLES" sbatch -w "$canonical" -J 'racknvloom-<run-id>' \
        --export=ALL "--output=$RESULTS_DIR/nvloom-rack-%j.txt" "$JOBS_DIR/nvloom-rack-nvlink.sbatch"
    printf '\nSubmission support is not implemented. The batch allocation header still needs fixed node-count removal before submission support is added.\n'
    printf 'ClusterUUID does not verify physical rack location. Health, shared locking and participation have not been checked.\n'
}
