#!/bin/bash
#
# Disarm this host: stop and disable the timer and remove the units. Lingering is
# left enabled -- it is the site's setting for the account, not this framework's,
# and turning it off would stop anything else the account runs.
#
# Nothing on disk under results/ is touched: a disarmed node keeps its results,
# its traces and its drains, and re-arming resumes the sweep where it stopped.
#
# See docs/how-to/arm-a-node.md#disarming-a-node.

home="${AGENT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[[ -f "$home/settings.sh" ]] && source "$home/settings.sh"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
dst="$HOME/.config/systemd/user"

for unit in bringup-agent bringup-supervisor; do
    [[ -f "$dst/$unit.timer" || -f "$dst/$unit.service" ]] || continue
    systemctl --user disable --now "$unit.timer" >/dev/null 2>&1
    rm -f "$dst/$unit.timer" "$dst/$unit.service"
    printf 'ok: removed %s on %s\n' "$unit" "$HOSTNAME"
done

systemctl --user daemon-reload 2>/dev/null
exit 0
