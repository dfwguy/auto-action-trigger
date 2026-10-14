# The burn-in waveform

`mnubergemm` does not run a workload flat out. It runs one on a square wave,
and everything interesting about the two burn-in jobs is which wave they run.
This page is why there are two, and why the flags that shape them are easy to
get silently wrong.

Everything here is read from the tool's own source at the last commit that had
the flag interface — `dc_diags/mnubergemm` at `048f3e1`, July 2025. It is not
in this repo, and the tool's README describes the flags without describing what
consumes them.

## What `--freq` and `--duty` actually do

`--freq` is in Hertz and `--duty` is the fraction of each period spent under
load. The tool turns them into two targets and tunes the workload length until
it hits them:

```
target_high_ms = (1/freq) * 1000 * duty
target_low_ms  = (1/freq) * 1000 * (1 - duty)
```

At the steady job's `--freq 500 --duty 1.0` that is a 2 ms period with **no low
phase at all** — a continuous soak. That is the point of it: sustained thermal
load at a fixed operating point, for hours, which is the 24–72 hour row of the
testing plan.

It also means the steady job is blind to a whole class of fault. Nothing about
a flat load exercises the power-delivery network's response to a load step, or
the cooling loop's response to going from full draw to idle and back.

## The long wave

`--dual_mode` adds a second, much slower square wave on top of the first:

```
inner_loops = ((1/dual_freq) * dual_duty) / (1/freq)
ms_sleep    = ((1/dual_freq) * (1 - dual_duty)) * 1000
```

The high phase becomes that many fast cycles; the low phase is a real host
`sleep`, so the GPUs go genuinely idle. `mnubergemm-pulse.sbatch` uses
`--dual_freq 0.0013888889 --dual_duty 0.50`: a **720-second wave, six minutes
of load then six minutes of idle**, about thirty times over a six-hour run.

The part that makes this worth having is one line before the sleep — the tool
calls its cluster-wide CPU sync first, so every rank drops and resumes
together. The wave is synchronised across the allocation, not per GPU.

Two limits worth stating plainly:

- **These jobs are `-N 1`**, so "the allocation" is four ranks on one node. The
  rack-scale power step that makes a synchronised pulse interesting on NVL72
  needs a multi-node job, and the sequencer is per-node throughout — see
  [sequencing.md#cadence-is-per-job-not-per-node](sequencing.md#cadence-is-per-job-not-per-node).
  What the single-node job does buy is the per-GPU and per-tray load step.
- `--dual_mode` **overwrites** `inner_loops`, which is otherwise "workloads
  between CPU syncs". Setting both is not additive; the waveform wins.

The pulse job also runs its fast wave at `--freq 400 --duty 0.9` rather than the
steady job's `500`/`1.0`. A duty of 1.0 leaves no low phase for the long wave to
sit on top of, and 400/0.9 are the numbers from the GB200 bring-up the dual-mode
configuration came from. Every other knob — `MM_type`, the SM counts, the
buffer sizes — is the steady job's, unchanged, so the two runs differ in the
waveform and nothing else.

There is a third mode, `--tri_mode` with `--tri_duty`, that inserts a preheat
phase before the work phase so the measured half does not start from cold. It
is not used here, and is the obvious next thing to try once a plain dual-mode
run has been captured.

## The two workload caps

`--max_workload` and `--MM_max_workload` look redundant and are not. The global
one seeds the workload length and sizes the GEMM's K extent; the `MM_` one is
the GEMM test's own cap. **The tuning loop stops at whichever is lower**, so
raising one alone does nothing at all.

This is not theoretical. The steady job asked for `--MM_max_workload 65536` for
months while the global cap sat at its default of 16384, which is what actually
bound. Both jobs now set both, which is also how every example in the tool's
own README is written.

`--CE_size` went the other way. It carried 20480000, character-identical to
`--NET_size` two lines above it and an order of magnitude off every reference
configuration — a paste, not a decision. Both jobs now state the tool's own
default of 1048576 rather than an unexplained number, and state it explicitly
rather than omitting the flag, because the default in the NGC image is not
something this tree can see.

## Two jobs, not one

The pulsed configuration is a separate `.sbatch` rather than a flag on the
existing one, for three reasons:

- The steady job **is** the plan's burn-in row, its `totalRuns=12` now a
  per-job ceiling under the shared `BURNIN_HOURS` target rather than the row's
  own definition. Changing its arguments still changes what that row means,
  silently, in a job whose output has never been captured.
- The two answer different questions and the results are not interchangeable.
  A node that survives thirty load steps has not been soaked, and a node that
  survives a six-hour soak has not been stepped.
- At `--dual_duty 0.50` half of each run is idle, so a pulse run delivers about
  half the load-hours of a steady one of the same walltime. The two are
  comparable in wall-clock validated hours — both are credited by
  `--time_to_run`, the argument that bounds a run's length, the same way — but
  `totalRuns=6` on the pulse job is still roughly three steady runs' worth of
  *load*, not hours; see
  [../reference/settings.md#burn-in](../reference/settings.md#burn-in).

Both queue at `--nice=100000` and neither runs unless `RUN_BURNIN` is on and
the job is named in `BURNIN` — see
[../reference/settings.md#burn-in](../reference/settings.md#burn-in).

## The banner is a gate

`_v_gate_mnubergemm` has no positive marker. The comment above it in
`parsers/nvl72/verdict.sh` says why: the tool has no documented success banner,
so a container that starts, runs nothing and exits 0 would pass anything
stricter than "non-empty". That is the weakest gate in the file.

Dual mode fixes this for the pulse job. The tool logs

```
DUAL MODE: WORK: <n> loops IDLE: <n> ms
```

at info level from the function that computes the waveform, before any work
starts and unconditionally when `--dual_mode` is set. So `mnubergemm-pulse` can
require a line that only a run which really entered dual mode can produce, and
`_v_gate_mnubergemm_pulse` does. The steady job has no equivalent and still
cannot have one.

The fixtures behind it are synthetic — no result file from either job has been
captured on this platform. Capture one before trusting either verdict; see
[judging-benchmarks.md#what-the-tests-hold](judging-benchmarks.md#what-the-tests-hold).

## The trap that is not in this repo

The tool parses its flags with cxxopts and does not enable
`allow_unrecognised_options()`, so an unknown `--flag` is an error and stops the
run. A token that does not start with two ASCII hyphens is not an unknown flag
— it is a positional argument, and positionals are collected and ignored.

A configuration circulating internally pins the cuBLAS algorithm with
`—MM_force_cublas_algo <base64>` written with an em-dash. It parses as two
ignored positionals, the flag never takes effect, and nothing says so. Neither
job here uses that flag, but the failure mode applies to any of them: **a
mistyped mnubergemm flag is silent, not fatal.** Copy flags as text, never from
a rendered document.

## Which binary this all applies to

The flag interface described here belongs to mnubergemm 1.x. Upstream replaced
it: from September 2025 the tool takes `--json_input <file>` and a JSON workload
schema, and the `--freq`/`--duty`/`--MM_*`/`--dual_*` options no longer exist —
they sit in a block named `MNUB_DEPR_OPTION_*`, commented out. The tool's README
still documents the flag form.

Both jobs here run `MNUBERGEMM_VERSION` from `SETTINGS`, an NGC image tag. If
that tag ever moves to a 2.x build, every argument in both files stops parsing
on the same day, and the pulse job's banner gate is what will say so first —
the steady job would report a `FAIL` with no cause. Moving the version is a
job-file change, not just a settings change.
