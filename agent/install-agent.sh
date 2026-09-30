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
QUIET=0
usage() {
    cat <<USAGE
Usage: install-agent.sh [--node|--head] [--quiet] [--help]

  --node   report this host as a compute node whatever it looks like
  --head   report it as the host that watches them
  --quiet  one line for this host: ARMED, or the WARNING and FAILED lines.
           What a fan-out over the fleet wants; run it without to see every
           step. See docs/how-to/arm-a-node.md#one-line-per-node

Both install the same unit -- cycle.sh asks the same question again on every
run, so these change what this run checks and prints, not what gets installed.
Re-running is how a changed unit or interval is picked up.

On the host that serves \$BRINGUP_HOME this refuses to arm unless
fs.leases-enable is 0. ALLOW_NFS_DELEGATIONS=yes forces it past that and is a
bad idea -- docs/explanation/the-fleet-snapshot.md
USAGE
}
for arg in "$@"; do
    case "$arg" in
        --node) ROLE="node" ;;
        --head) ROLE="head" ;;
        -q|--quiet) QUIET=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unrecognised argument '$arg' -- nothing was installed." >&2
           usage >&2; exit 2 ;;
    esac
done

## Two hundred nodes saying the same thing should read as one line, and clubak
## groups on an exact match -- so under --quiet a message carries no hostname,
## no timestamp and no pid, and the caller's own label says which host it was.
## See docs/how-to/arm-a-node.md#one-line-per-node.
rc=0
warns=0
say() { [[ "$QUIET" -eq 1 ]] && printf '%s\n' "${1//$HOSTNAME/<host>}" || printf '%s\n' "$1"; }
ok()   { [[ "$QUIET" -eq 1 ]] || printf 'ok: %s\n' "$*"; }
warn() { say "WARNING: $*" >&2; warns=$((warns + 1)); }
fail() { say "FAILED: $*" >&2; rc=1; }

## ── Who is running this ───────────────────────────────────────────────────
##
## Not root: a root install puts the unit under root's systemd and the cycle
## back where this whole change took it out of.
## See docs/explanation/running-unprivileged.md.
me=$(id -un)
if [[ "$me" != "$JOB_USER" ]]; then
    fail "running as $me, and the agent runs as $JOB_USER -- the timer would go into the wrong user's systemd. docs/explanation/running-unprivileged.md"
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
## OnCalendar=*:0/N repeats within the hour, so N has to divide 60 or the last
## step of each hour is short. See docs/reference/settings.md#the-agent-and-the-watchdog.
case "$interval" in
    1|2|3|4|5|6|10|12|15|20|30) ;;
    *)  warn "AGENT_INTERVAL_MINUTES='$interval' does not divide 60 -- using 2. docs/reference/settings.md#the-agent-and-the-watchdog"
        interval=2 ;;
esac

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

## ── The host that serves the tree must not grant delegations ──────────────
##
## Only where it is served from: a client has nothing to grant and a host with
## no nfsd exports nothing. See docs/explanation/the-fleet-snapshot.md#the-server-must-not-hand-out-delegations.
deleg_skip=""
if [[ "$(stat -f -c %T "$home" 2>/dev/null)" == nfs* ]]; then
    deleg_skip="$home is an NFS mount here, so this host reads the tree rather than serving it"
elif [[ ! -r /proc/fs/nfsd/threads ]]; then
    deleg_skip="nfsd is not running, so nothing is served from here"
fi
leases=""
[[ -r /proc/sys/fs/leases-enable ]] && read -r leases < /proc/sys/fs/leases-enable
if [[ -n "$deleg_skip" ]]; then
    ok "NFSv4 delegations do not apply here: $deleg_skip"
elif [[ -z "$leases" ]]; then
    warn "could not read /proc/sys/fs/leases-enable -- whether this host grants NFSv4 delegations is unknown, and the stall that causes reads as a dead watchdog rather than as a filesystem. docs/explanation/the-fleet-snapshot.md#the-server-must-not-hand-out-delegations"
elif [[ "$leases" == 0 ]]; then
    ok "fs.leases-enable=0 -- this host grants no NFSv4 delegations"
elif setting_enabled "$ALLOW_NFS_DELEGATIONS"; then
    warn "ALLOW_NFS_DELEGATIONS=$ALLOW_NFS_DELEGATIONS overrode fs.leases-enable=$leases, and nothing here can soften what that means: every results/<node>/.slurm-view the watchdog rewrites must first be recalled from a node that may not answer, at about 30s each, so enough silent nodes stop the whole fleet. Set it back. docs/explanation/the-fleet-snapshot.md#the-server-must-not-hand-out-delegations"
else
    fail "fs.leases-enable=$leases on $HOSTNAME, which serves $home -- it would grant an NFSv4 delegation on every results/<node>/.slurm-view, and recalling those stops the watchdog writing any of them. Required, not tuning. Fix it and arm again:
        echo 'fs.leases-enable = 0' | sudo tee /etc/sysctl.d/90-nfsd-no-delegations.conf
        sudo sysctl --system
    ALLOW_NFS_DELEGATIONS=yes forces the install past this. It is a bad idea and not a supported configuration -- it does not make the recalls cheaper, it only removes the one warning you would get before the fleet stops. docs/explanation/the-fleet-snapshot.md#the-server-must-not-hand-out-delegations"
fi

[[ "$rc" -eq 0 ]] || { say "refusing to arm while something is unusable" >&2; exit "$rc"; }

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
    warn "sudo would refuse: $PRIV_MISSING -- $priv_what. docs/explanation/running-unprivileged.md#the-sudoers-drop-in"
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
    fail "could not enable lingering for $me -- the timer dies with the ssh session. docs/explanation/the-agent-and-the-watchdog.md#why-lingering"
fi

## The flag above takes effect next login, not this session -- checked here
## rather than let a missing bus read as five unrelated failures below.
## See docs/how-to/enable-lingering-before-installing.md.
if [[ "$rc" -eq 0 && ! -S "$XDG_RUNTIME_DIR/bus" ]]; then
    fail "no user bus reachable in this session, even though lingering is enabled for $me now -- it takes effect on your NEXT login, not this one. Log out and back in (or open a fresh ssh session as $me) and re-run install-agent.sh. docs/how-to/enable-lingering-before-installing.md"
fi

[[ "$rc" -eq 0 ]] || { say "refusing to install units without a session systemctl --user can reach" >&2; exit "$rc"; }

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
    sed -e "s|@BRINGUP_HOME@|$home|g" -e "s|@INTERVAL@|$interval|g" \
        -e "s|@SPREAD@|$(( interval * 30 ))|g" "$src" > "$tmp" \
        || { fail "cannot write into $dst"; rm -f "$tmp"; continue; }
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
[[ "$rc" -eq 0 ]] || { say "refusing to start $unit.timer with a unit missing" >&2; exit "$rc"; }

## ── Start it ──────────────────────────────────────────────────────────────
systemctl --user daemon-reload 2>/dev/null || warn "systemctl --user daemon-reload failed"
out=$(systemctl --user enable "$unit.timer" 2>&1)
if [[ "$out" == *masked* ]]; then
    ## Nothing in this tree masks a unit, so this is an empty file seen through a
    ## manager that has not reloaded, or somebody's deliberate mask.
    systemctl --user unmask "$unit.timer" >/dev/null 2>&1
    systemctl --user daemon-reload 2>/dev/null
    out=$(systemctl --user enable --now "$unit.timer" 2>&1)
    [[ -n "$out" ]] || ok "unmasked $unit.timer"
fi
if [[ -z "$out" || ( "$out" != *Fail* && "$out" != *rror* ) ]]; then
    ok "$unit.timer enabled and started"
else
    fail "systemctl --user enable --now $unit.timer -- $out"
fi

## Restarted every time, not only when this host rewrote the file. $HOME is
## shared, so the first node to run this replaces the unit for the whole fleet
## and every other node sees "already current" -- while its own manager is still
## running whatever it loaded when it was last armed. `changed` says what
## happened on disk, which is not what this manager has in memory. A calendar
## timer's next elapse is the same wall-clock tick either way, so restarting
## costs nothing. See docs/explanation/the-agent-and-the-watchdog.md#one-unit-for-both-roles.
if systemctl --user restart "$unit.timer" 2>/dev/null; then
    [[ "$changed" -eq 1 ]] && ok "restarted $unit.timer on the unit this run installed" \
                           || ok "restarted $unit.timer so this manager is running the current unit"
else
    fail "could not restart $unit.timer -- it may still be running an older unit"
fi

## ── Confirm what was just armed ───────────────────────────────────────────
##
## Everything above reports on what it asked systemd to do. These two ask what
## is actually true, because a host that reports a clean install and then never
## writes a heartbeat is the failure with no symptom -- the watchdog re-arms it,
## the install succeeds again, and nothing anywhere says why.
## See docs/how-to/arm-a-node.md#armed-but-never-heartbeats.

## Resolved by the source above; nowhere readable still cycles, on coded
## defaults. See docs/how-to/arm-a-node.md#armed-with-no-settings.
if [[ -z "$SETTINGS_FILE" ]]; then
    fail "SETTINGS_HOME resolves nowhere readable -- cycling on settings.sh's coded defaults, not this site's. docs/how-to/arm-a-node.md#armed-with-no-settings"
else
    ok "reading settings from $SETTINGS_FILE"
fi

if ! systemctl --user is-active --quiet "$unit.timer" 2>/dev/null; then
    fail "$unit.timer is not active after enabling it. docs/how-to/arm-a-node.md#armed-but-never-heartbeats"
else
    ## Active is not the same as scheduled: a timer whose next elapse is
    ## `infinity` reports active, reports Result=success, and never fires again.
    ##
    ## Retried, because `systemctl restart` returns before the timer has
    ## computed its next elapse: asking immediately gets an empty answer on a
    ## node that is perfectly healthy a second later. Half a second, five times,
    ## and only for a node that has not answered yet.
    ## See docs/how-to/arm-a-node.md#armed-but-never-heartbeats.
    scheduled=""; next_r=""; next_m=""
    for _try in 1 2 3 4 5; do
        next_r=$(systemctl --user show "$unit.timer" -p NextElapseUSecRealtime --value 2>/dev/null)
        next_m=$(systemctl --user show "$unit.timer" -p NextElapseUSecMonotonic --value 2>/dev/null)
        for _v in "$next_r" "$next_m"; do
            case "$_v" in
                ""|0|infinity|n/a) ;;
                *) scheduled="$_v"; break ;;
            esac
        done
        [[ -n "$scheduled" ]] && break
        [[ "$_try" -lt 5 ]] && sleep 0.5
    done
    unset _v _try
    ## Which timers the loaded unit carries, which the elapse times cannot say:
    ## a calendar timer reports monotonic=infinity by construction, so the
    ## known-bad signature and a healthy restart are the same two values.
    ## See docs/how-to/arm-a-node.md#armed-but-never-heartbeats.
    cal=$(systemctl --user show "$unit.timer" -p TimersCalendar --value 2>/dev/null)
    mono=$(systemctl --user show "$unit.timer" -p TimersMonotonic --value 2>/dev/null)
    if [[ -n "$scheduled" ]]; then
        ok "$unit.timer is scheduled, next elapse $(systemctl --user list-timers "$unit.timer" --no-pager 2>/dev/null | awk 'NR==2 {print $1, $2, $3}')"
    elif [[ -n "$mono" && -z "$cal" ]]; then
        fail "$unit.timer active, next elapse never -- monotonic unit still loaded. docs/how-to/arm-a-node.md#armed-but-never-heartbeats"
    elif [[ -n "$cal" ]]; then
        ok "$unit.timer is active on the calendar unit this run installed; systemd had not computed a next elapse yet -- 'systemctl --user list-timers $unit.timer' is the readable answer"
    else
        ok "$unit.timer is active; systemd reported no next elapse (realtime=[$next_r] monotonic=[$next_m]) -- 'systemctl --user list-timers $unit.timer' is the readable answer"
    fi
fi

## `enable --now` starts the timer, not the service, and a calendar timer then
## waits for its first tick -- so a freshly armed node would look silent for a
## whole interval and get armed again. --no-block: the caller is a fan-out.
systemctl --user start --no-block "$unit.service" 2>/dev/null &&
    ok "started one cycle now rather than waiting for the first tick" ||
    warn "could not start $unit.service -- the first cycle waits for the timer"

## The one thing a cycle must be able to do, tested as the cycle will do it. A
## results/<host> the account cannot write makes the node invisible to the
## watchdog for ever: no heartbeat, so it is armed again, every interval.
beat_dir="$RESULTS_DIR/$HOSTNAME"
if node_excluded "$HOSTNAME" || [[ "$ROLE" == "head" ]]; then
    :   ## no heartbeat is written here; the watchdog has its own
elif ! mkdir -p "$beat_dir" 2>/dev/null; then
    fail "cannot create $beat_dir -- this node can never write a heartbeat. docs/how-to/arm-a-node.md#armed-but-never-heartbeats"
elif ! touch "$beat_dir/.heartbeat" 2>/dev/null; then
    fail "cannot write $beat_dir/.heartbeat as $me -- $(stat -c '%U owns it' "$beat_dir" 2>/dev/null). docs/how-to/arm-a-node.md#armed-but-never-heartbeats"
else
    ok "wrote $beat_dir/.heartbeat -- the watchdog can see this host is alive"
fi

## Not a fail: a node that cannot warm this cache still runs every job, off the
## shared path, at the cost of an NFS read per start instead of a local one --
## unlike the heartbeat above, nothing about arming depends on it. /opt is
## root-owned on a stock image, so this is the check that says so once instead
## of file_copy.sh tracing "cannot create" quietly, every cycle, forever.
## See docs/explanation/containers.md#one-share-two-mount-points.
if [[ "$ROLE" != "head" ]] && ! node_excluded "$HOSTNAME"; then
    if mkdir -p "$NODE_CONTAINER_DIR" 2>/dev/null; then
        ok "$NODE_CONTAINER_DIR is writable -- the container cache can warm"
    else
        warn "cannot create $NODE_CONTAINER_DIR as $me -- $(stat -c '%U owns %n' "$(dirname "$NODE_CONTAINER_DIR")" 2>/dev/null || echo 'the parent directory does not exist either'). Jobs still run, off CONTAINER_DIR over NFS. Fix: as root, on this node, 'mkdir -p $NODE_CONTAINER_DIR && chown $me $NODE_CONTAINER_DIR' -- or set NODE_CONTAINER_DIR to somewhere $me already owns."
    fi
fi

## The three states partition the fleet, so a caller can tally them: a host says
## ARMED, or it says why it did not, and never both.
if [[ "$QUIET" -eq 1 ]]; then
    [[ "$rc" -eq 0 && "$warns" -eq 0 ]] && echo "ARMED"
elif [[ "$rc" -ne 0 ]]; then
    echo "       one cycle by hand, which prints every gate it evaluates:" >&2
    echo "         $home/agent/cycle.sh --verbose" >&2
    echo "       and what the timer's own runs said:" >&2
    echo "         journalctl --user -u $unit.service -n 20 --no-pager" >&2
    echo "       See docs/how-to/arm-a-node.md#armed-but-never-heartbeats." >&2
fi

exit "$rc"
