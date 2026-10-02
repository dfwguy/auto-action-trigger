#!/bin/bash
# The fleet control script must not inspect the wrong user's systemd and call
# its missing timer STOPPED. An explicit --sudo is the only user transition.

set -u

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
ok()  { printf 'ok       %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAILED   %s -- %s\n' "$1" "$2"; fail=$((fail + 1)); }

cp "$home/admin_pause-agents.sh" "$work/admin_pause-agents.sh"
printf 'JOB_USER=some-other-user\n' > "$work/settings.sh"
printf '# test stub\n' > "$work/fanout.sh"

if out=$(bash "$work/admin_pause-agents.sh" --status 2>&1); then
    bad "wrong user is refused" "exit status was zero"
elif [[ "$out" != *"agents run as JOB_USER=some-other-user"* ]]; then
    bad "wrong user is refused" "the error did not name JOB_USER"
elif [[ "$out" != *"--sudo --status"* ]]; then
    bad "wrong user is refused" "the error did not give the explicit retry"
else
    ok "wrong user is refused with an explicit retry"
fi

mkdir "$work/bin"
printf '#!/bin/bash\nprintf "sudo args:"\nprintf " <%%s>" "$@"\nprintf "\\n"\n' > "$work/bin/sudo"
chmod +x "$work/bin/sudo"
if ! out=$(PATH="$work/bin:$PATH" bash "$work/admin_pause-agents.sh" --sudo --status rack1 2>&1); then
    bad "--sudo re-executes as JOB_USER" "the sudo stub failed"
elif [[ "$out" != *"switching from "*" to configured JOB_USER some-other-user through sudo"* ]]; then
    bad "--sudo re-executes as JOB_USER" "the transition was not announced"
elif [[ "$out" != *"sudo args: <-iu> <some-other-user> <bash> <$work/admin_pause-agents.sh> <--status> <rack1>"* ]]; then
    bad "--sudo re-executes as JOB_USER" "arguments were not preserved: $out"
elif [[ "$out" == *"<--sudo>"* ]]; then
    bad "--sudo re-executes as JOB_USER" "--sudo was forwarded and would recurse"
else
    ok "--sudo re-executes once and preserves arguments"
fi

if bash "$work/admin_pause-agents.sh" --help 2>&1 | grep -q -- '--sudo'; then
    ok "--help documents --sudo without requiring JOB_USER"
else
    bad "--help documents --sudo" "help failed or omitted the switch"
fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
