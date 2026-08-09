#!/bin/bash
#
# Usage: dmesg-archive.sh [-n] [--clear] [--resume] [--force] [-s glob] [-o dir] <nodelist> ...
#
# Saves each node's kernel ring buffer into the tree, and optionally clears it
# and resumes the node. For the one drain the recovery cannot argue its way out
# of: a node whose dmesg has filled with call traces fails BCM's pre-job `dmesg`
# check on every job, so it drains, resumes, drains again, and spends its
# attempt cap discovering that. Clearing the buffer is what breaks the loop.
#
# See docs/how-to/archive-and-clear-dmesg.md.
#
#   <nodelist>   required, repeatable, expanded through `scontrol show
#                hostnames`, so ink50-dh01-d06-[17-18,28-31] is one argument.
#                There is deliberately no fleet-wide default and no pattern
#                matching: this destroys kernel evidence on every node it
#                reaches, so the set is always typed out in full.
#
#   --clear      clear the buffer after saving, with `dmesg -C`. Two things have
#                to hold first, per node, or that node is skipped: the save came
#                back non-empty, and the node appears in the head node's syslog.
#
#                This takes SEVEN health checks to zero, not just the one that
#                drained the node: every health-checks/*/3N-dmesg-*.sh counts
#                matches in the live buffer. A node failing dmesg-xid,
#                dmesg-knvlink or dmesg-nv_err is reporting hardware, and
#                clearing it hides that until the messages come back. Archive
#                those without --clear.
#
#   -s, --syslog <glob>
#                where the head node keeps forwarded kernel messages. Default
#                /var/log/messages*. This is the long-term copy the archive
#                points at, and the thing --clear checks before destroying the
#                node's own.
#
#                Read on the host you run this from -- it is a local grep, not a
#                pdsh -- so run it on the head node the fleet forwards to, and
#                read the `on <host>` line to see which one that was. Matched as
#                `<node> kernel:`, so a line that merely names the node is not
#                counted as coverage.
#
#   --force      clear even where syslog could not be confirmed. For a site that
#                forwards somewhere this cannot see -- say so in the run, do not
#                make it the default.
#
#   --resume     scontrol update State=RESUME afterwards. Usually needed: a node
#                that flapped to RECOVER_MAX_ATTEMPTS is left drained for an
#                operator, and nothing in the tree will pick it up again.
#
#   -o, --archive-dir <dir>
#                where to write. Default $BRINGUP_HOME/dmesg-archive, which is
#                outside results/ on purpose -- single-node-purge.sh removes
#                results/<node> outright, and a kernel log should outlive that.
#
#   -n, --dry-run
#                print what would be saved, cleared and resumed, and stop. The
#                node list and the syslog check both still run, so it is the
#                real set and the real verdict.
#
# One file per node per run, at <dir>/<node>/<YYYYmmdd-HHMMSS>.txt, opening with
# the drain reason as it read at capture time and the command that gets the same
# node out of the head node's syslog. When --clear fires it appends a line
# saying so, because a buffer that starts empty afterwards otherwise looks like
# a node with nothing wrong.
#
# --- end of --help text; tests/help-text-test.sh keeps the -h range in step ---

set -u

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$home/settings.sh"

clear_buf=0
resume=0
dryrun=0
force=0
syslog='/var/log/messages*'
archive="${BRINGUP_HOME:-$home}/dmesg-archive"
args=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clear)          clear_buf=1; shift ;;
        --resume)         resume=1; shift ;;
        --force)          force=1; shift ;;
        -n|--dry-run)     dryrun=1; shift ;;
        -s|--syslog)      syslog="${2:-}"; shift 2 ;;
        -o|--archive-dir) archive="${2:-}"; shift 2 ;;
        -h|--help)
            sed -n '2,65p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        -*) echo "${0##*/}: unknown option '$1'" >&2; exit 1 ;;
        *)  args+=("$1"); shift ;;
    esac
done

if [[ "${#args[@]}" -eq 0 ]]; then
    echo "Usage: ${0##*/} [-n] [--clear] [--resume] [-s glob] [-o dir] <nodelist> ..." >&2
    echo "No node list given. This one is never fleet-wide by default." >&2
    exit 1
fi

mapfile -t nodes < <(
    for a in "${args[@]}"; do
        scontrol show hostnames "$a" 2>/dev/null || printf '%s\n' "$a"
    done | sort -u
)
[[ "${#nodes[@]}" -gt 0 ]] || { echo "${0##*/}: no nodes to act on" >&2; exit 1; }

nodelist=$(IFS=,; printf '%s' "${nodes[*]}")

## One sinfo for the whole set, so the header line can say what the node was
## drained for at the moment its buffer was taken.
declare -A reason
while IFS='|' read -r n r; do
    [[ -n "$n" ]] && reason["$n"]="$r"
done < <(sinfo -N -h -n "$nodelist" -o '%N|%E' 2>/dev/null | sort -u)

## Does the long-term copy actually have this node? Read here, on the host this
## is invoked from, not out on the nodes -- and matched as `<host> kernel:`, so
## a line that merely mentions the name is not read as coverage. Unreadable logs
## answer "no" rather than "probably".
## docs/how-to/archive-and-clear-dmesg.md#is-syslog-enough
declare -A in_syslog
for n in "${nodes[@]}"; do
    # shellcheck disable=SC2086  # $syslog is a glob and must stay unquoted
    if grep -Em1 -q -- "(^|[[:space:]])${n}[[:space:]]+kernel" $syslog 2>/dev/null; then
        in_syslog["$n"]=yes
    else
        in_syslog["$n"]=no
    fi
done

stamp=$(date '+%Y%m%d-%H%M%S')
syslog_cmd() { printf 'grep -hE -- "(^|[[:space:]])%s[[:space:]]+kernel" %s' "$1" "$syslog"; }

echo "== ${#nodes[@]} node(s), archive $archive/<node>/$stamp.txt"
echo "== long-term copy: $syslog on $(hostname -s)"

if [[ "$dryrun" -eq 1 ]]; then
    for n in "${nodes[@]}"; do
        printf '   would save   %-26s syslog:%-3s %s\n' \
            "$n" "${in_syslog[$n]}" "${reason[$n]:-<no drain reason>}"
    done
    if [[ "$clear_buf" -eq 1 ]]; then
        echo "   would clear  nodes whose save is non-empty and whose syslog reads yes"
        [[ "$force" -eq 1 ]] && echo "   --force is set, so syslog:no would be cleared too"
    fi
    [[ "$resume" -eq 1 ]] && echo "   would resume the same set"
    exit 0
fi

for n in "${nodes[@]}"; do
    mkdir -p "$archive/$n" || exit 1
    {
        printf '## %s dmesg captured %s -- drain reason at capture: %s\n' \
            "$n" "$(date '+%F %T')" "${reason[$n]:-<none>}"
        printf '## long-term copy on %s (present: %s):  %s\n' \
            "$(hostname -s)" "${in_syslog[$n]}" "$(syslog_cmd "$n")"
    } > "$archive/$n/$stamp.txt"
done

## `--time-format=iso` is util-linux 2.30 and later; -T is the older spelling
## and a bare dmesg is the fallback that always answers.
pdsh -R ssh -w "$nodelist" \
    'dmesg --time-format=iso 2>/dev/null || dmesg -T 2>/dev/null || dmesg' 2>/dev/null |
    awk -v dir="$archive" -v stamp="$stamp" '
        { i = index($0, ": "); if (i == 0) next
          node = substr($0, 1, i - 1)
          print substr($0, i + 2) >> (dir "/" node "/" stamp ".txt") }'

## Two ways a node is not safe to clear, and they are reported apart because
## they need different things done about them.
saved=()
empty=()
unlogged=()
for n in "${nodes[@]}"; do
    lines=$(( $(wc -l < "$archive/$n/$stamp.txt") - 2 ))
    if [[ "$lines" -le 0 ]]; then
        empty+=("$n")
        printf '## nothing came back; the buffer was never read here, and never cleared\n' \
            >> "$archive/$n/$stamp.txt"
        printf '   EMPTY        %-26s nothing came back -- not cleared, not resumed\n' "$n"
    elif [[ "${in_syslog[$n]}" == "no" && "$force" -eq 0 ]]; then
        unlogged+=("$n")
        printf '   NO SYSLOG    %-26s %s lines saved, but not cleared\n' "$n" "$lines"
    else
        saved+=("$n")
        printf '   saved        %-26s %s lines   syslog:%s\n' \
            "$n" "$lines" "${in_syslog[$n]}"
    fi
done

if [[ "${#empty[@]}" -gt 0 ]]; then
    echo "   ${#empty[@]} node(s) returned no dmesg. Unreachable, or dmesg is root-only here:"
    echo "     pdsh -R ssh -w $(IFS=,; printf '%s' "${empty[*]}") 'dmesg | tail -5'"
fi
if [[ "${#unlogged[@]}" -gt 0 ]]; then
    echo "   ${#unlogged[@]} node(s) are not in $syslog, so the archive is the only copy."
    echo "   Their buffers were left alone. Re-run with --force to clear anyway."
fi
[[ "${#saved[@]}" -gt 0 ]] || exit 1

savedlist=$(IFS=,; printf '%s' "${saved[*]}")

if [[ "$clear_buf" -eq 1 ]]; then
    pdsh -R ssh -w "$savedlist" 'dmesg -C' 2>&1 | sed 's/^/   clear: /'
    for n in "${saved[@]}"; do
        printf '## ring buffer cleared %s by %s; anything older is only in the syslog above\n' \
            "$(date '+%F %T')" "${USER:-unknown}" >> "$archive/$n/$stamp.txt"
    done
    echo "   cleared      ${#saved[@]} node(s). The seven dmesg health checks now read 0 here."
fi

if [[ "$resume" -eq 1 ]]; then
    out=$(scontrol update NodeName="$savedlist" State=RESUME 2>&1)
    ## scontrol is quiet on success, so any output is the failure.
    if [[ -n "$out" ]]; then
        echo "   RESUME FAILED: $out" >&2
        exit 1
    fi
    echo "   resumed      ${#saved[@]} node(s)"
fi

echo "== archive kept at $archive; it is not touched by single-node-purge.sh"
