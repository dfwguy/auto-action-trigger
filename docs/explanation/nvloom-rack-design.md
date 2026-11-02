# Fixed 18-node NVLoom rack runs

This records the approved Step 1 design. Step 2 implements only
[read-only configuration and membership explanation](../how-to/explain-nvloom-rack.md);
coordination and submission below remain planned behavior. Existing
[single-node sequencing](sequencing.md) stays unchanged when no rack request
is active. The current [manual procedure](../how-to/run-nvloom-tests.md) still
uses direct submission; the coordinated launcher described here will replace
its rack submission example in a later step.

## Membership needs site input

No authoritative node-to-NVLink-domain inventory was found in this checkout.
`check_rack.sh` reports Slurm state, not membership. Neither Slurm partition
membership nor a hostname prefix establishes a fabric boundary.

The NVL72 health checks record useful observations:

- `14-nvidia-smi-cuuid.sh` records GPU Bus Id, CliqueId and ClusterUUID.
- `27-imex-node-config.sh` records only an IMEX configuration checksum.
- `30-imex-status.sh` records a transformed, time-varying IMEX status matrix.

These informational logs are neither a complete, versioned membership source
nor an approved translation from IMEX addresses to Slurm node names. The
[node inventory explanation](node-inventory.md#it-is-not-a-baseline) explicitly
warns against treating one rack's observation as a fleet baseline. NVLoom's
own ClusterUUID checks remain additional runtime protection; its reported
`rackGuid` is not assumed to equal ClusterUUID or a physical rack label.

Use a site-owned inventory export until the site supplies an authoritative
API and its identifier semantics. Proposed setting `RACK_MEMBERSHIP_FILE`
names an absolute, shared, readable TSV file outside the release tree. Its
first line is exactly `node<TAB>rack_id<TAB>nvlink_domain_id`; each subsequent
line contains one literal Slurm node name, physical rack ID and domain ID.
There are no hostlists, blank fields, aliases or inferred members. No actual
membership data is shipped with this design.

The site must attest the export's origin, revision and operational freshness,
including refresh after fabric changes. Publish it atomically; trust its
ownership and write permissions only after site review. Reject missing,
unreadable, malformed or conflicting mappings, duplicate node rows, and
unknown selections. Record its exact content and digest with each request.

`rack_id` identifies the physical enclosure; `nvlink_domain_id` identifies the
shared NVLink fabric domain. They are separate fields even where the site has
one domain per rack. Use the site's canonical fabric identifier (ClusterUUID
only if the site confirms that meaning), never derive it from `rack_id`.
IDs must be safe single path components; reject separators, whitespace, `.`
and `..`. Nodes must also be valid literal Slurm node names.

For this workload a valid group is exactly 18 distinct mapped nodes with one
physical rack ID and one NVLink domain ID, and all mapped members of that
domain must be those 18 nodes. Expand an operator hostlist, reject duplicates
before canonical sorting, and require exact equality to that group. Reject
short, oversized, mixed, excluded or filtered selections; never pad or expand
a request to additional nodes. Validate against the current Slurm inventory
as well. Missing data stops submission with a reason, not a hardware finding.

**Review input still required:** inventory owner/source and export path;
physical rack label and canonical domain identifier; confirmation of the
18-node domain boundary. No live inventory or cluster validation was performed.

## Existing assumptions that need explicit integration

| Area | Current behavior and consequence for rack support |
|---|---|
| Names | `actions/launch_job.sh` uses `bringup-<node>` and `burnin-<node>`. Snapshot ownership and several reports strip those prefixes into one hostname. A rack name cannot be added to that logic without changing its meaning. |
| In flight | `results/<node>/.in-flight` stores job ID, workload, run number, total runs and submit epoch. Do not put the rack job in these records: the supervisor's `MAX_JOB_HOURS` path can drain their nodes. |
| Snapshots | `slurm-snapshot.sh` obtains a fleet queue and writes per-node sealed views. Running allocations map onto all allocated nodes, but pending ownership is keyed by the single-node job name. Missing, stale or torn views cannot authorize submission or release. |
| Pause | `RUN_JOBS=no` prevents manual/forced and automatic local submission; the supervisor cancels pending framework jobs and leaves running jobs to finish. Apply the same policy to coordinated rack requests. |
| Timeout | Local sequencing has stale-marker and submission-backoff logic; the supervisor has a separate overrun drain path. Rack lifecycle must reconcile its own IDs and avoid both node retry and drain paths. |
| Cancellation | Supervisor pause/failed-launch cleanup, `get-out-of-the-way.sh` and `admin_kill-jobs.sh` recognize single-node prefixes. Rack cancellation must operate on one verified job ID, with owner, request identity and name checks. |
| Reporting | Per-node result paths, retry archives and verdict caches feed node pass counts. Rack results need their own report. `nvloom-rack-nvlink` currently falls through to generic parser checks, so generic `DONE` is insufficient evidence of rack quality. |

The batch file currently requests `#SBATCH -N 18`, four GPUs and four tasks
per node, exclusive nodes, all memory, a 90-minute allocation and an 80-minute
step. It uses NVLoom v2.0.0, all GPU visibility, six rack suites, `-r`, and
`RACK_SAMPLES=5` by default. Preserve those workload choices, container lookup
and MPI interface behavior. The current rack script checks the MPI interface;
it does not implement the per-node GPU/CPU preflight claimed by the existing
manual guide. Correct that documentation when updating the submission guide.

## One coordinator for manual and automatic requests

Proposed interfaces are `actions/launch_rack_job.sh` for manual request,
status and cancellation, and a sourced `rack-jobs.sh` coordinator used by that
entry point and `agent/supervisor.sh`. Manual submission supplies a domain
and explicit node selection. The supervisor selects only complete mapped
groups. Both call the same validation and state transitions as `JOB_USER`.
Use a distinct job name `racknvloom-<run-id>`, tied to its request record;
name matching alone never proves ownership.
No node agent submits a rack job and no per-node fan-out runs this launcher.

Load configuration through `settings.sh`, including its existing site pointer
resolution. Step 2 adds `RUN_RACK_JOBS=no`, `RACK_ID` and `RACK_NODES` empty,
`RACK_SAMPLES=5`, and `RACK_MEMBERSHIP_FILE` empty by default.
`RACK_ID` selects the physical rack and the mapping supplies its domain.
A later step will add
`RACK_REQUEST_TIMEOUT_MINUTES=120` for preparation and pending time combined.
The timeout remains a proposed default. Automatic scheduling
requires explicit `RUN_RACK_JOBS=yes`; manual requests work with it set to
`no`. Both require `RUN_JOBS=yes`, valid membership, all existing node selection
restrictions and a usable configured launcher in `JOBS_DIR`. Missing launcher
or membership is explained and blocks rack work only.

Initially automatic scheduling makes at most one attempt per domain,
membership digest and workload configuration digest. Retain terminal history
so a failure or supervisor restart cannot create an automatic retry loop.
An explicit manual request may start another attempt after release. Changing
`RUN_RACK_JOBS` to `no` prevents new automatic requests; accepted requests still
reconcile to completion. `RUN_JOBS=no` also cancels unsubmitted requests and
pending rack jobs, while running allocations finish normally.

Use one shared coordinator lock, not the supervisor's host-local `/tmp` lock,
for all request creation, transitions and submission. A shared atomic `mkdir`
lock is an option; validate its semantics on the site's filesystem. Fail
closed on contention, unreadable state or uncertain lock ownership. Do not
reclaim locks merely by age or check a remote PID as though it were local.

The coordinator and the final local submission gate must also share short
per-node locks, acquired in canonical node order. The local launcher holds its
node lock through its final participation check, `sbatch` and in-flight record
write. The coordinator holds all 18 locks while publishing participation.
This closes the check-versus-submit race, including direct manual local
launches. A fresh snapshot must subsequently reconcile any preceding local
submission. Existing local jobs, including queued jobs, finish normally;
selected nodes defer new benchmark, continuous and burn-in submissions.
With no active participation reference, local submission follows its existing
rules. A broken reference blocks that node with a trace until reconciled.

## Lifecycle and release

Store authoritative run metadata under
`$BRINGUP_DATA/multinode-results/<rack-id>/<run-id>/`: immutable request and
membership snapshot, canonical nodes, origin, timestamps, workload/settings
digest, unique submission token/name, submission response, job ID, transitions,
cancellation reason and result assessment. Run IDs must be unique across
domains within the same physical rack. Shared locks/indexes and per-node
participation references are coordination aids, not alternative verdicts.
Publish records atomically using host/process-specific temporary names.

| State | Action and release condition |
|---|---|
| Preparing | Validate and persist the request; claim all selected nodes before waiting for local work to finish. Require fresh node views and no outstanding local submissions or foreign work, and verify the existing health/container readiness prerequisites before submitting. A competing request reports the existing run. |
| Submitting | Persist the unique token before calling `sbatch` exactly once. Manual and supervisor callers see this same state. A crash, timeout or unparsable response leaves an uncertain submission to reconcile by token, owner and exact requested nodes; never retry it blindly. |
| Pending / running | Save the job ID; reconcile from the supervisor's fleet query. Keep participation through pending, running, requeue and completing states. Membership changes cannot silently change an accepted request's nodes; block submission on a changed mapping. |
| Cancelling | Unsubmitted requests can terminate directly once absence of a submission is certain. Otherwise request `scancel` for the verified ID; command success alone does not release participation. Pause, explicit cancel, held-launch cleanup or request deadline records the cause. |
| Terminal | Confirm the allocation is gone with a successful fresh queue query taken after the last submission/cancel action, and obtain terminal job evidence by targeted accounting when available. An absent queue entry can establish release but cannot establish success. Save completed, failed, cancelled or inconclusive assessment before removing only this run's participation references. |

The 120-minute request deadline bounds waiting for existing jobs and pending
allocation time; it does not shorten the batch/step limits. A deadline during
uncertain submission requires reconciliation, not forced release. No TTL,
missing output, final output marker or failed/empty probe alone releases
participation. A healthy empty queue is distinguished from a failed query.
If controller/accounting evidence is inconclusive, retain or report uncertainty
as appropriate; provide status and an operator reconciliation path. A restart
resumes reconciliation from disk, including cleanup interrupted after saving
terminal state. A long-lived poller is unnecessary: supervisor cycles reconcile
requests, even with automatic scheduling disabled.

Submit the validated canonical list through `sbatch -w`; remove
`#SBATCH -N 18` from both shipped rack job variants. The launcher must pass
neither `-N` nor `--nodes`, and must reject inherited allocation node-count
overrides such as `SBATCH_NODES`. Preserve any allocation-relative step options
such as `srun --nodes="$SLURM_NNODES"`. Keep the output pattern
`$RESULTS_DIR/nvloom-rack-%j.txt` and store its path in run metadata. Never
write rack output into a member's benchmark result slot.

Do not automatically drain any member for rack failure, timeout or
cancellation. Releasing participation restores ordinary node scheduling and
does not mark single-node tests passed or failed. Rack reporting separates
scheduler state, workload completion and quality assessment; retain
inconclusive quality until a dedicated parser has representative fixtures.

## Smallest later implementation surface

- `settings.sh` and `SETTINGS.default`: opt-in settings and resolved paths.
- New `rack-jobs.sh` and `actions/launch_rack_job.sh`: membership validation,
  shared locking, request persistence, submission and reconciliation.
- `actions/launch_job.sh`: participation and shared final-submission lock;
  reject using the rack workload through the per-node launcher.
- `agent/supervisor.sh`: cadence-bounded coordination using its existing queue;
  keep rack records outside local timeout/drain handling.
- `slurm-snapshot.sh`, `get-out-of-the-way.sh`, `admin_kill-jobs.sh`: explicitly
  recognize rack ownership through request records. Never strip a rack name
  into a hostname. Yielding cancels the whole verified rack job once if any
  member must yield; it never cancels existing local jobs to prepare a rack.
- Both `jobs/nvl72*/nvloom-rack-nvlink.sbatch` variants: allocation count removal.
- New `report_rack-status.sh`: independent rack status and log references;
  existing node reports must avoid interpreting rack identities as nodes.
- Offline tests: invalid membership, pause/manual opt-in semantics, concurrent
  callers and local submission races, ambiguous submission, restart, cancelled
  and completing jobs, failed probes, release and independent reporting.
  Update settings/jobs/operator references and the layout when code lands.

Review the membership input, domain identifier, lifecycle and proposed defaults
before implementing these interfaces. Later cluster acceptance must verify
shared locking, Slurm allocation of exactly the validated list, reconciliation
and release; offline fixtures cannot establish those properties at a site.
