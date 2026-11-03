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
site's rack/domain inventory. Replace the example list with those nodes:

```bash
rack_nodes='node[01-18]'
scontrol show hostnames "$rack_nodes"
sbatch -w "$rack_nodes" \
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

Submit one `sbatch` for the whole rack. Keep this job out of `BENCHMARKS`,
`BURNIN` and `CONTINUE_RUNNING_JOBS`, and do not fan out
`launch_job.sh -t nvloom-rack-nvlink` across nodes: that launcher makes
per-node decisions rather than coordinating one selected rack allocation.

Leave `MPI_IFACE` unset to use the batch host's default-route interface.
The sourced `jobs/nvl72/nvloom-prechecks.sh` helper exports it through
`OMPI_MCA_btl_tcp_if_include` and `OMPI_MCA_oob_tcp_if_include` for MPI
coordination. If the site needs an override, export `MPI_IFACE` before
submission and select a routable host
interface whose name and connectivity work on every selected node. Do not
choose a Spectrum-X rail/VRF-only interface. This test exercises NVLink;
it needs no NCCL SPCX plugin or HCA-selection settings.

## 5. Read the result

Use the recorded job ID to watch the queue and locate the log. For a rack
test, for example:

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
