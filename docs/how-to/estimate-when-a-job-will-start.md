# Work out when your job will start behind the bringup sweep

You submitted a job, it is `PENDING`, and `squeue` shows jobs named
`bringup-<node>` or `burnin-<node>` sitting on the nodes you want. This is how
to turn that into a number.

The short version, for a site running the shipped `BENCHMARKS` list: **under an
hour, and usually much less.** The long version is below, because the answer
changes a lot if the site has burn-in on.

## The one rule that decides everything

Every job this framework submits is `#SBATCH --exclusive` and asks for the whole
node. Priority does not change that: **`--nice` reorders what has not started
and never preempts what has.** So if one of our jobs is `RUNNING` on the node
you want, your job starts when that job ends, and no amount of priority moves
it.

That makes the estimate a subtraction rather than a guess: find the running job,
read its time limit, subtract what it has used.

## 1. Ask Slurm first

```bash
squeue --start -j <your-jobid>
```

If you get a `START_TIME`, that is the backfill scheduler's own estimate and it
is the best answer available — it accounts for everything below plus the rest of
the cluster. Take it and stop.

Two reasons you may get nothing useful:

- **The column is blank or the job is not listed.** The backfill scheduler has
  not reached your job yet, or cannot place it. Carry on to step 2.
- **The estimate is very far out and the reason is `Priority` or
  `Resources`.** That is a queue-depth answer, not a bringup answer, and this
  page will not improve it.

## 2. Find what is actually holding the node

```bash
squeue -w <node> -o '%.10i %.10u %.9T %.22j %.10M %.10L %R'
```

The two columns that matter are `%M` (elapsed) and `%L` (**time left**). `%L` is
your answer directly — Slurm computes it from the job's own `TimeLimit`.

```
     JOBID       USER     STATE                   NAME      TIME  TIME_LEFT NODELIST
    121918      cmods   RUNNING   bringup-ink50-dh01-h20     12:04      37:56 ink50-dh01-h20-11
```

That node frees in **37 minutes and 56 seconds**, worst case. Usually sooner —
`%L` is the walltime ceiling, and most of these jobs finish well inside it.

If the name starts `bringup-` or `burnin-`, it is ours. Anything else on the
`cmods` account is not this framework: a hand-submitted reproduction, another
team on a shared account. Only the two name prefixes are ours.

## 3. Look up the ceiling if you cannot wait for `%L`

If nothing of ours is running *yet* but the node is in the sweep, the worst case
is the longest walltime in the site's list. From the job files:

| Job | `#SBATCH -t` |
|---|---|
| the five NCCL jobs, `dcgmi-r1`, `dcgmi-r2` | `0:25:00` |
| `cublasmatmul` | `0:30:00` |
| `nvbandwidth` | `0:40:00` |
| `dcgmi-r3`, `nvsm` | `0:50:00` |
| `ethr`, `nvloom`, `llm-pretrain-solo` | `1:10:00` |
| `hpl` | `2:00:00` |
| `fio`, `stress-ng`, `llm-pretrain` | `2:10:00` |
| `dcgmi-r4` | `3:10:00` |
| `stream`, `memtester`, `stressapptest` | `4:10:00` |
| `mnubergemm` (burn-in) | `6:41:00` |

**The shipped `BENCHMARKS` list is `dcgmi-r1 dcgmi-r3 nvbandwidth allreduce
allreduce-forcesharp alltoall allreduce-nonvlink alltoall-nonvlink`, whose
longest job is `dcgmi-r3` at 50 minutes.** On a site running the default, no
single benchmark can hold a node longer than that.

Check what the site actually runs rather than assuming the default:

```bash
grep -E '^(BENCHMARKS|BURNIN|RUN_BURNIN)=' /home/cmods/bringup/SETTINGS
```

If that file does not exist the site is on `SETTINGS.default`, which is the
list above.

## 4. Do not read "three days of burn-in" as a three-day wait

This is the number people get wrong, and it is wrong in your favour.

`mnubergemm` burn-in is **12 runs of a ~6.5-hour step**, so a node is under
burn-in for about three days. But each run is submitted as **its own job**, one
at a time. Your job does not wait for the burn-in campaign; it waits for **the
one run currently in flight** — at most `6:41:00`, and `%L` tells you the actual
remainder.

Between runs the node returns to the queue like any other, and your job is
ordered against the *next* burn-in run rather than behind all of the remaining
ones. Burn-in carries `--nice=100000` precisely so that anything else waiting
goes first.

So: a node three days into burn-in is a node whose worst-case wait is still
under seven hours, and whose typical wait is whatever `%L` says.

## 5. Getting in front of the queue

Our jobs deliberately leave `--nice=0` empty for you. A bare `sbatch` with no
`--nice` lands at `0`, which is **ahead of every job this framework submits**:

| `--nice` | What |
|---|---|
| `0` | left free — anything submitted by hand |
| `1`–`4` | the `dcgmi-r*` gates |
| `20` | every other benchmark |
| `100000` | burn-in |

You do not need to do anything to get this; it is the default. It means your
pending job outranks every pending job of ours on the same partition.

It does **not** get you past a job that is already running — see the rule at the
top. If you are queued behind a running benchmark, priority is not the lever.

## 6. When the wait is not about us at all

Before blaming the sweep, check whether the node is even available:

```bash
bash /home/cmods/bringup/check_squeue.sh -j <your-jobid>
```

This exists for exactly this question. The queue's reason field names a
*condition* and never the nodes behind it — `ReqNodeNotAvail, May be reserved
for other job` is equally true of a job blocked by a drained node and one
blocked by a maintenance reservation. `-j` prints each of your job's nodes with
its state and drain reason, then every reservation whose node list overlaps
them.

- **A drained node in that table** — your job is waiting on a node nobody can
  use. If the drain reason contains `auto-retry`, the framework put it there and
  will clear it when the node passes; otherwise it needs a person.
- **A reservation covering your nodes** — you are waiting by policy, and nothing
  is broken.
- **Neither** — the node is busy, and step 2 says with what.

## 7. If you need the nodes now

Ask whoever runs the bringup; these change fleet state and are not yours to run
casually. The framework can be stopped in two ways, and the difference matters:

```bash
bash kill-jobs.sh -n <node-pattern>    # what would be cancelled, changes nothing
bash kill-jobs.sh -p <node-pattern>    # pause, then cancel
```

**Cancelling alone buys about one monitoring cycle.** The sequencer fires every
minute, finds an idle node, and submits the next benchmark. `-p` is what makes
it hold, and it writes `PAUSE_JOBS=yes` before cancelling anything so there is
no window for a cycle to resubmit into.

Note that a pause is fleet-wide even when the node pattern is not — `SETTINGS`
is one file read by every node. And nothing lifts a pause automatically; someone
has to set `PAUSE_JOBS=no` when your window closes.

Cancelling a benchmark costs the bringup a re-run, not a node: the partial
result reads as `INCOMPLETE` and the sweep retries it after the pause. See
[pause-and-resume.md](pause-and-resume.md).

## Summary

| Question | Command |
|---|---|
| When does Slurm think it starts? | `squeue --start -j <id>` |
| What is holding the node, and for how long? | `squeue -w <node> -o '%.10i %.22j %.10M %.10L'` |
| Is it ours? | job name begins `bringup-` or `burnin-` |
| What is the ceiling? | the table in step 3, against the site's `BENCHMARKS` |
| Is the node even usable? | `check_squeue.sh -j <id>` |

Why the sweep holds whole nodes, and why it never preempts, is
[explanation/sequencing.md](../explanation/sequencing.md). The walltime
derivations are
[reference/jobs.md#two-time-limits-and-the-order-they-fire-in](../reference/jobs.md#two-time-limits-and-the-order-they-fire-in).
