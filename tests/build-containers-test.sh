#!/bin/bash
#
# build_containers.sh: -a is required rather than assumed from this machine,
# and a build that needs nvcr.io credentials refuses up front rather than
# discovering the missing login after a network round trip. See
# docs/how-to/build-containers.md#building-arm-images-on-an-x86-headnode and
# docs/how-to/build-containers.md#logging-in-to-ngc.
#
# Everything here stops before `enroot` is ever invoked -- "enroot is not
# installed" is the proof a case got past every gate this suite checks, since
# nothing here needs enroot, nvcr.io or a real home directory to exist.

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
ok()  { printf '  ok   %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }

## Runs the real script with an isolated HOME, so a stray -L never touches
## this account's actual ~/.config/enroot/.credentials.
run() {
    (
        export HOME="$work/home" ENROOT_CONFIG_PATH="$work/home/.config/enroot"
        mkdir -p "$HOME"
        "$repo/build_containers.sh" "$@"
    )
}

past_the_gates() { grep -q 'enroot is not installed' <<<"$1"; }

echo "== -a is required =="

out=$(run hpc-benchmarks 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && grep -q '\-a is required' <<<"$out"; then
    ok "no -a: refused, naming the fix"
else
    bad "no -a: did not refuse: $out"
fi

out=$(run -a mips hpc-benchmarks 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'unknown architecture: mips' <<<"$out"; then
    ok "bad -a value: refused, naming the value"
else
    bad "bad -a value: did not refuse: $out"
fi

out=$(run -a arm hpc-benchmarks 2>&1)
if past_the_gates "$out"; then
    ok "-a arm: past every gate"
else
    bad "-a arm: stopped before enroot: $out"
fi

echo "== -L, -l and -h need no architecture =="

out=$(NGC_API_KEY=nvapi-test run -L 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'wrote the nvcr.io entry' <<<"$out"; then
    ok "-L with no -a: still writes credentials"
else
    bad "-L with no -a: $out"
fi

out=$(run -h 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && grep -q '^Arch:' <<<"$out"; then
    ok "-h with no -a: still prints usage"
else
    bad "-h with no -a: $out"
fi

mkdir -p "$work/images"
truncate -s 1M "$work/images/one-arm.sqsh"
truncate -s 2M "$work/images/two-x86.sqsh"
out=$(run -d "$work/images" -l 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'one-arm\.sqsh' <<<"$out" &&
   grep -q 'two-x86\.sqsh' <<<"$out"; then
    ok "-l with no -a: lists the files actually present"
else
    bad "-l with no -a: $out"
fi

mkdir -p "$work/empty-images"
out=$(run -d "$work/empty-images" -l 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && grep -q '(none)' <<<"$out"; then
    ok "-l with no -a: reports an empty image directory"
else
    bad "-l with no -a on an empty directory: $out"
fi

echo "== a build needing nvcr.io refuses without a login =="

## The -L case above wrote a real credentials file into this same $HOME;
## clear it so "no login" means no login here, not leftover state.
rm -rf "$work/home/.config/enroot"

out=$(run -a arm nvbandwidth 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'not logged in to nvcr.io' <<<"$out"; then
    ok "nvbandwidth, no credentials file: refused up front"
else
    bad "nvbandwidth, no credentials file: $out"
fi

out=$(run -a arm mnubergemm 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'not logged in to nvcr.io' <<<"$out"; then
    ok "mnubergemm, no credentials file: refused up front"
else
    bad "mnubergemm, no credentials file: $out"
fi

echo "== a public image never asks about login =="

out=$(run -a arm hpc-benchmarks 2>&1)
if grep -q 'not logged in to nvcr.io' <<<"$out"; then
    bad "hpc-benchmarks was gated on a login it does not need: $out"
else
    ok "hpc-benchmarks: the login gate never fired"
fi

out=$(run -a x86 pytorch 2>&1)
if grep -q 'not logged in to nvcr.io' <<<"$out"; then
    bad "pytorch was gated on a login it does not need: $out"
elif past_the_gates "$out"; then
    ok "pytorch: a known image, and the login gate never fired"
else
    bad "pytorch: not accepted as an image: $out"
fi

echo "== --no-login bypasses the gate =="

out=$(run -a arm --no-login nvbandwidth 2>&1)
if grep -q 'not logged in to nvcr.io' <<<"$out"; then
    bad "--no-login did not bypass the gate: $out"
elif past_the_gates "$out"; then
    ok "--no-login: past the gate, reached the enroot check"
else
    bad "--no-login: stopped somewhere unexpected: $out"
fi

echo "== a real-looking credentials file opens the gate =="

mkdir -p "$work/home/.config/enroot"
printf 'machine nvcr.io\nlogin \$oauthtoken\npassword nvapi-fake\n' \
    > "$work/home/.config/enroot/.credentials"
out=$(run -a arm nvbandwidth 2>&1)
if grep -q 'not logged in to nvcr.io' <<<"$out"; then
    bad "a present nvcr.io entry still refused: $out"
elif past_the_gates "$out"; then
    ok "credentials present: past the gate, reached the enroot check"
else
    bad "credentials present: stopped somewhere unexpected: $out"
fi
rm -f "$work/home/.config/enroot/.credentials"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
