#!/usr/bin/env python3
#
# Resolves an llmb-run install and reports whether the two LLM jobs can use it.
# Run as `python3 llmb_check.py`, from build_llmb.sh -- never executed directly.
#
#   --resolve   shell-quoted KEY=VALUE lines for the caller to eval
#   --report    the state table; exit 1 when a required item is missing
#
# Every path is an override-then-fallback: the SETTINGS value wins, and an empty
# one is searched for. See docs/explanation/llmb.md#adopting-an-existing-install.

import glob
import os
import platform
import shlex
import shutil
import subprocess
import sys

## The shipped cluster_config.yaml carries these; a real one never does.
## See docs/explanation/llmb.md#telling-a-real-config-from-the-template.
TEMPLATE_MARKERS = ("/path/to/", "/lustre/path/to/", "hf_token")


## ---------------------------------------------------------------- yaml ---

def _scalar(text):
    text = text.split(" #", 1)[0].strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "'\"":
        return text[1:-1]
    if text in ("null", "~", ""):
        return None
    if text in ("true", "false"):
        return text == "true"
    return text


def load_config(path):
    """The mapping/list subset cluster_config.yaml and release.yaml are written
    in. PyYAML is not on a head node's system python.
    See docs/explanation/llmb.md#reading-the-config-without-pyyaml."""
    try:
        with open(path, encoding="utf-8") as fh:
            raw = fh.readlines()
    except OSError:
        return None

    lines = []
    for line in raw:
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        lines.append((len(line) - len(line.lstrip()), line.strip()))

    value, _ = _block(lines, 0, lines[0][0] if lines else 0)
    return value if isinstance(value, dict) else {}


def _block(lines, i, indent):
    """Everything at `indent` from line i on, as a list or a mapping."""
    if i >= len(lines):
        return {}, i
    if lines[i][1].startswith("- "):
        items = []
        while i < len(lines) and lines[i][0] == indent and lines[i][1].startswith("- "):
            items.append(_scalar(lines[i][1][2:]))
            i += 1
        return items, i

    node = {}
    while i < len(lines) and lines[i][0] == indent and not lines[i][1].startswith("- "):
        key, _, rest = lines[i][1].partition(":")
        i += 1
        if rest.strip() and not rest.strip().startswith("#"):
            node[key.strip()] = _scalar(rest)
            continue
        ## Bare `key:` -- a child block if anything follows under it, else null.
        ## A list is written at the key's own indent as often as under it, and
        ## the installer picks the first: `installed:` then `- name` at the same
        ## column. See docs/explanation/llmb.md#reading-the-config-without-pyyaml.
        if i < len(lines) and (lines[i][0] > indent
                               or (lines[i][0] == indent and lines[i][1].startswith("- "))):
            node[key.strip()], i = _block(lines, i, lines[i][0])
        else:
            node[key.strip()] = None
    return node, i


def dig(data, *keys):
    node = data
    for key in keys:
        if not isinstance(node, dict):
            return None
        node = node.get(key)
    return node


## ------------------------------------------------------------ resolving ---

def first_dir(candidates):
    for path in candidates:
        for hit in sorted(glob.glob(path)):
            if os.path.isdir(hit):
                return hit
    return ""


def first_file(candidates):
    for path in candidates:
        for hit in sorted(glob.glob(path)):
            if os.path.isfile(hit):
                return hit
    return ""


def find_exe(candidates):
    for path in candidates:
        for hit in sorted(glob.glob(path)):
            if os.path.isfile(hit) and os.access(hit, os.X_OK):
                return hit
    return ""


class Install:
    def __init__(self, env):
        self.root = env.get("LLMB_INSTALL", "")
        self.up = os.path.dirname(self.root.rstrip("/")) if self.root else ""
        self.ref = env.get("LLMB_REF", "")
        self.workload = env.get("LLMB_WORKLOAD", "pretrain_llama3.1")

        ## `llmb-run` is an executable, not a directory: an install's bin/ holds
        ## uv, and the venv carrying the CLI can sit beside the root rather than
        ## in it. See docs/explanation/llmb.md#where-llmb-run-actually-lives.
        self.exe = env.get("LLMB_BIN", "")
        if self.exe and os.path.isdir(self.exe):
            self.exe = os.path.join(self.exe, "llmb-run")
        if not self.exe:
            self.exe = find_exe([
                f"{self.root}/llmb-run",
                f"{self.root}/llmb_venv/bin/llmb-run",
                f"{self.root}/venvs/*/bin/llmb-run",
                f"{self.root}/bin/llmb-run",
                f"{self.up}/llmb_venv/bin/llmb-run",
            ]) or (shutil.which("llmb-run") or "")

        self.config = env.get("LLMB_CONFIG", "") or first_file([
            f"{self.root}/cluster_config.yaml",
            f"{self.up}/cluster_config.yaml",
            f"{self.root}/src/cli/llmb-run/cluster_config.yaml",
        ])
        self.cfg = load_config(self.config) if self.config else None

        ## Falls back to a path that may not exist yet: a first install creates
        ## it, and the report says MISSING rather than naming nothing at all.
        self.images = (env.get("LLMB_IMAGES", "")
                       or first_dir([f"{self.root}/images"])
                       or f"{self.root}/images")

        cfg_hf = dig(self.cfg, "environment", "HF_HOME") or ""
        self.hf = env.get("LLMB_HF", "") or first_dir(
            [f"{self.root}/hf"] + ([cfg_hf] if cfg_hf else []) + [f"{self.up}/hf"]
        ) or f"{self.root}/hf"

        ## The collection copies its recipes beside the install; a checkout has
        ## them in src/. Either one carries release.yaml.
        cfg_repo = dig(self.cfg, "llmb_repo") or ""
        self.repo = first_dir(
            ([cfg_repo] if cfg_repo else []) + [f"{self.root}/llmb_repo", f"{self.root}/src"]
        )
        self.version, self.version_from = self._version()

    def _version(self):
        if self.repo and os.path.isdir(os.path.join(self.repo, ".git")):
            try:
                out = subprocess.run(
                    ["git", "-C", self.repo, "describe", "--tags", "--always", "--dirty"],
                    capture_output=True, text=True, timeout=30,
                )
                if out.returncode == 0 and out.stdout.strip():
                    return out.stdout.strip(), "git describe"
            except (OSError, subprocess.SubprocessError):
                pass
        for name in ("release.yaml",):
            path = os.path.join(self.repo, name) if self.repo else ""
            if path and os.path.isfile(path):
                data = load_config(path)
                got = dig(data, "llmb_version")
                if got:
                    return str(got), f"{name} llmb_version"
        return "", ""

    def is_template(self):
        if not self.cfg:
            return False
        blob = repr(self.cfg)
        return any(marker in blob for marker in TEMPLATE_MARKERS)

    def workloads(self):
        got = dig(self.cfg, "workloads", "installed")
        return got if isinstance(got, list) else []


## -------------------------------------------------------------- report ---

OK, MISS, WARN, SKIP = "ok", "MISSING", "WARN", "skip"


def rows(inst):
    """(label, state, detail, required) for every item, in reading order."""
    out = []

    root_ok = bool(inst.root) and os.path.isdir(inst.root)
    out.append(("install root", OK if root_ok else MISS,
                inst.root or "LLMB_INSTALL is empty", True))

    out.append(("llmb-run", OK if inst.exe else MISS,
                inst.exe or "not in the install, beside it, or on PATH -- set LLMB_BIN", True))

    if not inst.config:
        out.append(("cluster config", MISS, "no cluster_config.yaml found -- set LLMB_CONFIG", True))
    elif inst.is_template():
        out.append(("cluster config", MISS,
                    f"{inst.config} is the shipped template, not a real config", True))
    else:
        schema = dig(inst.cfg, "schema_version")
        detail = f"{inst.config} (schema {schema})"
        out.append(("cluster config", OK if str(schema) == "2" else WARN,
                    detail if str(schema) == "2" else detail + " -- expected 2", True))

        ## A copied or moved install keeps the absolute paths of the tree it was
        ## built in, and fails at submit rather than here.
        declared = dig(inst.cfg, "llmb_install") or ""
        same = bool(declared) and os.path.realpath(declared) == os.path.realpath(inst.root)
        out.append(("config points at", OK if same else MISS,
                    declared or "no llmb_install key", True))

        gpu = dig(inst.cfg, "gpu_type") or ""
        out.append(("gpu_type", OK if gpu else WARN, gpu or "unset", False))

        installed = inst.workloads()
        have = inst.workload in installed
        out.append(("workloads", OK if have else MISS,
                    ", ".join(installed) or "none installed", True))
        if have:
            venv = dig(inst.cfg, "workloads", "config", inst.workload, "venv_path") or ""
            out.append((f"venv for {inst.workload}",
                        OK if venv and os.path.isdir(venv) else MISS,
                        venv or "no venv_path", True))

    sqsh = sorted(glob.glob(f"{inst.images}/*.sqsh")) if inst.images else []
    out.append(("images", OK if sqsh else MISS,
                f"{len(sqsh)} in {inst.images}" if sqsh
                else f"no .sqsh under {inst.images or 'images/'}", True))

    hf_full = os.path.isdir(inst.hf) and bool(os.listdir(inst.hf))
    out.append(("tokenizer+data", OK if hf_full else MISS,
                inst.hf if hf_full else f"{inst.hf} is empty or absent -- set LLMB_HF", True))

    if not inst.ref:
        out.append(("version", SKIP, "LLMB_REF is empty -- no version gate", False))
    elif not inst.version:
        out.append(("version", MISS,
                    "cannot tell what this install is -- no git checkout and no release.yaml", True))
    else:
        want = inst.ref.lstrip("v")
        got = inst.version.lstrip("v")
        out.append(("version", OK if got == want else MISS,
                    f"{inst.version} ({inst.version_from}), want {inst.ref}", True))

    out.append(("HF_TOKEN", OK if os.environ.get("HF_TOKEN") else WARN,
                "set" if os.environ.get("HF_TOKEN") else "unset -- needed only to stage the tokenizer",
                False))

    creds = os.path.join(os.environ.get("ENROOT_CONFIG_PATH")
                         or os.path.expanduser("~/.config/enroot"), ".credentials")
    out.append(("enroot creds", OK if os.path.exists(creds) else WARN, creds, False))
    out.append(("arch", OK, platform.machine(), False))
    return out


def main(argv):
    mode = argv[1] if len(argv) > 1 else "--report"
    inst = Install(os.environ)

    if mode == "--resolve":
        for name, value in (("LLMB_BIN", os.path.dirname(inst.exe) if inst.exe else ""),
                            ("LLMB_CONFIG", inst.config),
                            ("LLMB_IMAGES", inst.images),
                            ("LLMB_HF", inst.hf),
                            ("LLMB_REPO_DIR", inst.repo),
                            ("LLMB_VERSION", inst.version)):
            print(f"{name}={shlex.quote(value)}")
        return 0

    if mode != "--report":
        print(f"usage: {argv[0]} [--resolve|--report]", file=sys.stderr)
        return 2

    missing = 0
    for label, state, detail, required in rows(inst):
        if state == MISS and required:
            missing += 1
        print(f"{label:<26} {state:<8} {detail}")

    ## A compute node reads SETTINGS, not this resolution: anything found by
    ## fallback has to be written down or the jobs will not see it.
    ## See docs/explanation/llmb.md#adopting-an-existing-install.
    candidates = (("LLMB_BIN", os.path.dirname(inst.exe) if inst.exe else ""),
                  ("LLMB_CONFIG", inst.config),
                  ("LLMB_IMAGES", inst.images),
                  ("LLMB_HF", inst.hf))
    found = [] if not os.path.isdir(inst.root or "") else [
        (name, value) for name, value in candidates
        if value and not os.environ.get(name)]
    if found:
        print("\nfound by fallback -- put these in SETTINGS so the nodes get them:")
        for name, value in found:
            print(f"  {name}={value}")

    if missing:
        print(f"\n{missing} required item(s) missing -- llm-pretrain would refuse on every node.")
        print("See docs/explanation/llmb.md#adopting-an-existing-install.")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
