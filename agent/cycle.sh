#!/bin/bash
#
# What the timer runs, on every host. Decides at run time whether this host is a
# compute node or the one watching them, and hands over to the right script.
#
# One unit for both roles because $HOME is NFS-shared at most sites: every host
# reads the same ~/.config/systemd/user and the same `systemctl --user enable`
# state, so a unit that differs by role cannot survive that -- and one that is
# *enabled* by role is enabled for the whole fleet.
# See docs/explanation/the-agent-and-the-watchdog.md#one-unit-for-both-roles.

home="${AGENT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if [[ ! -f "$home/settings.sh" ]]; then
    echo "########ERROR: $home/settings.sh is missing -- refusing to run." >&2
    exit 1
fi
source "$home/settings.sh"
umask 0002

agent_role
if [[ "$AGENT_ROLE" == "head" ]]; then
    exec bash "$home/agent/supervisor.sh" "$@"
fi
exec bash "$home/agent/node-agent.sh" "$@"
