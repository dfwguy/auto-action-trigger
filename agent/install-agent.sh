#!/bin/bash
#
# Arm this host: enable lingering for JOB_USER, install the systemd --user unit
# out of agent/units/, and start the timer. Idempotent and safe to re-run -- it
# is what the head-node watchdog runs over clush on a node whose heartbeat has
# gone stale, as well as what an operator runs by hand.
#
# One unit for every host, whatever its role: $HOME is NFS-shared at most sites,
# so the units and the `systemctl --user enable` state are read by the whole
# fleet. cycle.sh decides the role at run time instead.
#
# See docs/how-to/arm-a-node.md.

home="${AGENT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[[ -f "$home/settings.sh" ]] || {
    echo "FAILED: no $home/settings.sh -- it is what says which account and which" >&2
    echo "        tree to arm, and guessing either would start a timer that runs" >&2
    echo "        nothing. Incomplete checkout?" >&2
    exit 1
}
source "$home/settings.sh"
source "$home/priv.sh"

ROLE=""
usage() {
    cat <<USAGE
Usage: install-agent.sh [--node|--head] [--help]

  --node   report this host as a compute node whatever it looks like
  --head   report it as the host that watches them

Both install the same unit -- cycle.sh asks the same question again on every
run, so these change what this run checks and prints, not what gets installed.
Re-running is how a changed unit or interval is picked up.
USAGE
}
for arg in "$@"; do
    case "$arg" in
        --node) ROLE="node" ;;
        --head) ROLE="head" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unrecognised argument '$arg' -- nothing was installed." >&2
           usage >&2; exit 2 ;;
    esac
done

rc=0
ok()   { printf 'ok: %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
fail() { printf 'FAILED: %s\n' "$*" >&2; rc=1; }

## ── Who is running this ───────────────────────────────────────────────────
##
## Not root: a root install puts the unit under root's systemd and the cycle
## back where this whole change took it out of.
## See docs/explanation/running-unprivileged.md.
me=$(id -un)
if [[ "$me" != "$JOB_USER" ]]; then
    echo "FAILED: this is $me, and the agent runs as $JOB_USER (JOB_USER in ${SETTINGS_FILE:-<none>})." >&2
    echo "        Arming as anyone else installs the timer into the wrong user's" >&2
    echo "        systemd, where nothing on the fleet ever looks for it." >&2
    exit 1
fi

## systemctl --user needs this and a non-interactive ssh does not reliably carry
## it; without it the failure reads as a missing unit.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

if [[ -n "$ROLE" ]]; then
    role_why="--$ROLE was passed"
else
    agent_role; ROLE="$AGENT_ROLE"; role_why="$AGENT_ROLE_WHY"
fi
unit=bringup-agent
script="$home/agent/cycle.sh"
interval="$AGENT_INTERVAL_MINUTES"
[[ "$interval" =~ ^[1-9][0-9]*$ ]] || {
    warn "AGENT_INTERVAL_MINUTES is '$interval', which is not a whole number of minutes -- using 2"
    interval=2
}

## ── Preflight ─────────────────────────────────────────────────────────────
##
## An exec bit is easy to lose in transit, and a timer pointed at a file that
## will not run reports active and does nothing. All three, because the unit
## names cycle.sh and cycle.sh hands over to whichever of the other two.
for s in "$script" "$home/agent/node-agent.sh" "$home/agent/supervisor.sh"; do
    if [[ ! -f "$s" ]]; then
        fail "$s does not exist -- nothing to arm"
    elif [[ ! -x "$s" ]]; then
        chmod +x "$s" 2>/dev/null && ok "restored exec bit on $s" \
            || fail "$s is not executable and chmod failed"
    fi
done
command -v systemctl >/dev/null 2>&1 || fail "systemctl is not installed -- this host cannot run a timer"
[[ "$rc" -eq 0 ]] || { echo "refusing to arm $HOSTNAME while something is unusable" >&2; exit "$rc"; }

ok "$HOSTNAME is $([[ "$ROLE" == "head" ]] && printf 'not a compute node' || printf 'a compute node') ($role_why) -- every host installs $unit.timer, and cycle.sh asks again on each run"

## The reports walk results/*/ and skip a host only on EXCLUDE_NODES or on
## node_self_excluded, which needs a slurmctld unit this host may not have.
## See docs/reference/settings.md#hosts-that-are-not-compute-nodes.
if [[ "$ROLE" == "head" ]] && ! node_excluded "$HOSTNAME" && ! node_self_excluded; then
    warn "the reports cannot work out on their own that $HOSTNAME is not a compute node -- add EXCLUDE_NODES=\"$HOSTNAME\" to ${SETTINGS_FILE:-SETTINGS}, or it gets a row of NOT_RUN in every report"
fi

## Only what this role actually uses: the health checks run on a node and
## nowhere else, and the watchdog's one privileged call is the MAX_JOB_HOURS
## drain. A warning rather than a refusal -- the rules are the site's to deploy,
## and everything needing no privilege still works without them.
## See docs/explanation/running-unprivileged.md#a-lost-rule-must-stop-the-run.
priv_cmds=()
priv_what=""
if [[ "$ROLE" == "node" ]]; then
    mapfile -t priv_cmds < <(grep -hoE 'sudo -n [a-z0-9_.-]+' "$HEALTHCHECKS_DIR"/[0-9]*.sh 2>/dev/null | awk '{print $3}' | sort -u)
    priv_what="the health checks that need them will not run here"
elif [[ "${PRIV_SCONTROL,,}" != "direct" ]]; then
    priv_cmds=(scontrol)
    priv_what="a job past MAX_JOB_HOURS could not be drained from here"
fi
if [[ "${#priv_cmds[@]}" -gt 0 ]] && ! priv_ready "${priv_cmds[@]}"; then
    warn "sudo as $me would refuse: $PRIV_MISSING -- $priv_what. Those rules are deployed by the site, via the BCM software image so they survive a reprovision; $home/agent/sudoers.default is the reference."
fi

## ── Lingering ─────────────────────────────────────────────────────────────
##
## Without it the user manager stops with the ssh session that armed the node
## and the timer goes with it. See docs/explanation/the-agent-and-the-watchdog.md#why-lingering.
if [[ "$(loginctl show-user "$me" -p Linger --value 2>/dev/null)" == "yes" ]]; then
    ok "lingering already enabled for $me"
elif loginctl enable-linger "$me" 2>/dev/null || priv loginctl enable-linger "$me" 2>/dev/null; then
    ok "enabled lingering for $me"
else
    fail "could not enable lingering for $me -- 'sudo loginctl enable-linger $me' on this host, or add the rule from agent/sudoers.default"
fi

## ── The unit ──────────────────────────────────────────────────────────────
##
## Through a temp file named for this host and this run. A shared $HOME means
## every node in one fan-out writes this directory at once, and a single temp
## name had them taking each other's file -- `mv` on a name another host had
## already moved, and a zero-length unit left behind, which systemd reports as
## masked. See docs/explanation/the-agent-and-the-watchdog.md#one-unit-for-both-roles.
dst="$HOME/.config/systemd/user"
mkdir -p "$dst" || fail "cannot create $dst"

## Left behind by the two-unit arrangement this replaced. Its enable symlink is
## shared too, so on a shared $HOME it would start a watchdog on every node.
stale=bringup-supervisor
if [[ -e "$dst/$stale.timer" || -e "$dst/$stale.service" || -L "$dst/timers.target.wants/$stale.timer" ]]; then
    systemctl --user disable --now "$stale.timer" >/dev/null 2>&1
    rm -f "$dst/$stale.timer" "$dst/$stale.service" "$dst/timers.target.wants/$stale.timer"
    ok "removed $stale, which no host's role decides any more"
fi

changed=0
for suffix in service timer; do
    src="$home/agent/units/$unit.$suffix"
    [[ -f "$src" ]] || { fail "$src is missing"; continue; }
    tmp="$dst/.$unit.$suffix.$HOSTNAME.$$"
    sed -e "s|@BRINGUP_HOME@|$home|g" -e "s|@INTERVAL@|$interval|g" "$src" > "$tmp" \
        || { fail "cannot write $tmp"; rm -f "$tmp"; continue; }
    ## A zero-length unit file, or a symlink to /dev/null, is what systemd calls
    ## masked -- so those are replaced rather than compared.
    if [[ -s "$dst/$unit.$suffix" && ! -L "$dst/$unit.$suffix" ]] && cmp -s "$tmp" "$dst/$unit.$suffix"; then
        rm -f "$tmp"
        ok "$unit.$suffix already current"
    else
        [[ -e "$dst/$unit.$suffix" && ! -s "$dst/$unit.$suffix" ]] &&
            ok "$unit.$suffix was empty, which systemd reads as masked -- replacing it"
        if mv -f "$tmp" "$dst/$unit.$suffix"; then
            changed=1; ok "installed $dst/$unit.$suffix"
        else
            fail "cannot install $dst/$unit.$suffix"; rm -f "$tmp"
        fi
    fi
done
[[ "$rc" -eq 0 ]] || { echo "refusing to start $unit.timer with a unit missing" >&2; exit "$rc"; }

## ── Start it ──────────────────────────────────────────────────────────────
systemctl --user daemon-reload 2>/dev/null || warn "systemctl --user daemon-reload failed"
out=$(systemctl --user enable --now "$unit.timer" 2>&1)
if [[ "$out" == *masked* ]]; then
    ## Nothing in this tree masks a unit, so this is an empty file seen through a
    ## manager that has not reloaded, or somebody's deliberate mask.
    systemctl --user unmask "$unit.timer" >/dev/null 2>&1
    systemctl --user daemon-reload 2>/dev/null
    out=$(systemctl --user enable --now "$unit.timer" 2>&1)
    [[ -n "$out" ]] || ok "unmasked $unit.timer"
fi
if [[ -z "$out" || ( "$out" != *Fail* && "$out" != *rror* ) ]]; then
    ok "$unit.timer enabled and started on $HOSTNAME"
else
    fail "systemctl --user enable --now $unit.timer -- $out"
fi

## `enable --now` does not restart a timer that is already running, so a changed
## interval or ExecStart would not take effect until the next reboot.
if [[ "$changed" -eq 1 ]]; then
    systemctl --user restart "$unit.timer" 2>/dev/null &&
        ok "restarted $unit.timer to pick up the new unit" ||
        warn "could not restart $unit.timer -- it is still running the previous unit"
fi

## ── Confirm what was just armed ───────────────────────────────────────────
##
## Everything above reports on what it asked systemd to do. These two ask what
## is actually true, because a host that reports a clean install and then never
## writes a heartbeat is the failure with no symptom -- the watchdog re-arms it,
## the install succeeds again, and nothing anywhere says why.
## See docs/how-to/arm-a-node.md#armed-but-never-heartbeats.
if ! systemctl --user is-active --quiet "$unit.timer" 2>/dev/null; then
    fail "$unit.timer is not active after enabling it -- 'systemctl --user status $unit.timer' on this host"
else
    next=$(systemctl --user list-timers "$unit.timer" --no-pager 2>/dev/null | awk 'NR==2 {print $1, $2, $3}')
    ok "$unit.timer is active${next:+, next elapse $next}"
fi

## The one thing a cycle must be able to do, tested as the cycle will do it. A
## results/<host> the account cannot write makes the node invisible to the
## watchdog for ever: no heartbeat, so it is armed again, every interval.
beat_dir="$home/results/$HOSTNAME"
if node_excluded "$HOSTNAME" || [[ "$ROLE" == "head" ]]; then
    :   ## no heartbeat is written here; the watchdog has its own
elif ! mkdir -p "$beat_dir" 2>/dev/null; then
    fail "cannot create $beat_dir, so this node will never write a heartbeat and the watchdog will keep arming it. sudo chown -R $JOB_USER:$JOB_USER $home/results"
elif ! touch "$beat_dir/.heartbeat" 2>/dev/null; then
    fail "cannot write $beat_dir/.heartbeat as $me -- $(stat -c '%U owns it' "$beat_dir" 2>/dev/null). This node will never be seen as alive. sudo chown -R $JOB_USER:$JOB_USER $home/results"
else
    ok "wrote $beat_dir/.heartbeat -- the watchdog can see this host is alive"
fi

if [[ "$rc" -ne 0 ]]; then
    echo "       one cycle by hand, which prints every gate it evaluates:" >&2
    echo "         $home/agent/cycle.sh --verbose" >&2
    echo "       and what the timer's own runs said:" >&2
    echo "         journalctl --user -u $unit.service -n 20 --no-pager" >&2
    echo "       See docs/how-to/arm-a-node.md#armed-but-never-heartbeats." >&2
fi

exit "$rc"
