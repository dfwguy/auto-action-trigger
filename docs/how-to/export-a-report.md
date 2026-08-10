# Get a report into a spreadsheet

```bash
bash daily-report.sh -c -o ~/report-$(date '+%F').csv
```

Use `-c` and split on the delimiter. That gives comma separated rows for the
table *and* the summary, so a paste of the whole screen imports in one pass.
`daily-report.sh | cat` is the same thing with tabs, which most spreadsheets
split on paste without a dialog at all.

The summary goes to stderr, so `-o` and a redirect both capture the table alone.
To keep both in one file:

```bash
bash daily-report.sh -c > report.csv 2>&1
```

## Where the file goes is yours to say

`-o` writes exactly where you point it and **creates nothing**. The directory
has to exist already; if it does not, the run says so and stops without
scanning, rather than building a fleet-wide report it cannot then write.

There is no reports directory and no default. An earlier version of this made
the parent with `mkdir -p`, which meant `-o reports/x.csv` silently produced a
`reports/` under the deployment root — a directory the framework appeared to own,
that nothing read, that got copied between deployments, and that had to be
explained. A report is a thing you asked for once; where you keep it is not the
framework's business.

`overall_report.sh -o` behaves the same way.

## Do not import the aligned form

Text-to-columns in fixed-width mode looks like it should work and does not: the
import guesses where the columns are from whatever was selected, so pasting one
block gets different break points than pasting the whole report, and either
guess can land mid-word. No amount of padding or shifting fixes that — a
separator has nothing to guess.

The aligned form is for reading on screen. The rule the report follows is that
**TSV at a terminal** is column-aligned, and **anything else** — a pipe, a
redirect, `-o`, or `-c` — is the raw separated rows.

When it is aligned, the node table and every summary block share one grid: no
indentation, one set of column positions measured across every row of every
block before anything prints, and every line a row. Blocks are named by the
first cell of their own header row rather than by a title line above them, since
a free-form line like `254 nodes, 4 jobs` puts words at offsets no column
boundary passes through.

## Scoping the export

The node pattern filters the table *and* the summary blocks, so a filtered
report's `median` is that rack's median rather than the fleet's — the `nodes`
count in the first summary block is what says how many nodes it was taken over.

```bash
bash daily-report.sh ink50-dh01-h20 -c -o ~/rack-h20.csv
```

What each column and summary block means is
[reference/scripts.md#daily-reportsh--per-node-table-with-metrics](../reference/scripts.md#daily-reportsh--per-node-table-with-metrics).
