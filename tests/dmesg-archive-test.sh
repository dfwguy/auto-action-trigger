#!/bin/bash
#
# Checks check_dmesg.sh against a stubbed fan-out, scontrol and sinfo on PATH.
#
# This is the one script in the tree that destroys evidence on purpose, so the
# assertions here are mostly about what it refuses to do: a node whose buffer
# came back empty, and a node the head node has no syslog for, must survive a
# --clear untouched. Both are checked by reading the stub's own call log rather
# than the script's output, so a reassuring message cannot pass for the
# behaviour. See docs/how-to/archive-and-clear-dmesg.md.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$home" || exit 1

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

stub="$work/bin"
mkdir -p "$stub"

## Expands a nodelist and records every update, so a resume can be asserted on.
cat > "$stub/scontrol" <<'EOF'
#!/bin/bash
if [[ "$1" == "show" && "$2" == "hostnames" ]]; then
    printf '%s\n' $STUB_NODES
    exit 0
fi
printf 'scontrol %s\n' "$*" >> "$STUB_CALLS"
exit 0
EOF

cat > "$stub/sinfo" <<'EOF'
#!/bin/bash
for n in $STUB_NODES; do printf '%s|Prolog error\n' "$n"; done
EOF

## Answers dmesg only for STUB_DMESG_NODES, so a case decides which nodes come
## back empty. One reply carries colons in the message body: the demux splits on
## the first ": " only, and a kernel line is full of the things.
cat > "$stub/pdsh" <<'EOF'
#!/bin/bash
printf 'pdsh %s\n' "$*" >> "$STUB_CALLS"
case "$*" in
    *"dmesg -C"*) exit 0 ;;
esac
for n in $STUB_DMESG_NODES; do
    printf '%s: [2026-08-09T00:00:01,000] INFO: task nv:1 blocked for more than 120 seconds.\n' "$n"
    printf '%s: [2026-08-09T00:00:02,000] Call Trace: with: colons: inside\n' "$n"
done
exit 0
EOF

## The same answers from clush, which fanout() prefers. Both stubs are on PATH so
## the suite exercises whichever the resolution picks, and the assertions below
## are written not to care.
cat > "$stub/clush" <<'EOF'
#!/bin/bash
printf 'clush %s\n' "$*" >> "$STUB_CALLS"
case "$*" in
    *"dmesg -C"*) exit 0 ;;
esac
for n in $STUB_DMESG_NODES; do
    printf '%s: [2026-08-09T00:00:01,000] INFO: task nv:1 blocked for more than 120 seconds.\n' "$n"
    printf '%s: [2026-08-09T00:00:02,000] Call Trace: with: colons: inside\n' "$n"
done
exit 0
EOF

cat > "$stub/hostname" <<'EOF'
#!/bin/bash
printf 'test-hn1\n'
EOF

chmod 755 "$stub"/*

pass=0
fail=0
ok()  { printf '  ok   %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }

## One run: $1 name, rest are check_dmesg.sh options. The nodelist is appended
## here so no case can forget it and pass by hitting the "no node list" guard --
## which is how the first draft of this file scored seven green. The per-run
## directory carries the assertions: calls is the stub log, arch/ what was
## written.
RUN_DIR=""
RUN_NAME=""
run() {
    local name="$1"; shift
    RUN_DIR="$work/run-$((pass + fail))"
    mkdir -p "$RUN_DIR"
    (
        export PATH="$stub:$PATH"
        export STUB_CALLS="$RUN_DIR/calls"
        export STUB_NODES="${STUB_NODES:-n01 n02 n03}"
        export STUB_DMESG_NODES="${STUB_DMESG_NODES:-n01 n02}"
        : > "$RUN_DIR/calls"
        "$home/check_dmesg.sh" -o "$RUN_DIR/arch" "$@" 'n0[1-3]' > "$RUN_DIR/out" 2>&1
        printf '%s' "$?" > "$RUN_DIR/rc"
    )
    RUN_NAME="$name"
}

## The fan-out tool is whichever of clush/pdsh is installed, so the assertion is
## on the node list and the command, not on the spelling.
## See docs/explanation/architecture.md#reaching-nodes-is-clush-or-pdsh.
cleared()  { grep -q -- "-w $1 .*dmesg -C" "$RUN_DIR/calls"; }
resumed()  { grep -q "scontrol update NodeName=$1 State=RESUME" "$RUN_DIR/calls"; }
any_clear(){ grep -q 'dmesg -C' "$RUN_DIR/calls"; }

## The archive name carries a timestamp, so every assertion resolves it first
## rather than globbing inside a test -- `[[ -s dir/*.txt ]]` does not expand.
arch_of() { compgen -G "$RUN_DIR/arch/$1/*.txt" 2>/dev/null | head -1; }
in_arch() { local f; f=$(arch_of "$1") && [[ -n "$f" ]] && grep -q -- "$2" "$f"; }

## Two syslogs: one where n01 genuinely forwards kernel messages, and one where
## n02 is only ever mentioned by somebody else.
printf 'Aug  9 00:00:01 n01 kernel: Call Trace:\n' > "$work/syslog-n01"
printf 'Aug  9 00:00:01 n01 kernel: Call Trace:\nAug  9 00:00:02 hn1 slurmctld: node n02 drained\n' \
    > "$work/syslog-mention"
printf 'Aug  9 00:00:01 n01 kernel: x\nAug  9 00:00:01 n02 kernel: y\n' > "$work/syslog-both"

echo "== refusing to act =="

## Called directly rather than through run(), which supplies a nodelist.
RUN_DIR="$work/run-noargs"; mkdir -p "$RUN_DIR"; : > "$RUN_DIR/calls"
(
    export PATH="$stub:$PATH" STUB_CALLS="$RUN_DIR/calls"
    export STUB_NODES="n01 n02 n03" STUB_DMESG_NODES="n01"
    "$home/check_dmesg.sh" --clear > "$RUN_DIR/out" 2>&1
    printf '%s' "$?" > "$RUN_DIR/rc"
)
[[ "$(cat "$RUN_DIR/rc")" == "1" ]] &&
    ok "no node list -> exits 1" || bad "no node list -> did not refuse"
any_clear && bad "  ... and it reached a node anyway"

run "dry run writes nothing" -n --clear --resume -s "$work/syslog-both"
[[ -d "$RUN_DIR/arch" ]] && bad "$RUN_NAME -> created the archive directory" ||
    ok "$RUN_NAME -> nothing written"
any_clear && bad "  ... and it cleared a buffer during a dry run"
grep -q 'would save' "$RUN_DIR/out" ||
    bad "  ... and it did not say what it would do"

## The dry run still runs the syslog check, or the verdict it prints is a guess.
grep -q 'syslog:yes' "$RUN_DIR/out" ||
    bad "  ... and the dry run did not report a real syslog verdict"

echo "== saving =="

run "saves what came back" --clear -s "$work/syslog-both"
if [[ -s "$(arch_of n01)" ]]; then
    ok "$RUN_NAME -> n01 archived"
else
    bad "$RUN_NAME -> nothing archived for n01"
fi

## The header is the part that makes the file readable a week later.
in_arch n01 'drain reason at capture: Prolog error' ||
    bad "  ... and the archive does not say what the node was drained for"
in_arch n01 'long-term copy on test-hn1' ||
    bad "  ... and the archive does not point at the syslog copy"

## Split on the first ": " only. A kernel message is full of colons, and losing
## everything after the second one would corrupt every line silently.
if in_arch n01 'Call Trace: with: colons: inside'; then
    ok "message body with colons survives the demux"
else
    bad "message body with colons was truncated by the demux"
fi

## And it goes to the right node's file, which is the other half of a demux.
in_arch n01 '^n02' &&
    bad "  ... and n02's output landed in n01's archive" ||
    ok "each node's output landed in its own file"

echo "== what --clear refuses =="

run "empty node is never cleared" --clear --resume -s "$work/syslog-both"
cleared n03 && bad "$RUN_NAME -> cleared a node that returned no dmesg" ||
    ok "$RUN_NAME -> n03 left alone"
resumed n03 && bad "  ... and resumed it too"
grep -q 'EMPTY' "$RUN_DIR/out" || bad "  ... and it did not report the node as empty"
## The record has to say the buffer was never read, or an archive of two header
## lines reads as a node with a clean dmesg.
in_arch n03 'nothing came back' ||
    bad "  ... and n03's archive does not say nothing came back"

run "node absent from syslog is not cleared" --clear --resume -s "$work/syslog-n01"
cleared n01 || bad "$RUN_NAME -> did not clear the node syslog does have"
if grep -q 'dmesg -C' "$RUN_DIR/calls" && ! grep -q 'n02 dmesg -C' "$RUN_DIR/calls"; then
    ok "$RUN_NAME -> n02 saved but not cleared"
else
    bad "$RUN_NAME -> cleared a node with no syslog copy"
fi
grep -q 'NO SYSLOG' "$RUN_DIR/out" || bad "  ... and it did not say why"

## A line that merely names the node is not coverage: `slurmctld: node n02
## drained` proves somebody mentioned it, which is the opposite of the node
## forwarding its own kernel messages.
run "a mention is not coverage" --clear -s "$work/syslog-mention"
if grep -q 'NO SYSLOG' "$RUN_DIR/out"; then
    ok "$RUN_NAME -> n02 still reads as uncovered"
else
    bad "$RUN_NAME -> a passing mention counted as a syslog copy"
fi

run "unreadable syslog reads as no" --clear -s "$work/does-not-exist"
any_clear && bad "$RUN_NAME -> cleared with no syslog to check" ||
    ok "$RUN_NAME -> nothing cleared"

echo "== --force and the line it does not cross =="

run "force clears an uncovered node" --clear --force -s "$work/syslog-n01"
cleared "n01,n02" &&
    ok "$RUN_NAME -> n01 and n02 cleared together" ||
    bad "$RUN_NAME -> did not clear the uncovered node"
## Empty is not a syslog question, so --force must not reach it either.
grep -q 'n03' <(grep 'dmesg -C' "$RUN_DIR/calls") &&
    bad "  ... and --force cleared a node that returned nothing" ||
    ok "  ... and the empty node is still untouched"

echo "== the note a cleared buffer leaves =="

run "clearing is written into the archive" --clear -s "$work/syslog-both"
in_arch n01 'ring buffer cleared' ||
    bad "clearing left no record in the archive"
in_arch n03 'ring buffer cleared' &&
    bad "an uncleared node's archive claims it was cleared" ||
    ok "only the cleared nodes say so"

run "no --clear leaves the buffer alone" --resume -s "$work/syslog-both"
any_clear && bad "resumed without --clear but cleared anyway" ||
    ok "without --clear nothing is cleared"
resumed "n01,n02" || bad "  ... and it did not resume the saved nodes"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
