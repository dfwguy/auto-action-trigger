# Explain an NVLoom rack selection

`actions/launch_rack_job.sh --explain` validates a proposed fixed 18-node
selection. It prints evidence, expanded members, blocking reasons and a
hypothetical command. It creates no files, requests, participation records or
jobs, even when `RUN_RACK_JOBS=yes`. Single-node scheduling is unchanged.

## Prepare trusted membership evidence

The nodes provide the evidence directly. No site-owned membership file or
saved health log is used. All 18 selected nodes must be reachable through
`fanout.sh`, and each must support `nvidia-smi -q` without privilege escalation.
The command uses `clush` by preference or `pdsh -R ssh`; the existing
`FANOUT_TOOL` setting selects the tool. Positive `FANOUT_CONNECT_TIMEOUT` and
`FANOUT_COMMAND_TIMEOUT` values are required (defaults: 10 and 60 seconds).

Each node must return four valid, nonzero GPU ClusterUUID readings. They must
match within the node and across all 18 nodes. Empty, unavailable, malformed,
zero or conflicting identities fail validation, as do missing responses and
failed or timed-out probes. This step uses ClusterUUID consistently and does
not launch NVLoom to obtain rackGuid.

To inspect the live evidence manually, use either equivalent form:

```bash
clush -w '<selected-nodes>' 'nvidia-smi -q'
pdsh -R ssh -w '<selected-nodes>' 'nvidia-smi -q'
```

The detected UUID identifies the reported fabric domain. `RACK_ID` is only an
operator label: a matching UUID does not establish physical rack location.
See the [membership design](../explanation/nvloom-rack-design.md#membership-needs-site-input).

## Run the explanation

Set these keys in the site settings found through `settings.sh`:

```bash
RUN_RACK_JOBS=no
RACK_ID='<operator-rack-label>'
RACK_NODES='<site-approved-hostlist>'
RACK_SAMPLES=5
```

Use actual site values in place of the placeholders. `RACK_ID` labels the run;
the validator discovers the common ClusterUUID from the selected nodes.
Run from the checkout or deployed source tree with Slurm client tools on PATH:

```bash
./actions/launch_rack_job.sh --explain
```

For a different selection without editing settings:

```bash
./actions/launch_rack_job.sh --explain --rack-id '<operator-rack-label>' \
    --nodes '<site-approved-hostlist>' --samples 5
```

Run `--help` for the option list. The command uses `scontrol show hostnames`
to expand the selection and `sinfo -N -h -o '%N'` to confirm selected nodes exist
in Slurm. It then probes their ClusterUUID values live in one bounded fan-out.
Neither Slurm node existence nor hostlist expansion establishes membership.
`EXCLUDE_NODES` and `NODE_FILTER` also apply. Invalid configuration or selection
blocks the remote probe before any fan-out.

## Interpret the output

Exit status `0` means configuration and membership validation passed; `1`
means blocked or inconclusive evidence; `2` means invalid command usage.
`RUN_RACK_JOBS=no` describes disabled automatic scheduling and permits explicit
manual validation. `RUN_JOBS=no` blocks a submission proposal, as does an
unrecognized run-switch value. Missing or inconsistent live identity evidence, failed or empty Slurm
queries,
unknown nodes and invalid selections print blocking reasons and withhold the
command. The expanded list retains duplicates so they remain visible.

On success the proposed command uses the exact canonical list through `-w`,
no allocation node-count option, and the output pattern
`$RESULTS_DIR/nvloom-rack-%j.txt`. Container paths and samples come from resolved
settings. The run ID is a placeholder, and the command is a preview of the
future launcher: submission support and fixed batch-header removal are later
steps. Inherited `SBATCH_NODES` blocks the proposal.

Revalidate live identities immediately before any future submission. A previous
explanation is not permission to submit. A valid selection does not establish
health, image readiness, allocation
availability or safe coordination with existing work. No participation is
claimed. Use this step to review the membership source and arguments; it does
not authorize starting the proposed job.

For acceptance, repeat explanation with a valid 18-node selection, 17 nodes,
a list containing a repeated member, mixed ClusterUUIDs and an unavailable identity probe.
Check the printed reasons and exit statuses and confirm the data tree is
unchanged. `./tests/rack-validation-test.sh` exercises these cases with synthetic
nvidia-smi fixtures and stubbed Slurm and fan-out tools, including checks that
no mutating commands
are called and no runtime data directories are created.
