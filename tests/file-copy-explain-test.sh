#!/bin/bash
set -o pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

tree="$work/tree"
src="$work/shared"
dst="$work/local"
runtime="$work/runtime"
stub="$work/bin"
mkdir -p "$tree/actions" "$src" "$runtime" "$stub"
cp "$repo/actions/file_copy.sh" "$repo/settings.sh" "$tree/"
mv "$tree/file_copy.sh" "$tree/actions/file_copy.sh"
touch "$src/image.sqsh" "$src/manifest.txt"
cat > "$tree/SETTINGS" <<EOF
CONTAINER_DIR=$src
NODE_CONTAINER_DIR=$dst
RUN_CONTAINER_COPY=yes
EOF

cat > "$stub/rsync" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$RSYNC_ARGS"
printf '>f+++++++++ image.sqsh\n>f+++++++++ manifest.txt\n'
EOF
cat > "$stub/systemd-run" <<'EOF'
#!/bin/bash
touch "$DETACHED"
exit 99
EOF
cp "$stub/systemd-run" "$stub/setsid"
chmod 755 "$stub"/*

fail() { echo "FAIL: $*" >&2; exit 1; }

out=$(
    PATH="$stub:$PATH" HOSTNAME=node01 FILE_COPY_HOME="$tree" \
        XDG_RUNTIME_DIR="$runtime" RSYNC_ARGS="$work/rsync.args" \
        DETACHED="$work/detached" \
        bash "$tree/actions/file_copy.sh" --explain
) || fail "--explain exited non-zero: $out"

grep -q -- "--explain: $src/ -> $dst/" <<<"$out" ||
    fail "source and destination were not shown: $out"
grep -q '>f+++++++++ image.sqsh' <<<"$out" ||
    fail "rsync itemization was not printed: $out"
[[ ! -e "$dst" ]] || fail "--explain created the destination"
[[ ! -e "$tree/results" ]] || fail "--explain wrote a trace"
[[ ! -e "$work/detached" ]] || fail "--explain tried to detach"

mapfile -t args < "$work/rsync.args"
expected=(-a --partial --dry-run --itemize-changes "$src/" "$dst/")
[[ "${args[*]}" == "${expected[*]}" ]] ||
    fail "unexpected rsync arguments: ${args[*]}"

touch "$runtime/.bringup-file-copy.disabled-state-logged"
sed -i 's/RUN_CONTAINER_COPY=yes/RUN_CONTAINER_COPY=no/' "$tree/SETTINGS"
out=$(PATH="$stub:$PATH" HOSTNAME=node01 FILE_COPY_HOME="$tree" \
    XDG_RUNTIME_DIR="$runtime" RSYNC_ARGS="$work/rsync.args" \
    bash "$tree/actions/file_copy.sh" --explain) ||
    fail "disabled --explain exited non-zero: $out"
grep -q '>f+++++++++ image.sqsh' <<<"$out" ||
    fail "RUN_CONTAINER_COPY=no blocked the preview: $out"
grep -q 'NOTE: RUN_CONTAINER_COPY=no.*a real run starts no new copy.*previewing' <<<"$out" ||
    fail "the preview did not explain why a real copy would not run: $out"
[[ -e "$runtime/.bringup-file-copy.disabled-state-logged" ]] ||
    fail "--explain removed the disabled-state marker"

echo "file_copy --explain previews rsync without changing state"
