# Enable NVSM (`jobs/nvl72/nvsm.sbatch`)

> **DGX only, and not in the default benchmark list.**
> `nvsm` ships as part of DGX OS and only carries platform definition files for
> DGX platforms. On anything else it exits before doing any work, identically on
> every node, so leaving it in `BENCHMARKS` drains the whole cluster for a tool
> that was never going to run. It is omitted from the default `BENCHMARKS` list
> in `actions/launch_job.sh` for that reason — add it back only on a DGX site.
> GPU stress is covered by `dcgmi-r3` and `mnubergemm` everywhere else.

`nvsm` is the one job that runs a host binary as **root**, and the one job whose
failures are as likely to be cluster configuration as hardware. Both setup
requirements below have to be met on **every compute node**, not just the
headnode — and both only matter once you are on a DGX platform to begin with.

## Running nvsm as root

`nvsm` exits immediately for any other user:

```
ERROR:nvsm:nvsm must be run with root privileges
srun: error: node001: task 0: Exited with exit code 1
```

Jobs are submitted via `su - cmods`, and Slurm runs the task as the submitting
user — there is no way to have `srun` launch the task as root. `jobs/nvl72/nvsm.sbatch`
therefore calls `sudo -n nvsm`, which needs a passwordless sudoers grant for
`cmods`. Drop a file in `/etc/sudoers.d/` — via the BCM software image so it
survives a reprovision:

```bash
# /etc/sudoers.d/cmods-nvsm  (mode 0440, root:root)
cmods ALL=(root) NOPASSWD: /usr/bin/nvsm, /usr/sbin/nvsm
```

Use the path `command -v nvsm` reports on the node; both are listed above
because the location varies by NVSM package. Validate before deploying:

```bash
visudo -cf /etc/sudoers.d/cmods-nvsm          # as root, on the node
sudo -l | grep nvsm                           # as cmods, on the node
clush -w <node> 'sudo -n nvsm show version'   # as cmods, from the headnode
pdsh -R ssh -w <node> 'sudo -n nvsm show version'   # as cmods, from the headnode
```

The last one is the check that matters. Run it as `cmods` — `su - cmods` needs
cmods's password unless you are already root, and it is `sudo` that is
passwordless here, not `su`. Use `clush` or `pdsh` rather than a bare `ssh`: it allocates
no tty, so the run reproduces the batch task, which has none — and the same
line checks a whole rack by widening `-w`.

Do not read a working `sudo -s` as proof the grant is in place — that is a
different sudoers rule, and the per-command grant above can be missing while a
root shell still works.

If the node sets `Defaults requiretty`, add an exemption alongside the grant:

```bash
Defaults:cmods !requiretty
```

If site policy forbids the grant entirely, leave `nvsm` out of `BENCHMARKS` and
run the stress test by hand from the headnode as root
(`clush -w <nodes> 'sudo -n nvsm stress-test --force'`), outside the automated sequence.

## Platform definition files — why this is DGX only

NVSM only runs on a platform it has a definition file (PDF) for, and the
packaged PDFs cover DGX platforms. On a node it does not recognise it exits
before doing any work:

```
ERROR:nvsm:Failed to initialize NVSM: Failed to find a matching definition file for this platform.
Please toggle autogenerate_pdf flag from nvsm.config for auto generating pdf.
```

This is neither a sudo problem nor a hardware problem, and it is not
node-specific — every node of the same platform running the same NVSM package
fails identically, so `nvsm` fails its sweep and drains the whole rack for a
software gap. That is why it is not in the default `BENCHMARKS` list: on a
non-DGX platform it cannot pass, and a check that cannot pass is a check that
drains every node it runs on.

On a **non-DGX** platform, leave it out and cover GPU stress with `dcgmi-r3` and
`mnubergemm`. That is the default and needs no action.

On a **DGX** platform seeing this error, the PDF for that specific model is
missing from the installed NVSM package. Set the flag in the software image so
it survives a reprovision:

```bash
# /etc/nvsm/nvsm.config  -- on the compute node image
autogenerate_pdf = true
```

then restart the NVSM services (`systemctl restart nvsm nvsm-core nvsm-api-gateway`)
and re-check with `sudo -n nvsm show version` before adding `nvsm` back to
`BENCHMARKS`. Confirm on one node first — the failure is platform-wide, so a
single node tells you what the whole fleet will do.

## Reading a failed result

The job preflights with `nvsm show version` before spending 20 minutes on the
stress test. On failure it writes the reason and nvsm's own output above the
`FAIL` in `results/<node>/nvsm.txt`, so a setup gap is distinguishable from a
real stress-test failure:

| Result file says | Cause |
|---|---|
| `no passwordless sudo grant` | `cmods` has no NOPASSWD entry for the nvsm path |
| `sudo requires a tty` | grant is fine, but `Defaults requiretty` is set — a batch task has no tty |
| `nvsm is not on sudo's secure_path` | grant lists a path nvsm is not installed at |
| `no platform definition file` | sudo and hardware are both fine — see above |
| `This is not a sudoers failure` | anything else; the captured output below it is the diagnosis |

Only the last row is open-ended. The preflight never claims a sudoers problem
unless sudo itself said so.
