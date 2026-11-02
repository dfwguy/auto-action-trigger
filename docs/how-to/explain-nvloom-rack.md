# Explain an NVLoom rack selection

`actions/launch_rack_job.sh --explain` validates a proposed fixed 18-node
selection. It prints evidence, expanded members, blocking reasons and a
hypothetical command. It creates no files, requests, participation records or
jobs, even when `RUN_RACK_JOBS=yes`. Single-node scheduling is unchanged.

## Prepare trusted membership evidence

Ask the site inventory owner for a TSV export, published atomically at an
absolute readable path outside the release tree. Its header must be exactly
these three tab-separated fields:

```text
node<TAB>rack_id<TAB>nvlink_domain_id
```

Replace `<TAB>` with literal tabs. Each data row names one literal Slurm node,
its physical rack ID and its canonical NVLink domain ID. There are no blank
fields, comments, hostlists or duplicate node rows. Identifiers start with a
letter, digit or underscore and otherwise contain letters, digits, underscores,
dots or hyphens. The domain must map to exactly 18 nodes, all in one physical
rack. Do not manufacture the mapping from hostname patterns.

The operator is responsible for confirming the export's ownership, origin and
freshness with the site. The validator checks its structure and membership;
it cannot independently establish that site inventory reflects current wiring.
ClusterUUID health logs and IMEX checks alone are insufficient. See the
[membership design](../explanation/nvloom-rack-design.md#membership-needs-site-input).

## Run the explanation

Set these keys in the site settings found through `settings.sh`:

```bash
RUN_RACK_JOBS=no
RACK_ID='<physical-rack-id>'
RACK_NODES='<site-approved-hostlist>'
RACK_SAMPLES=5
RACK_MEMBERSHIP_FILE='<absolute-path-to-site-export.tsv>'
```

Use actual site values in place of the placeholders. `RACK_ID` is the physical
rack ID; the validator discovers the common domain ID from the mapping.
Run from the checkout or deployed source tree with Slurm client tools on PATH:

```bash
./actions/launch_rack_job.sh --explain
```

For a different selection without editing settings:

```bash
./actions/launch_rack_job.sh --explain --rack-id '<physical-rack-id>' \
    --nodes '<site-approved-hostlist>' \
    --membership-file '<absolute-path-to-site-export.tsv>' --samples 5
```

Run `--help` for the option list. The command calls only `scontrol show hostnames`
to expand the selection and `sinfo -N -h -o '%N'` to confirm selected nodes exist
in Slurm. Neither establishes domain membership; the TSV supplies that evidence.
The selection must include exactly the 18 mapped members of one domain, without
duplicates. `EXCLUDE_NODES` and `NODE_FILTER` also apply.

## Interpret the output

Exit status `0` means configuration and membership validation passed; `1`
means blocked or inconclusive evidence; `2` means invalid command usage.
`RUN_RACK_JOBS=no` describes disabled automatic scheduling and permits explicit
manual validation. `RUN_JOBS=no` blocks a submission proposal, as does an
unrecognized run-switch value. Missing inventory, failed or empty Slurm queries,
unknown nodes and invalid selections print blocking reasons and withhold the
command. The expanded list retains duplicates so they remain visible.

On success the proposed command uses the exact canonical list through `-w`,
no allocation node-count option, and the output pattern
`$RESULTS_DIR/nvloom-rack-%j.txt`. Container paths and samples come from resolved
settings. The run ID is a placeholder, and the command is a preview of the
future launcher: submission support and fixed batch-header removal are later
steps. Inherited `SBATCH_NODES` blocks the proposal.

A valid selection does not establish live health, image readiness, allocation
availability or safe coordination with existing work. No participation is
claimed. Use this step to review the membership source and arguments; it does
not authorize starting the proposed job.

For acceptance, repeat explanation with a valid 18-node selection, 17 nodes,
a list containing a repeated member, mixed domains and a missing mapping file.
Check the printed reasons and exit statuses and confirm the data tree is
unchanged. `./tests/rack-validation-test.sh` exercises these cases with synthetic
fixtures and stubbed Slurm tools, including checks that no mutating commands
are called and no runtime data directories are created.
