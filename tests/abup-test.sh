#!/bin/bash
#
# Checks abup's dispatch: the two-word mapping to <group>_<name>.sh, argument
# forwarding, exit-code passthrough, self-location by symlink and by
# BRINGUP_HOME, and the derived (not maintained) command list.
# See docs/how-to/install-abup.md.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
ok()  { printf 'ok       %-46s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL     %-46s %s\n' "$1" "$2"; fail=$((fail + 1)); }

## A fake tree: just enough for abup's own SETTINGS check to find it, plus a
## couple of stub commands that record how they were called.
tree="$work/tree"
mkdir -p "$tree"
cp "$home/abup" "$tree/abup"
cp "$home/SETTINGS.default" "$tree/SETTINGS.default"
cat > "$tree/check_stub.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "$STUB_CALLED"
exit 0
EOF
cat > "$tree/report_fails.sh" <<'EOF'
#!/bin/bash
exit 42
EOF
chmod 755 "$tree/abup" "$tree"/*.sh

echo "== dispatch, with the group/name mapping and argument forwarding =="

export STUB_CALLED="$work/called.txt"
rm -f "$STUB_CALLED"
if "$tree/abup" check stub -x --foo bar >/dev/null; then
    ok "dispatch exits clean" "yes"
else
    bad "dispatch exits clean" "non-zero exit"
fi
if [[ "$(cat "$STUB_CALLED" 2>/dev/null)" == "-x --foo bar" ]]; then
    ok "arguments forwarded past the group/name" "-x --foo bar"
else
    bad "arguments forwarded past the group/name" "got: $(cat "$STUB_CALLED" 2>/dev/null)"
fi

echo "== exit code passes through unchanged =="

"$tree/abup" report fails
if [[ "$?" -eq 42 ]]; then
    ok "exec, not a subshell -- the target's own exit code survives" "42"
else
    bad "exec, not a subshell -- the target's own exit code survives" "got $?"
fi

echo "== unknown command names what was tried and lists its own group =="

out=$("$tree/abup" report nowhere 2>&1); rc=$?
if [[ "$rc" -ne 0 ]]; then
    ok "unknown command is a non-zero exit" "$rc"
else
    bad "unknown command is a non-zero exit" "exit 0"
fi
if [[ "$out" == *"report nowhere"* ]]; then
    ok "names the command that was not found" "reported"
else
    bad "names the command that was not found" "$out"
fi
if [[ "$out" == *"report fails"* ]]; then
    ok "lists the rest of its own group alongside the error" "report fails present"
else
    bad "lists the rest of its own group alongside the error" "$out"
fi
if [[ "$out" != *"check stub"* ]]; then
    ok "does not list a different group's commands" "check stub absent"
else
    bad "does not list a different group's commands" "check stub leaked in: $out"
fi

echo "== <group> -h narrows the listing to that group =="

out=$("$tree/abup" check -h 2>&1); rc=$?
if [[ "$rc" -eq 0 ]]; then
    ok "<group> -h exits clean" "yes"
else
    bad "<group> -h exits clean" "got $rc"
fi
if [[ "$out" == *"check stub"* ]]; then
    ok "lists that group's commands" "check stub present"
else
    bad "lists that group's commands" "$out"
fi
if [[ "$out" != *"report fails"* ]]; then
    ok "leaves out every other group" "report fails absent"
else
    bad "leaves out every other group" "report fails leaked in: $out"
fi

out=$("$tree/abup" check 2>&1); rc=$?
if [[ "$rc" -ne 0 ]]; then
    ok "<group> alone (no name, no -h) is a non-zero exit" "$rc"
else
    bad "<group> alone (no name, no -h) is a non-zero exit" "exit 0"
fi
if [[ "$out" == *"check stub"* && "$out" != *"report fails"* ]]; then
    ok "but still shows the same narrowed list" "check stub only"
else
    bad "but still shows the same narrowed list" "$out"
fi

echo "== the command list is derived, not written down here =="

## A third stub that this test never names anywhere else: if it shows up in
## --help, the list came from the filesystem.
cat > "$tree/admin_surprise.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod 755 "$tree/admin_surprise.sh"
out=$("$tree/abup" --help 2>&1)
if [[ "$out" == *"admin surprise"* ]]; then
    ok "a script dropped into the tree appears in --help unaided" "admin surprise listed"
else
    bad "a script dropped into the tree appears in --help unaided" "$out"
fi
if [[ "$out" == *"check stub"* ]]; then
    ok "--help also lists the earlier stub" "check stub listed"
else
    bad "--help also lists the earlier stub" "$out"
fi

echo "== no command and -h/--help are different outcomes =="

"$tree/abup" >/dev/null 2>&1
if [[ "$?" -ne 0 ]]; then
    ok "no command at all is a non-zero exit" "yes"
else
    bad "no command at all is a non-zero exit" "exit 0"
fi
"$tree/abup" --help >/dev/null 2>&1
if [[ "$?" -eq 0 ]]; then
    ok "explicit --help exits clean" "yes"
else
    bad "explicit --help exits clean" "got $?"
fi

echo "== resolves the tree through a symlink, not just its own dirname =="

ln -s "$tree/abup" "$work/abup-link"
rm -f "$STUB_CALLED"
if "$work/abup-link" check stub via-symlink >/dev/null && \
   [[ "$(cat "$STUB_CALLED" 2>/dev/null)" == "via-symlink" ]]; then
    ok "a symlink elsewhere still finds the tree" "dispatched"
else
    bad "a symlink elsewhere still finds the tree" "did not dispatch"
fi

echo "== a detached copy with no symlink falls back to BRINGUP_HOME =="

cp "$tree/abup" "$work/abup-detached"
chmod 755 "$work/abup-detached"
rm -f "$STUB_CALLED"
if BRINGUP_HOME="$tree" "$work/abup-detached" check stub via-env >/dev/null && \
   [[ "$(cat "$STUB_CALLED" 2>/dev/null)" == "via-env" ]]; then
    ok "BRINGUP_HOME finds the tree for a plain copy" "dispatched"
else
    bad "BRINGUP_HOME finds the tree for a plain copy" "did not dispatch"
fi
out=$("$work/abup-detached" check stub 2>&1); rc=$?
if [[ "$rc" -ne 0 && "$out" == *"cannot find the bringup tree"* ]]; then
    ok "with neither a real location nor BRINGUP_HOME, refuses and says why" "named"
else
    bad "with neither a real location nor BRINGUP_HOME, refuses and says why" "rc=$rc: $out"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
