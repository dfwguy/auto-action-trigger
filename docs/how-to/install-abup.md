# Put `abup` on PATH

`abup` dispatches to the operator scripts by name — `abup report benchmarks`
runs `report_benchmarks.sh`, `abup check trigger-log` runs
`check_trigger-log.sh` — forwarding anything after the second word unchanged.
See [reference/scripts.md](../reference/scripts.md) for the full command list.

## Symlink it in

```bash
sudo ln -s /cluster/bringup/abup /usr/local/bin/abup
```

A symlink, not a copy: `abup` finds the tree by resolving its own real path
(`readlink -f`), so the symlink can live anywhere on `PATH` and still locate
the checkout it points at. Confirm it:

```bash
abup --help
```

lists every `<group> <name>` pair actually in the tree — not a maintained
list, so a script added later shows up without anyone updating this page.
`abup check -h` (or just `abup check`) narrows that to one group.

## A detached copy, with no symlink

Copying `abup` itself (rather than symlinking to it) means it has no path
back to the tree on its own. Set `BRINGUP_HOME`:

```bash
BRINGUP_HOME=/cluster/bringup abup report overall
```

the same variable the deployed tree already defaults to — see
[reference/settings.md#accounts-and-paths](../reference/settings.md#accounts-and-paths).
`admin_kill-jobs.sh`, the one other script meant to be copied out of the tree,
resolves itself the same way.

## `ERROR: cannot find the bringup tree`

Printed when neither the symlink's real location nor `BRINGUP_HOME` holds a
`SETTINGS`, `SETTINGS.default`, `SETTINGS_HOME` or `SETTINGS_HOME.default` —
the same four files `settings.sh` itself checks, so this fails exactly when
sourcing settings would also fail. Either the symlink points somewhere that is
not the tree, or `BRINGUP_HOME` is unset or wrong for a detached copy.
