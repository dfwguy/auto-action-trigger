#!/bin/bash
#
# Checks llmb_check.py against install layouts built in a temp directory: the
# one build_llmb.sh produces, the two the collection's own installer produces,
# and the ways an adopted install is wrong.
#
# The report is the only thing standing between "somebody else's llmb install"
# and a fleet-wide run of jobs that refuse on every node two hours in, so the
# cases that matter are the ones where the tree looks fine and is not: a config
# that is the shipped template, a relocated install whose paths still name the
# machine it was built on, and a bin/ that holds uv rather than llmb-run.
#
# See docs/explanation/llmb.md#adopting-an-existing-install.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check="$home/llmb_check.py"

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT

pass=0
fail=0

ok()  { printf 'ok       %-44s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL     %-44s %s\n' "$1" "$2"; fail=$((fail + 1)); }

## Every case runs with a clean environment: an override leaking out of one
## case is exactly the bug the fallback order exists to make visible.
run() {
    env -i PATH="$PATH" HOME="$work/home" \
        LLMB_INSTALL="$1" LLMB_REF="$2" LLMB_WORKLOAD=pretrain_llama3.1 \
        LLMB_BIN="${LLMB_BIN_OVERRIDE:-}" LLMB_HF="${LLMB_HF_OVERRIDE:-}" \
        LLMB_CONFIG="${LLMB_CONFIG_OVERRIDE:-}" LLMB_IMAGES="${LLMB_IMAGES_OVERRIDE:-}" \
        python3 "$check" "${3:---report}"
}

config() {
    ## $1 install root, $2 repo dir, $3 venv path, $4 workload
    cat <<EOF
schema_version: 2
llmb_repo: "$2"
llmb_install: "$1"
gpu_type: "gb200"  # homogeneous
install:
  node_architecture: "aarch64"
environment:
  HF_TOKEN: "hf_realvalue"
slurm:
  account: "acct"
  gpu:
    partition: "gpu"
    gres: 8
  cpu:
    partition: "cpu"
    gres: null
workloads:
  installed:
    - $4
  config:
    $4:
      venv_path: "$3"
      venv_type: "venv"
EOF
}

## ── The layout the collection's installer produces ────────────────────────
## Config at the root, recipes copied to llmb_repo/, per-workload venvs, and
## the CLI venv a SIBLING of the install root. See the same docs section.

adopted="$work/ws/llmb"
mkdir -p "$adopted"/{images,llmb_repo,bin,venvs/venv_abc/bin} \
         "$work/ws/llmb_venv/bin" "$work/ws/hf" "$work/home"
touch "$adopted/images/nvidia+nemo+26.04.01.sqsh" "$work/ws/hf/tokenizer.json"
printf "llmb_version: '26.06.00'\n" > "$adopted/llmb_repo/release.yaml"
config "$adopted" "$adopted/llmb_repo" "$adopted/venvs/venv_abc" pretrain_llama3.1 \
    > "$adopted/cluster_config.yaml"

## uv, not the CLI: a fallback that adds bin/ to PATH finds this and reports a
## working install that cannot submit anything.
printf '#!/bin/sh\n' > "$adopted/bin/uv"
printf '#!/bin/sh\n' > "$work/ws/llmb_venv/bin/llmb-run"
chmod +x "$adopted/bin/uv" "$work/ws/llmb_venv/bin/llmb-run"

out=$(run "$adopted" 26.06.00)
rc=$?
if [[ "$rc" -eq 0 ]]; then
    ok "adopted install: exit status" "0"
else
    bad "adopted install: exit status" "got $rc, want 0
$out"
fi

if grep -q "llmb-run  *ok  *$work/ws/llmb_venv/bin/llmb-run" <<<"$out"; then
    ok "llmb-run found beside the root" "ws/llmb_venv/bin"
else
    bad "llmb-run found beside the root" "$(grep llmb-run <<<"$out")"
fi

if grep -q "tokenizer+data  *ok  *$work/ws/hf" <<<"$out"; then
    ok "HF cache found outside the root" "ws/hf"
else
    bad "HF cache found outside the root" "$(grep tokenizer <<<"$out")"
fi

if grep -q "venv for pretrain_llama3.1  *ok" <<<"$out"; then
    ok "venv_path read from the config" "workloads.config.<w>.venv_path"
else
    bad "venv_path read from the config" "$(grep venv <<<"$out")"
fi

if grep -q 'found by fallback' <<<"$out"; then
    ok "names the SETTINGS lines to write" "found by fallback"
else
    bad "names the SETTINGS lines to write" "no such block -- a node would not see them"
fi

## ── The shipped template ──────────────────────────────────────────────────
## The one that reads as a valid config and is a placeholder.

tmpl="$work/tmpl"
mkdir -p "$tmpl/src/cli/llmb-run" "$tmpl/images"
config "/lustre/path/to/LLMB_INSTALL" "/path/to/LLMB_REPO" "/lustre/path/to/venv" \
    pretraining_nemotron | sed 's/hf_realvalue/hf_token/' \
    > "$tmpl/src/cli/llmb-run/cluster_config.yaml"

out=$(run "$tmpl" "")
if grep -q "cluster config  *MISSING.*shipped template" <<<"$out"; then
    ok "template config rejected" "not mistaken for a real one"
else
    bad "template config rejected" "$(grep -i config <<<"$out")"
fi

## ── A relocated install ───────────────────────────────────────────────────
## Copied to another path; every absolute path inside still names the old one.

moved="$work/moved"
mkdir -p "$moved/images" "$moved/llmb_repo"
cp "$adopted/cluster_config.yaml" "$moved/"
touch "$moved/images/x.sqsh"
printf "llmb_version: '26.06.00'\n" > "$moved/llmb_repo/release.yaml"

out=$(run "$moved" 26.06.00)
rc=$?
if grep -q "config points at  *MISSING" <<<"$out" && [[ "$rc" -ne 0 ]]; then
    ok "relocated install caught" "llmb_install names the old path"
else
    bad "relocated install caught" "rc=$rc $(grep 'points at' <<<"$out")"
fi

## ── The version gate ──────────────────────────────────────────────────────

out=$(run "$adopted" v26.06.01)
rc=$?
if grep -q "version  *MISSING.*want v26.06.01" <<<"$out" && [[ "$rc" -ne 0 ]]; then
    ok "version mismatch fails" "26.06.00 against v26.06.01"
else
    bad "version mismatch fails" "rc=$rc $(grep version <<<"$out")"
fi

out=$(run "$adopted" "")
rc=$?
if grep -q "version  *skip" <<<"$out" && [[ "$rc" -eq 0 ]]; then
    ok "empty LLMB_REF skips the gate" "the house convention for no floor"
else
    bad "empty LLMB_REF skips the gate" "rc=$rc $(grep version <<<"$out")"
fi

## A `v` on one side only is the same version, and has to read as one.
out=$(run "$adopted" v26.06.00)
if grep -q "version  *ok" <<<"$out"; then
    ok "leading v is not a mismatch" "v26.06.00 against 26.06.00"
else
    bad "leading v is not a mismatch" "$(grep version <<<"$out")"
fi

## ── Overrides win ─────────────────────────────────────────────────────────

mkdir -p "$work/elsewhere/hf" && touch "$work/elsewhere/hf/tokenizer.json"
out=$(LLMB_HF_OVERRIDE="$work/elsewhere/hf" run "$adopted" "")
if grep -q "tokenizer+data  *ok  *$work/elsewhere/hf" <<<"$out"; then
    ok "LLMB_HF override beats the fallback" "elsewhere/hf"
else
    bad "LLMB_HF override beats the fallback" "$(grep tokenizer <<<"$out")"
fi

## ── --resolve is eval-safe and complete ───────────────────────────────────

resolved=$(run "$adopted" 26.06.00 --resolve)
if ( eval "$resolved" ) 2>/dev/null && grep -q '^LLMB_HF=' <<<"$resolved"; then
    ok "--resolve evals" "$(grep -c . <<<"$resolved") assignments"
else
    bad "--resolve evals" "$resolved"
fi

## A path with a space must not become two assignments when the caller evals it.
spaced="$work/with space"
mkdir -p "$spaced/images" && touch "$spaced/images/y.sqsh"
resolved=$(run "$spaced" "" --resolve)
value=$(eval "$resolved"; echo "$LLMB_IMAGES")
if [[ "$value" == "$spaced/images" ]]; then
    ok "--resolve quotes paths with spaces" "$value"
else
    bad "--resolve quotes paths with spaces" "got '$value'"
fi

## ── The indent the installer actually writes ──────────────────────────────
## A block sequence sits at its key's own column as often as under it, and the
## installer picks the first. Read as "no workloads installed", it condemns a
## working install -- which is what it did the first time this ran on a cluster.

flat="$work/flat"
mkdir -p "$flat/images" "$flat/llmb_repo" "$flat/venvs/venv_f4496d246607"
touch "$flat/images/a.sqsh"
## A wrapper at the install root, which is where this layout keeps the CLI.
printf '#!/bin/sh\n' > "$flat/llmb-run"
chmod +x "$flat/llmb-run"
printf "llmb_version: '26.06.00'\n" > "$flat/llmb_repo/release.yaml"
cat > "$flat/cluster_config.yaml" <<EOF
schema_version: 2
llmb_repo: $flat/llmb_repo
llmb_install: $flat
gpu_type: gb300
workloads:
  installed:
  - pretrain_nemotron-h
  - microbenchmark_nccl
  - pretrain_llama3.1
  config:
    microbenchmark_nccl:
      venv_path: $flat/venvs/venv_f4496d246607
      venv_type: uv
    pretrain_llama3.1:
      venv_path: $flat/venvs/venv_f4496d246607
      venv_type: uv
EOF

out=$(LLMB_HF_OVERRIDE="$work/ws/hf" run "$flat" 26.06.00)
rc=$?
if grep -q "workloads  *ok  *pretrain_nemotron-h, microbenchmark_nccl, pretrain_llama3.1" <<<"$out"; then
    ok "list at the key's own indent" "3 workloads read"
else
    bad "list at the key's own indent" "$(grep workloads <<<"$out")"
fi

## The key after the list has to survive it: a sequence that swallows its
## sibling takes workloads.config with it and the venv row reads MISSING.
if grep -q "venv for pretrain_llama3.1  *ok" <<<"$out" && [[ "$rc" -eq 0 ]]; then
    ok "the key after a list is still read" "workloads.config"
else
    bad "the key after a list is still read" "rc=$rc $(grep venv <<<"$out")"
fi

## ── SETTINGS reaches the checker ──────────────────────────────────────────
## settings.sh assigns plain shell variables, so build_llmb.sh has to name each
## one on the command that runs this file. When that broke, every gate read as
## unset and -l reported a clean install with the version check skipped.

cat > "$work/SETTINGS" <<EOF
JOBS=nvl72
HEALTHCHECKS=nvl72
PARSERS=nvl72
BRINGUP_HOME=$work/bringup
LLMB_INSTALL=$adopted
LLMB_REF=v99.99.99
LLMB_BIN=
LLMB_CONFIG=
LLMB_IMAGES=
LLMB_HF=
EOF

out=$(SETTINGS_HOME="$work" "$home/build_llmb.sh" -l 2>&1)
rc=$?
if grep -q "want v99.99.99" <<<"$out" && [[ "$rc" -ne 0 ]]; then
    ok "build_llmb.sh -l passes SETTINGS through" "LLMB_REF gated on"
else
    bad "build_llmb.sh -l passes SETTINGS through" "rc=$rc $(grep -i version <<<"$out")"
fi

if grep -q "install root  *ok  *$adopted" <<<"$out"; then
    ok "build_llmb.sh -l reads LLMB_INSTALL" "$adopted"
else
    bad "build_llmb.sh -l reads LLMB_INSTALL" "$(grep 'install root' <<<"$out")"
fi

## The install is a capture-time tool. A frozen job that mentions it has
## silently restored the runtime dependency this separation removed.
for job in "$home"/jobs/nvl72/llm-pretrain*.sbatch; do
    if ! grep -q '/opt/Megatron-Bridge/scripts/performance/run_script.py' "$job" ||
       ! grep -q 'LLM_HF_HOME' "$job" || grep -q 'LLMB_INSTALL\|LLMB_HF' "$job"; then
        bad "frozen job is independent of LLMB" "${job##*/}"
    else
        ok "frozen job is independent of LLMB" "${job##*/}"
    fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
