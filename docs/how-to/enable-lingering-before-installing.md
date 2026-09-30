# Enable lingering before installing the agent, not in the same breath

`bringup-agent.timer` runs under `$JOB_USER`'s `systemd --user`, which
normally stops the moment that account's last session closes — so arming a
node over ssh would start a timer that dies with the ssh session that started
it. Lingering is what keeps the manager running after you disconnect. Why
this framework needs it at all is
[explanation/the-agent-and-the-watchdog.md#why-lingering](../explanation/the-agent-and-the-watchdog.md#why-lingering).

## The gotcha

`loginctl enable-linger $JOB_USER` only takes effect for sessions that start
**after** it runs. It does not reach back and grant a working `systemd --user`
bus to the session you are already sitting in. `install-agent.sh` enables
lingering for you automatically if it finds it off — but if this is the
account's first time being armed, that means the very ssh session you are
running the installer from is exactly the session lingering cannot help.

`install-agent.sh` catches this and refuses to go further:

```
ok: enabled lingering for cmods
FAILED: no user bus reachable in this session, even though lingering is enabled for cmods now -- it takes effect on your NEXT login, not this one. Log out and back in (or open a fresh ssh session as cmods) and re-run install-agent.sh.
```

Before this check existed, the same root cause showed up as a pile of
unrelated-looking failures instead — `systemctl --user daemon-reload failed`,
then `Failed to connect to bus`, then `bringup-agent.timer is not active`, one
after another, none of them naming lingering at all.

## The fix, and how to skip the gotcha entirely

Once told, the fix is one line:

```bash
ssh cmods@head-node 'loginctl enable-linger cmods'   # or: sudo loginctl enable-linger cmods
```

then open a **new** ssh session before running `install-agent.sh` — the one
you just used to enable lingering still cannot use it, for the same reason
the installer's own session couldn't.

To skip the gotcha altogether on a fleet where lingering has never been
turned on: enable it as its own deliberate first step, in its own session,
*before* you ever run `install-agent.sh` for the first time —

```bash
ssh cmods@head-node 'loginctl enable-linger cmods'
# disconnect, then reconnect (or open a second session) before continuing
ssh cmods@head-node
bash /cluster/bringup/agent/install-agent.sh
```

— rather than letting the installer discover and enable it for you mid-run.

## Confirming it actually took

```bash
loginctl show-user cmods -p Linger --value        # want: yes
ls -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u cmods)}/bus"   # want: it to exist
```

The first line is the flag; the second is the fact that actually matters —
a flag set to `yes` with no bus reachable is precisely the state a session
that predates the flag is in. `install-agent.sh` checks the second, not the
first, for exactly that reason.

If lingering reads `yes` and a *new* session still has no bus, that is a
different, rarer problem — see
[arm-a-node.md#the-user-manager-is-not-really-lingering](arm-a-node.md#the-user-manager-is-not-really-lingering).
