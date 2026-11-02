#!/bin/bash

usage() {
    cat <<'HELP'
Usage: actions/launch_rack_job.sh --explain [options]
  --rack-id ID             Operator run label (default: RACK_ID)
  --nodes HOSTLIST         Explicit selection (default: RACK_NODES)
  --samples COUNT          Samples per testcase (default: RACK_SAMPLES=5)
  -h, --help               Show this help
Read-only validation only. No submission, participation or cancellation.
HELP
}

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -r "$home/settings.sh" || ! -r "$home/rack-jobs.sh" || ! -r "$home/fanout.sh" ]]; then
    echo "ERROR: settings.sh, rack-jobs.sh or fanout.sh is missing from $home" >&2
    exit 1
fi
source "$home/settings.sh"
source "$home/fanout.sh"
source "$home/rack-jobs.sh"

explain=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --explain) explain=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --rack-id|--nodes|--samples)
            if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
                printf 'ERROR: %s requires a value\n' "$1" >&2
                exit 2
            fi
            case "$1" in
                --rack-id) RACK_ID=$2 ;;
                --nodes) RACK_NODES=$2 ;;
                --samples) RACK_SAMPLES=$2 ;;
            esac
            shift 2 ;;
        *) printf 'ERROR: unsupported argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done
if [[ "$explain" -ne 1 ]]; then
    usage >&2
    exit 2
fi
rack_explain
