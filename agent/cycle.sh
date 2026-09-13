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

## The timer calls this with --quiet. Keep unexpected child output off journald
## while retaining it on the compute-facing health share. Interactive runs
## still print to the terminal. A broken share falls back to the journal so the
## missing diagnostic destination remains visible.
quiet=0
for arg in "$@"; do
    [[ "$arg" == "--quiet" || "$arg" == "-q" ]] && quiet=1
done
if [[ "$quiet" -eq 1 ]]; then
    ## Automated fan-out uses the service account's key files. Inheriting an
    ## interactive GnuPG SSH socket wakes gpg-agent once per connection and can
    ## flood the journal when its smart-card daemon is unavailable.
    unset SSH_AUTH_SOCK GPG_AGENT_INFO
    if [[ "$AGENT_ROLE" == "head" ]]; then
        service_log_dir="${HEALTH_LOG_DIR%/}/_supervisor"
    else
        service_log_dir="${HEALTH_LOG_DIR%/}/$HOSTNAME"
    fi
    service_log="$service_log_dir/service.log"
    if mkdir -p "$service_log_dir" 2>/dev/null && { : >> "$service_log"; } 2>/dev/null; then
        if [[ "$(stat -c %s "$service_log" 2>/dev/null || echo 0)" -gt 1000000 ]]; then
            tail -2000 "$service_log" > "$service_log.tmp" && mv "$service_log.tmp" "$service_log"
        fi
        exec >> "$service_log" 2>&1
    else
        echo "WARNING: cannot write $service_log as $(id -un); quiet-cycle output remains in the service journal." >&2
    fi
fi

if [[ "$AGENT_ROLE" == "head" ]]; then
    exec bash "$home/agent/supervisor.sh" "$@"
fi
exec bash "$home/agent/node-agent.sh" "$@"
