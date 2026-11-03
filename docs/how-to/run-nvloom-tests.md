# Run NVLoom tests

Use `nvloom` for a single four-GPU node, or `nvloom-rack-nvlink` for a
manually selected NVL72 rack/domain. Both are exploratory tests. The
[job reference](../reference/jobs.md#nvloom-jobs) lists their suites,
parameters and result checks.

## 1. Prepare the image and nodes

Both jobs need Pyxis/Enroot, four visible GPUs per node, and healthy IMEX
with populated `/dev/nvidia-caps-imex-channels/` devices. Check the site's
IMEX health results before submitting; the allocation preflight does not
establish that the NVLink domain is healthy.

Build the image using [the NVLoom build procedure](build-containers.md#nvloom).
On an x86 head node preparing an ARM image, the two passes are:

```bash
./build_containers.sh -a arm -F nvloom
srun -N1 ./build_containers.sh -a arm -B nvloom
```

The build pass needs an allocated ARM node. For a build host of the same
architecture, use `./build_containers.sh -a arm -S nvloom` instead. The
shipped jobs expect `nvloom-v2.0.0-arm.sqsh` on ARM, or
`nvloom-v2.0.0-x86.sqsh` on x86. Changing `NVLOOM_VERSION` in settings changes
the builder's output name, not the version hardcoded in the job files.

Make that image readable on every selected node, either in
`NODE_CONTAINER_DIR` or in the compute-node view of `CONTAINER_DIR`.
The jobs prefer the node-local copy. See
[the container paths](../explanation/containers.md#one-share-two-mount-points)
if the head node and compute nodes mount the image share differently.

## 2. Load the site's paths

Run the submissions as `JOB_USER` (`cmods` by default) from the deployed
tree on the head node:

```bash
cd /cluster/bringup
source settings.sh
run_dir="$BRINGUP_DATA/nvloom-runs"
mkdir -p "$run_dir"
```

Use the site's deployment path if it differs. Confirm that `run_dir` is
writable by `JOB_USER` and shared at the same path on the head node and
selected nodes. These examples keep logs outside per-node `results/`
directories and give each submission a separate file using Slurm's `%j`
job ID substitution.

Use `JOBS=nvl72` with `PARSERS=nvl72`, or `JOBS=nvl72-spx` with
`PARSERS=spectrum-x`, in the site's settings. The examples use `JOBS_DIR`
and `PARSERS_DIR` resolved by `settings.sh`; the rack job is available in
both job sets.

## 3. Submit a single-node test

Replace the example node with one four-GPU node you intend to test:

```bash
node=node01
sbatch -w "$node" \
    --export=ALL,CONTAINER_DIR="$CONTAINER_DIR",NODE_CONTAINER_DIR="$NODE_CONTAINER_DIR" \
    --output="$run_dir/nvloom-%j.txt" \
    "$JOBS_DIR/nvloom.sbatch"
```

Record the job ID printed by `sbatch`. This runs the single-node suites
without enabling `nvloom` in `BENCHMARKS`. The commented burn-in command in
the file stays disabled.

For a single-node result in the framework's usual location, you can instead
use `launch_job.sh -t nvloom` as described in
[run a job by hand](run-a-job-by-hand.md#running-a-job-that-is-not-in-the-list).
That path supplies the environment, archives previous results and lets
`report_job-status.sh -t nvloom` read the result.

## 4. Submit one rack-wide NVLink test

Select **exactly 18 four-GPU nodes from one NVLink rack/domain** using the
site's rack/domain inventory. The framework does not discover a rack from
node names, partition membership or whichever nodes happen to be idle.

### Through the launcher

`nvloom-rack-nvlink` is the only multinode job supported by
`actions/launch_job.sh`. In the site's resolved `SETTINGS` file, configure:

```bash
RUN_MULTINODE_NVLOOM=yes
MULTINODE_NVLOOM_NODES='node[01-18]'
```

Both settings ship disabled or empty. Replace the example list with the
selected rack's nodes. Enabling the switch permits an explicit `--test`
invocation; normal agent cycles never submit the rack job. Keep it out of
`BENCHMARKS`, `BURNIN` and `CONTINUE_RUNNING_JOBS`; the launcher traces and
skips an entry in any of those lists.

As `JOB_USER`, invoke the launcher **once on one selected node**, for
example `node01`. Preview it, then submit without `--explain`:

```bash
clush -w node01 '/cluster/bringup/actions/launch_job.sh --test nvloom-rack-nvlink --explain -v'
pdsh -R ssh -w node01 '/cluster/bringup/actions/launch_job.sh --test nvloom-rack-nvlink --explain -v'

clush -w node01 '/cluster/bringup/actions/launch_job.sh --test nvloom-rack-nvlink -v'
pdsh -R ssh -w node01 '/cluster/bringup/actions/launch_job.sh --test nvloom-rack-nvlink -v'
```

Choose either `clush` or `pdsh` for each step. Do not fan this invocation out
to all 18 nodes or combine it with another `--test` job. The launcher expands
the configured list, rejects invalid counts or duplicate nodes, and passes
the complete list with `--nodelist` and its validated count with `--nodes`.
The sorted first node supplies a stable coordinator name, `nvloom-rack-node01`;
it does not select the rack and need not be the node issuing the command.

Fresh watchdog views must exist for all selected nodes. Queued framework
jobs, allocated jobs, in-flight markers and inconclusive views stop submission.
`SUBMIT_ONLY_WHEN_IDLE=yes` also requires all 18 nodes to be exactly idle.
The launcher honors `RUN_JOBS=no`, and `--test` cannot bypass
`RUN_MULTINODE_NVLOOM=no`. Rack membership is still checked inside the
allocation before the workload starts.

The trace prints the job ID and a unique log under
`$RESULTS_DIR/.multinode-nvloom/`. This path is advisory: it returns before
benchmark verdicts, drain recovery, resume and drain logic. It creates no
per-node `.in-flight` marker, so the watchdog's `MAX_JOB_HOURS` drain does
not apply. Slurm's job and step time limits still bound execution. Results
do not enter required benchmark status or authorize any node state change.

A shared lock serializes submissions. The `submission` receipt is written
before `sbatch`; a second request must see a newer watchdog view confirming
that the previous request is no longer queued. A failed or timed-out
submission is not retried automatically because Slurm may have accepted it.
After the watchdog confirms the queue is clear, another explicit invocation
can run again; previous logs are retained, including incomplete attempts.
The `nvloom-rack-` job name is outside the framework's automatic cancellation
prefixes. `RUN_JOBS=no` stops new submissions; use `scancel <job-id>` yourself
to stop an already queued or running rack job.

### Direct submission

A direct `sbatch` bypasses the launcher's enable switch, queue guards and
submission receipt. Supply the node count as well as the selected list:

```bash
rack_nodes='node[01-18]'
scontrol show hostnames "$rack_nodes"
sbatch --nodes=18 -w "$rack_nodes" \
    --export=ALL,BRINGUP_HOME="$BRINGUP_HOME",CONTAINER_DIR="$CONTAINER_DIR",NODE_CONTAINER_DIR="$NODE_CONTAINER_DIR",RACK_SAMPLES=5 \
    --output="$run_dir/nvloom-rack-nvlink-%j.txt" \
    "$JOBS_DIR/nvloom-rack-nvlink.sbatch"
```

`scontrol show hostnames` only expands the list; it does not check rack or
domain membership. Before NVLoom starts, the job runs the
[rack preflight](../reference/jobs.md#nvloom-rack-preflight) through `srun`
on every allocated node. It requires exactly 18 distinct nodes whose GPU
ClusterUUID values identify one rack. Failed or inconclusive queries stop
the job. Node-name order and Slurm partition membership are not evidence
that nodes share an NVLink domain.

The job files have no hardcoded `#SBATCH -N` line. The caller supplies the
count: `-w` names nodes, while Slurm can use a subset or add nodes according
to the resource request. Matching `--nodes=18` to the 18 selected nodes
requests the complete rack. See the
[Slurm nodelist reference](https://slurm.schedmd.com/sbatch.html#OPT_nodelist).

Leave `MPI_IFACE` unset to use the batch host's default-route interface.
The sourced `jobs/nvl72/nvloom-prechecks.sh` helper exports it through
`OMPI_MCA_btl_tcp_if_include` and `OMPI_MCA_oob_tcp_if_include` for MPI
coordination. If the site needs an override, export `MPI_IFACE` before
submission and select a routable host
interface whose name and connectivity work on every selected node. Do not
choose a Spectrum-X rail/VRF-only interface. This test exercises NVLink;
it needs no NCCL SPCX plugin or HCA-selection settings.

## 5. Read the result

Use the recorded job ID to watch the queue and locate the log. The launcher
prints the full log path; direct submissions above use `run_dir`. For a
direct rack test, for example:

```bash
job_id=12345
squeue -j "$job_id"
log="$run_dir/nvloom-rack-nvlink-$job_id.txt"
tail -n 40 "$log"
```

Inspect the complete log after the job finishes. The final `PENDING` marker
means the workload exited zero; it is not a quality verdict, and is
unrelated to Slurm's queued `PENDING` state. `FAIL` means preflight or the
workload failed. A missing final marker means there is no completed result.

For a completed single-node log, set `job_id` to that submission's ID and
run the configured parser offline:

```bash
source "$PARSERS_DIR/verdict.sh"
verdict nvloom "$run_dir/nvloom-$job_id.txt"
printf '%s: %s\n%s\n' "$VERDICT_STATUS" "$VERDICT_REASON" "$VERDICT_DETAIL"
```

The parser checks for a rack GUID and known errors; bandwidth matrices
still need review.
The rack job currently has no dedicated parser dispatch: passing
`nvloom-rack-nvlink` to `verdict` uses only the generic checks. A generic
`DONE` does not establish rack membership, completion of all NVLoom suites,
or acceptable bandwidth. Review rack logs manually and retain a real run
for future parser validation.

If rack preflight fails, read the node's `ClusterUUID=` line and the
reported reason. For single-node allocation failures, read the `gpus=` and
`cores=` line. For `MPI_Allgather` / `EADDRNOTAVAIL`, check the reported
MPI coordination interface and its reachability on all selected nodes. For CUDA, IMEX or
NVLink errors, retain the full log and investigate the named node or GPU
before repeating the test. Do not add `--gpus-per-task`: NVLoom assigns
GPUs by MPI local rank and needs all four GPUs visible to every rank.
