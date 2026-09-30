#!/bin/bash
set -o pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/tree/actions" "$work/runtime"
cp "$repo/actions/file_copy.sh" "$repo/settings.sh" "$work/tree/"
mv "$work/tree/file_copy.sh" "$work/tree/actions/file_copy.sh"
printf 'RUN_CONTAINER_COPY=no\nBRINGUP_DATA=%s\n' "$work/tree" > "$work/tree/SETTINGS"

run() {
    HOSTNAME=node01 FILE_COPY_HOME="$work/tree" XDG_RUNTIME_DIR="$work/runtime" \
        bash "$work/tree/actions/file_copy.sh"
}

run
marker="$work/runtime/.bringup-file-copy.disabled-state-logged"
[[ -e "$marker" ]] || { echo 'disabled cycle did not record its node-local log suppression state' >&2; exit 1; }
first=$(stat -c %Y "$work/tree/results/node01/copy.log")
sleep 1
run
second=$(stat -c %Y "$work/tree/results/node01/copy.log")
[[ "$first" == "$second" ]] || { echo 'disabled cycle rewrote the shared trace' >&2; exit 1; }
[[ "$(wc -l < "$work/tree/results/node01/copy.log")" -eq 1 ]] || { echo 'disabled state was logged more than once' >&2; exit 1; }

printf 'RUN_CONTAINER_COPY=yes\nBRINGUP_DATA=%s\n' "$work/tree" > "$work/tree/SETTINGS"
run
[[ ! -e "$marker" ]] || { echo 'enabling copies did not clear the log suppression marker' >&2; exit 1; }

printf 'RUN_CONTAINER_COPY=no\nBRINGUP_DATA=%s\n' "$work/tree" > "$work/tree/SETTINGS"
run
[[ "$(grep -c 'RUN_CONTAINER_COPY=no' "$work/tree/results/node01/copy.log")" -eq 2 ]] || {
    echo 'a new disabled period was not logged' >&2
    exit 1
}
echo 'the marker suppresses repeat logs but does not keep copying disabled'
