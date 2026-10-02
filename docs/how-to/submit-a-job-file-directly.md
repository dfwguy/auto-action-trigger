# Submit a job file directly

For running one of the `jobs/$JOBS/*.sbatch` files with `sbatch` yourself,
rather than through `launch_job.sh`.

**Try `--test` first.** `launch_job.sh -t <job>` runs any job in the directory,
whether or not `BENCHMARKS` names it, and supplies everything below correctly:

```bash
clush -w ink50-dh01-h01-11 '/cluster/bringup/actions/launch_job.sh -t hpl -v'
pdsh -R ssh -w ink50-dh01-h01-11 '/cluster/bringup/actions/launch_job.sh -t hpl -v'
```

It drains nothing, leaves `quick-view.txt` alone, and the result lands where the
reports read it. See
[run-a-job-by-hand.md#running-a-job-that-is-not-in-the-list](run-a-job-by-hand.md#running-a-job-that-is-not-in-the-list).

Submit directly only when you need to change something `--test` does not expose
— a different `--nice`, a node list, an edited copy of the job file.

## What a direct submission has to supply

A batch script runs from Slurm's spool copy. It cannot read `SETTINGS`, and it
cannot find the tree from its own path, so anything the site configured has to
arrive on the command line. `launch_job.sh` passes four things; by hand, so must
you.

| What | Why |
|------|-----|
| `--export=ALL,<site paths>` | The job resolves its container and data paths from these. Which ones it needs is the table below |
| `--output=<result path>` | Where the reports look. The `#SBATCH -o` line inside each job file is deliberately disabled, because the path is per node |
| `-w <node>` | The job files do not name a node |
| `--nice=<n>` | Optional. The file carries `--nice=20`, the sweep's tier; `0` is left empty for jumping the queue. See [reference/jobs.md#queue-priority](../reference/jobs.md#queue-priority) |

## The recipe

Source `settings.sh` rather than typing paths: it yields the site's own values,
so this stays correct if the tree, the account or the image share ever moves.

```bash
cd /cluster/bringup          # or wherever BRINGUP_HOME is
source settings.sh

node=ink50-dh01-h01-11
job=cublasmatmul

sbatch -w "$node" --nice=0 \
       --export=ALL,BRINGUP_HOME="$BRINGUP_HOME",CONTAINER_DIR="$CONTAINER_DIR" \
       --output="$RESULTS_DIR/$node/$job.txt" \
       "$JOBS_DIR/$job.sbatch"
```

Run it as `JOB_USER` (`cmods` as shipped), not as root and not as yourself:
`--output` is written by Slurm as the submitting user, and `results/<node>/` is
owned by `JOB_USER`. Submitting as someone else is the
[root-owned result directory](../reference/layout.md#result-path-ownership)
failure with the owners swapped — a job id, a scheduled job, and a job that dies
at startup with nowhere to write.

## Which variables each job needs

Passing all three is harmless, and the recipe above is the safe default. If you
want the minimum:

| Variables | Jobs |
|-----------|------|
| `CONTAINER_DIR` | `allreduce`, `allreduce-forcesharp`, `alltoall`, `cublasmatmul`, `mnubergemm`, `nvbandwidth`, `nvloom`, `stream` |
| `CONTAINER_DIR` + `BRINGUP_HOME` | `hpl`, `allreduce-nonvlink`, `alltoall-nonvlink` |
| `CONTAINER_DIR` + `LLM_HF_HOME` | `llm-pretrain`, `llm-pretrain-solo` |
| none | `dcgmi-r1`…`r4`, `ethr`, `fio`, `memtester`, `nvsm`, `stress-ng`, `stressapptest` |

`BRINGUP_HOME` is what `hpl` finds its `.dat` files through and what the two
`-nonvlink` jobs source `nccl-hca.sh` from. `CONTAINER_DIR` is the shared image
directory — which need not be under the tree, and which the head node may mount
at a different path than the compute nodes do. See
[explanation/containers.md#one-share-two-mount-points](../explanation/containers.md#one-share-two-mount-points).

## What it looks like when one is missing

The job stops at its first path and says which variable it wanted, in the result
file:

```
/var/spool/slurmd/job09231/slurm_script: line 44: CONTAINER_DIR: not set --
launch_job.sh exports it; a bare sbatch must too
```

The job exits there, so the result file holds that line and no end marker, and
the reports show it `INCOMPLETE` — the same as any run that died part-way. That
is deliberate. These used to carry a hardcoded `/cluster/bringup/...`
fallback, which was silently wrong for any site that had moved its images or its
account — the job ran, found no image at the NFS path, and failed later looking
like something else entirely. Stopping at the missing variable names the actual
problem. See
[explanation/architecture.md#one-account-name](../explanation/architecture.md#one-account-name).

## Two consequences of submitting by hand

**Name it, or the sequencer will treat it as a stranger's job.** Without `-J`,
the job takes the script's filename. `launch_job.sh` counts and cancels only
`bringup-<node>` and `burnin-<node>`, and it leaves a node alone while somebody
else's job is on it — so an unnamed hand submission blocks the sweep on that
node until it finishes, which is usually what you want. To have it counted as
one of the sweep's own instead, add `-J bringup-$node`; be aware that the next
cycle may then cancel it under `RUN_JOBS=no` or the in-flight gate.

**The result is judged like any other.** It lands at
`results/<node>/<job>.txt`, so `report_job-status.sh` and `verdict.sh` will pick it
up, and it postpones that node's next ordinary sweep by up to
`RETRY_INTERVAL_HOURS` — the retry gate reads the newest mtime in the directory.
Writing it somewhere else instead keeps it out of every report.
