# Add a new benchmark

1. Copy `jobs/nvl72/example.sbatch` to `jobs/$JOBS/<name>.sbatch`. Its
   `#SBATCH` header and preflight block are part of what you are copying — see
   [reference/jobs.md#the-allocation-header](../reference/jobs.md#the-allocation-header).

2. Set `job_name=<name>` and optionally `totalRuns=N`. For a job listed in
   `BURNIN`, `totalRuns` is a per-job ceiling under the shared `BURNIN_HOURS`
   target rather than the completion signal — see
   [reference/settings.md#burn-in](../reference/settings.md#burn-in).

3. Add your workload between the job and parse sections.

4. Set `STEP_TIMELIMIT` and `#SBATCH -t` per
   [reference/jobs.md#two-time-limits-and-the-order-they-fire-in](../reference/jobs.md#two-time-limits-and-the-order-they-fire-in),
   and pass the former to the workload's `srun --time`. Add a row to
   [what each job's limits were derived from](../reference/jobs.md#what-each-jobs-limits-were-derived-from)
   so the next person can compare yours against its neighbours.

5. The parse section must `echo PENDING` if the workload ran and `echo FAIL` if
   it could not, as the last line — capture the exit status immediately after
   the workload with `rc=$?` and end the file with:

   ```bash
   echo "exit status: $rc"
   [[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL
   ```

   Keep the prefix identical across jobs, keep it before the marker —
   `verdict.sh` reads the last line — and keep the words fail, warn and error
   out of it, since several gates sweep the whole file for those
   case-insensitively. What that line buys is in
   [explanation/judging-benchmarks.md#exit-status-says-who-decided-a-fail](../explanation/judging-benchmarks.md#exit-status-says-who-decided-a-fail).

6. Add a gate for `<name>` to the `case` in `parsers/$PARSERS/verdict.sh`.
   Without one it falls through to `_v_gate_generic`, which only checks for
   common crash signatures and cannot know what your job's output is supposed to
   look like. Read
   [explanation/judging-benchmarks.md](../explanation/judging-benchmarks.md)
   before writing it — the two failure modes it describes have both been paid
   for here already.

7. Add a fixture under `tests/fixtures/` and a line to `tests/verdict-test.sh`.
   Capture it from a real run on the platform; a gate with no fixture behind it
   has never been run against real output.

8. Add `<name>` to the `BENCHMARKS` in `SETTINGS` — see
   [enable-a-benchmark.md](enable-a-benchmark.md).

## Before committing

```bash
./tests/verdict-test.sh
bash -n jobs/$JOBS/<name>.sbatch
shellcheck -S warning jobs/$JOBS/<name>.sbatch
```

The new file is `644`, not `755` — `sbatch` reads it, it is never executed. See
[reference/layout.md#executable-bits](../reference/layout.md#executable-bits).
