#!/bin/bash
#
# Arm this host: enable lingering for JOB_USER, install the systemd --user units
# out of agent/units/, and start the timer. Idempotent and safe to re-run -- it
# is what the head-node watchdog runs over pdsh on a node whose heartbeat has
# gone stale, as well as what an operator runs by hand.
#
# The role is decided here, not by the caller: a host that runs slurmctld and no
# slurmd gets the watchdog, everything else gets the node agent.
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

  --node   install the node agent even if this host looks like the head node
  --head   install the watchdog even if this host looks like a compute node

With no argument the role is decided from systemd: a host with slurmctld
installed and no slurmd is the head node. Re-running is how a unit or an
interval change is picked up.
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
## Not root: a root install puts the units under root's systemd and the cycle
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

if [[ -z "$ROLE" ]]; then
    if node_self_excluded || node_excluded "$HOSTNAME"; then ROLE="head"; else ROLE="node"; fi
fi
if [[ "$ROLE" == "head" ]]; then
    unit=bringup-supervisor
    script="$home/agent/supervisor.sh"
    interval="$SUPERVISOR_INTERVAL_MINUTES"
else
    unit=bringup-agent
    script="$home/agent/node-agent.sh"
    interval="$AGENT_INTERVAL_MINUTES"
fi
[[ "$interval" =~ ^[1-9][0-9]*$ ]] || {
    warn "interval for $unit is '$interval', which is not a whole number of minutes -- using 2"
    interval=2
}

## ── Preflight ─────────────────────────────────────────────────────────────
##
## An exec bit is easy to lose in transit, and a timer pointed at a file that
## will not run reports active and does nothing.
if [[ ! -f "$script" ]]; then
    fail "$script does not exist -- nothing to arm"
elif [[ ! -x "$script" ]]; then
    chmod +x "$script" 2>/dev/null && ok "restored exec bit on $script" \
        || fail "$script is not executable and chmod failed"
fi
command -v systemctl >/dev/null 2>&1 || fail "systemctl is not installed -- this host cannot run a timer"
[[ "$rc" -eq 0 ]] || { echo "refusing to arm $HOSTNAME while something is unusable" >&2; exit "$rc"; }

## A missing sudo rule is a warning, not a refusal: two of the three steps need
## no privilege at all, and node_health.sh is where the missing rule becomes
## fatal -- for the run it would otherwise misjudge, not for the whole node.
## See docs/explanation/running-unprivileged.md#a-lost-rule-must-stop-the-run.
if [[ "$ROLE" == "node" ]]; then
    mapfile -t priv_cmds < <(grep -hoE 'sudo -n [a-z0-9_.-]+' "$HEALTHCHECKS_DIR"/[0-9]*.sh 2>/dev/null | awk '{print $3}' | sort -u)
    if [[ "${#priv_cmds[@]}" -gt 0 ]] && ! priv_ready "${priv_cmds[@]}"; then
        warn "sudo as $me would refuse: $PRIV_MISSING -- the health checks needing them will not run. Install $home/agent/sudoers.default as /etc/sudoers.d/50-bringup."
    fi
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

## ── The units ─────────────────────────────────────────────────────────────
##
## Copied rather than symlinked into the exported tree: a unit file systemd
## cannot read through an NFS stall is a node that does not come back.
dst="$HOME/.config/systemd/user"
mkdir -p "$dst" || fail "cannot create $dst"
for suffix in service timer; do
    src="$home/agent/units/$unit.$suffix"
    [[ -f "$src" ]] || { fail "$src is missing"; continue; }
    tmp="$dst/.$unit.$suffix.new"
    sed -e "s|@BRINGUP_HOME@|$home|g" -e "s|@INTERVAL@|$interval|g" "$src" > "$tmp" \
        || { fail "cannot write $tmp"; continue; }
    if cmp -s "$tmp" "$dst/$unit.$suffix"; then
        rm -f "$tmp"
        ok "$unit.$suffix already current"
    else
        mv "$tmp" "$dst/$unit.$suffix" && ok "installed $dst/$unit.$suffix"
    fi
done
[[ "$rc" -eq 0 ]] || { echo "refusing to start $unit.timer with a unit missing" >&2; exit "$rc"; }

## ── Start it ──────────────────────────────────────────────────────────────
systemctl --user daemon-reload 2>/dev/null || warn "systemctl --user daemon-reload failed"
if out=$(systemctl --user enable --now "$unit.timer" 2>&1); then
    ok "$unit.timer enabled and started on $HOSTNAME"
else
    fail "systemctl --user enable --now $unit.timer -- $out"
fi

exit "$rc"
