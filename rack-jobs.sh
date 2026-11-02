#!/bin/bash

## Read-only membership validation; sourced by actions/launch_rack_job.sh.
## See docs/explanation/nvloom-rack-design.md and docs/reference/settings.md#rack-validation.

rack_identifier_valid() {
    [[ "$1" =~ ^[[:alnum:]_][[:alnum:]_.-]*$ && "$1" != . && "$1" != .. ]]
}

rack_block() { RACK_ERRORS+=("$*"); }

rack_validate() {
    local expanded inventory header line node rack domain rest live pat matched
    local first_rack="" first_domain="" domain_count=0 common=1
    local -a filters=()
    local -A selected=() racks=() domains=() known=()
    RACK_ERRORS=(); RACK_MEMBERS=(); RACK_DOMAIN=""

    rack_identifier_valid "$RACK_ID" || rack_block "RACK_ID must name a physical rack using letters, digits, _, . or -"
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

    if [[ "$RACK_MEMBERSHIP_FILE" != /* || ! -f "$RACK_MEMBERSHIP_FILE" || ! -r "$RACK_MEMBERSHIP_FILE" ]]; then
        rack_block "membership inventory unavailable: RACK_MEMBERSHIP_FILE must name an absolute readable TSV file"
    elif ! inventory=$(cat -- "$RACK_MEMBERSHIP_FILE"); then
        rack_block "membership inventory read failed: $RACK_MEMBERSHIP_FILE"
    else
        header=${inventory%%$'\n'*}
        if [[ "$header" != $'node\track_id\tnvlink_domain_id' ]]; then
            rack_block "invalid membership header: expected node<TAB>rack_id<TAB>nvlink_domain_id"
        else
            rest=${inventory#"$header"}
            rest=${rest#$'\n'}
            while IFS= read -r line; do
                if [[ ! "$line" =~ ^([^$'\t']+)$'\t'([^$'\t']+)$'\t'([^$'\t']+)$ ]]; then
                    rack_block "malformed membership row: expected three nonempty TSV fields"
                    continue
                fi
                node=${BASH_REMATCH[1]}; rack=${BASH_REMATCH[2]}; domain=${BASH_REMATCH[3]}
                if ! rack_identifier_valid "$node" || ! rack_identifier_valid "$rack" || ! rack_identifier_valid "$domain"; then
                    rack_block "invalid membership identifiers in row for $node"
                    continue
                fi
                if [[ -n "${racks[$node]+set}" ]]; then
                    rack_block "duplicate membership row for $node (ambiguous inventory)"
                    continue
                fi
                racks[$node]=$rack; domains[$node]=$domain
            done <<< "$rest"
        fi
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
        if [[ -z "${racks[$node]+set}" ]]; then
            rack_block "unknown membership for selected node: $node"
            common=0
            continue
        fi
        [[ "${racks[$node]}" == "$RACK_ID" ]] || rack_block "physical rack mismatch: $node belongs to ${racks[$node]}, requested $RACK_ID"
        if [[ -z "$first_domain" ]]; then
            first_rack=${racks[$node]}; first_domain=${domains[$node]}
        elif [[ "${racks[$node]}" != "$first_rack" || "${domains[$node]}" != "$first_domain" ]]; then
            rack_block "mixed NVLink rack/domain membership: $node is ${racks[$node]}/${domains[$node]}, expected $first_rack/$first_domain"
            common=0
        fi
    done
    if [[ -n "$first_domain" ]]; then
        [[ "$common" -eq 1 ]] && RACK_DOMAIN=$first_domain
        for node in "${!domains[@]}"; do
            if [[ "${domains[$node]}" == "$first_domain" ]]; then
                domain_count=$((domain_count + 1))
                [[ -n "${selected[$node]+set}" ]] || rack_block "incomplete domain selection: mapped member $node was not selected"
            fi
        done
        [[ "$domain_count" -eq 18 ]] || rack_block "NVLink domain $first_domain has $domain_count mapped members; expected exactly 18"
    fi

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
    [[ "${#RACK_ERRORS[@]}" -eq 0 ]]
}

rack_explain() {
    local node reason rc=0
    rack_validate || rc=1
    printf 'Read-only NVLoom rack explanation; no files or jobs are created.\n'
    printf 'Settings: %s\nMembership source: %s\nPhysical rack: %s\nNVLink domain: %s\n' \
        "${SETTINGS_FILE:-<defaults>}" "${RACK_MEMBERSHIP_FILE:-<unset>}" "${RACK_ID:-<unset>}" "${RACK_DOMAIN:-<unconfirmed>}"
    printf 'RUN_JOBS=%s RUN_RACK_JOBS=%s RACK_SAMPLES=%s\n' "$RUN_JOBS" "$RUN_RACK_JOBS" "$RACK_SAMPLES"
    printf 'Automatic scheduling: '
    if setting_enabled "$RUN_RACK_JOBS"; then
        printf 'requested; not implemented in this step\n'
    else
        printf 'disabled; explicit manual validation remains available\n'
    fi
    printf 'Expanded members (%d entries):\n' "${#RACK_MEMBERS[@]}"
    for node in "${RACK_MEMBERS[@]}"; do printf '  %s\n' "$node"; done
    if [[ "$rc" -ne 0 ]]; then
        for reason in "${RACK_ERRORS[@]}"; do printf 'BLOCKED: %s\n' "$reason"; done
        printf 'Proposed submission: withheld because validation is blocked.\n'
        return 1
    fi
    local canonical
    canonical=$(printf '%s\n' "${RACK_MEMBERS[@]}" | LC_ALL=C sort | paste -sd, -)
    printf 'VALID: exactly 18 members of one physical rack and NVLink domain.\n'
    printf 'Proposed submission (display only; run ID is a placeholder):\n  '
    printf '%q ' env "CONTAINER_DIR=$CONTAINER_DIR" "NODE_CONTAINER_DIR=$NODE_CONTAINER_DIR" \
        "RACK_SAMPLES=$RACK_SAMPLES" sbatch -w "$canonical" -J 'racknvloom-<run-id>' \
        --export=ALL "--output=$RESULTS_DIR/nvloom-rack-%j.txt" "$JOBS_DIR/nvloom-rack-nvlink.sbatch"
    printf '\nSubmission support is not implemented. The batch allocation header still needs fixed node-count removal before submission support is added.\n'
    printf 'Live readiness, shared locking and participation have not been checked.\n'
}
