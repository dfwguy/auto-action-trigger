#!/bin/bash
#
# Installs the LLM Benchmarking Collection into $LLMB_INSTALL so the
# llm-pretrain job can run on nodes that have no route off the cluster.
# Head node only, once per CPU architecture. See docs/llmb.md.
#
#   ./build_llmb.sh          # install, image, tokenizer and dataset
#   ./build_llmb.sh -l       # what is present and what is not
#   ./build_llmb.sh -d       # re-stage the tokenizer and dataset only
#   ./build_llmb.sh -i       # re-import the container image only
#
# --- end of --help text; tests/help-text-test.sh keeps the -h range in step ---

set -uo pipefail

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$home/settings.sh"

## LLMB_REF comes from SETTINGS. See docs/llmb.md#pinning-the-collection.
LLMB_REPO=https://github.com/NVIDIA/dgxc-benchmarking.git

## Llama 3.1 8B: the smallest pre-training recipe in the collection, and the
## only one that fits a 4-GPU tray. See docs/llmb.md#the-two-llm-jobs.
WORKLOAD=pretrain_llama3.1
MODEL_SIZE=8b
DTYPE=fp8

usage() { sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; }

die() { echo "ERROR: $*" >&2; exit 1; }

DO_INSTALL=1; DO_IMAGE=1; DO_DATA=1; LIST_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--list)  LIST_ONLY=1 ;;
        -d|--data)  DO_INSTALL=0; DO_IMAGE=0 ;;
        -i|--image) DO_INSTALL=0; DO_DATA=0 ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "ERROR: unrecognised argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[[ -n "$LLMB_INSTALL" ]] ||
    die "LLMB_INSTALL is empty in ${SETTINGS_FILE:-the defaults} -- nothing to install into. See docs/llmb.md#where-the-install-lives."

case "$LLMB_INSTALL" in
    "$BRINGUP_HOME"|"$BRINGUP_HOME"/*)
        die "LLMB_INSTALL=$LLMB_INSTALL is inside BRINGUP_HOME. A tarball drop replaces that tree, images and dataset included. See docs/llmb.md#where-the-install-lives." ;;
esac

arch="$(uname -m)"
hf_home="$LLMB_INSTALL/hf"
images="$LLMB_INSTALL/images"

## ── -l ────────────────────────────────────────────────────────────────────

state() { if [[ -e "$1" ]]; then echo "present"; else echo "MISSING"; fi; }

if [[ "$LIST_ONLY" -eq 1 ]]; then
    printf '%-22s %s\n' \
        "install root"  "$LLMB_INSTALL ($(state "$LLMB_INSTALL"))" \
        "collection ref"  "$LLMB_REF$([[ -d "$LLMB_INSTALL/src/.git" ]] && printf ' (checked out: %s)' "$(git -C "$LLMB_INSTALL/src" describe --tags --always 2>/dev/null)")" \
        "llmb-run"      "$(command -v llmb-run 2>/dev/null || echo 'MISSING from PATH')" \
        "images/ ($arch)" "$(state "$images")" \
        "tokenizer+data"  "$(state "$hf_home")" \
        "enroot creds"    "$(state "${ENROOT_CONFIG_PATH:-$HOME/.config/enroot}/.credentials")" \
        "HF_TOKEN"        "$([[ -n "${HF_TOKEN:-}" ]] && echo set || echo 'unset -- needed to stage the tokenizer')" \
        "cluster config"  "$(state "$LLMB_INSTALL/cluster_config.yaml")"
    exit 0
fi

## ── Preflight ─────────────────────────────────────────────────────────────

## This machine needs the network precisely because the compute nodes do not.
for tool in git enroot; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"
done

mkdir -p "$LLMB_INSTALL" || die "cannot create $LLMB_INSTALL"

## ── Install ───────────────────────────────────────────────────────────────

if [[ "$DO_INSTALL" -eq 1 ]]; then
    [[ -n "$LLMB_REF" ]] ||
        die "LLMB_REF is empty in ${SETTINGS_FILE:-the defaults} -- it names the collection tag to install. See docs/llmb.md#pinning-the-collection."

    src="$LLMB_INSTALL/src"
    if [[ -d "$src/.git" ]]; then
        git -C "$src" fetch --tags --quiet || die "git fetch failed in $src"
    else
        git clone --quiet "$LLMB_REPO" "$src" || die "git clone $LLMB_REPO failed"
    fi
    git -C "$src" checkout --quiet "$LLMB_REF" ||
        die "no such ref '$LLMB_REF' in $LLMB_REPO. Available:
$(git -C "$src" tag | tail -8 | sed 's/^/          /')"
    echo "collection at $LLMB_REF in $src"

    ## The installer owns the venv, the workload layout and cluster_config.yaml;
    ## this script owns only where they land and whether the result is usable
    ## offline. It prompts -- for the cluster settings, the workload selection
    ## and HF_TOKEN -- so this is not an unattended step the first time.
    ## -i shares the image directory across installs rather than re-importing.
    ( cd "$src" && LLMB_INSTALL="$LLMB_INSTALL" ./install.sh -i "$images" ) ||
        die "the collection installer failed -- see its output above"
fi

## ── Image ─────────────────────────────────────────────────────────────────

if [[ "$DO_IMAGE" -eq 1 ]]; then
    mkdir -p "$images"
    creds="${ENROOT_CONFIG_PATH:-$HOME/.config/enroot}/.credentials"
    [[ -f "$creds" ]] ||
        echo "NOTE: no $creds -- a gated NGC image will fail with a 401. ./build_containers.sh -L writes it."

    ## Staged into containers/ as well, so actions/file_copy.sh rsyncs it to
    ## /tmp/containers on each node like every other image. Without that, every
    ## node streams the same multi-GB squashfs off one filer at once.
    ## See docs/llmb.md#getting-the-image-to-the-nodes.
    shopt -s nullglob
    staged=0
    for sqsh in "$images"/*.sqsh; do
        cp -u "$sqsh" "$home/containers/" || die "cannot stage ${sqsh##*/} into $home/containers/"
        echo "staged ${sqsh##*/} for file_copy.sh"
        staged=$((staged + 1))
    done
    shopt -u nullglob
    [[ "$staged" -gt 0 ]] ||
        die "no .sqsh under $images -- the installer did not import an image, so there is nothing for the nodes to run. See docs/llmb.md#getting-the-image-to-the-nodes."
fi

## ── Tokenizer and dataset ─────────────────────────────────────────────────

if [[ "$DO_DATA" -eq 1 ]]; then
    [[ -n "${HF_TOKEN:-}" ]] ||
        die "HF_TOKEN is unset -- the tokenizer is gated, and the compute nodes cannot fetch it later. Export it for this run only; it is never written to a node."

    mkdir -p "$hf_home"
    ## There is no staging subcommand: the installer fetches what a workload
    ## needs when the workload is selected, into this HF_HOME. So this step is a
    ## CHECK, not a fetch -- it proves the cache the nodes will read offline is
    ## actually populated, because the failure otherwise surfaces two hours into
    ## a training run on a node with no route out.
    ## See docs/llmb.md#running-offline.
    if [[ -z "$(ls -A "$hf_home" 2>/dev/null)" ]]; then
        die "$hf_home is empty -- re-run the installer and select $WORKLOAD, with HF_TOKEN set and Llama access approved on your HF account. Llama is a GATED repo; approval is per-account and is not part of the token."
    fi

    echo "tokenizer cache present in $hf_home"
fi

## ── What is still needed ──────────────────────────────────────────────────

echo "NEXT: confirm the recipe accepts a 4-GPU tray, which is below its
      characterised floor of 8 and needs --force:
        llmb-run submit -w $WORKLOAD -s $MODEL_SIZE --dtype $DTYPE --scale 4 --force --dry-run
      and take llm-pretrain-solo's training command from the same at --scale 1.
      See docs/llmb.md#running-below-the-characterised-scale."

echo "done. './build_llmb.sh -l' for the state of the install."
