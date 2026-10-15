#!/bin/bash
#
# fanout.sh: the one place this tree reaches more than one node. The failure to
# guard against is a preference nobody chose -- a site that installed clush and
# is quietly getting pdsh, or a pinned tool that is missing and falls back
# without saying so.
# See docs/explanation/architecture.md#reaching-nodes-is-clush-or-pdsh.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
both="$work/both"; only_pdsh="$work/only-pdsh"; only_clush="$work/only-clush"; neither="$work/neither"
mkdir -p "$both" "$only_pdsh" "$only_clush" "$neither"

## Coreutils only. /usr/bin would carry a real clush or pdsh into the cases that
## say neither is installed.
sys="$work/sys"; mkdir -p "$sys"
for t in bash env cat tr sed grep awk sort head tail cut wc date dirname basename; do
    ln -s "$(command -v "$t")" "$sys/$t"
done

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }

for d in "$both" "$only_clush"; do
    cat > "$d/clush" <<'EOF'
#!/bin/bash
printf 'clush %s\n' "$*"
EOF
    chmod 755 "$d/clush"
done
for d in "$both" "$only_pdsh"; do
    cat > "$d/pdsh" <<'EOF'
#!/bin/bash
printf 'pdsh %s\n' "$*"
EOF
    chmod 755 "$d/pdsh"
done

## A PATH with nothing on it but the stubs and coreutils, so `command -v` is
## answering about the stubs rather than about this machine.
run() {
    local dir="$1" tool="$2" script="$3"
    ( export PATH="$dir:$sys" FANOUT_TOOL="$tool"
      # shellcheck source=/dev/null
      source "$home/fanout.sh"
      eval "$script" )
}

echo "== auto prefers clush =="

out=$(run "$both" auto 'fanout n[1-4] "hostname"')
case "$out" in
    clush*) ok "with both installed, auto picks clush: $out" ;;
    *)      bad "auto did not pick clush: $out" ;;
esac
[[ "$out" == *"-w n[1-4]"* ]] &&
    ok "the nodeset is passed through as written" ||
    bad "the nodeset was mangled: $out"

out=$(run "$only_pdsh" auto 'fanout n[1-4] "hostname"')
case "$out" in
    pdsh*) ok "with only pdsh installed, auto falls back to it" ;;
    *)     bad "the fallback did not happen: $out" ;;
esac
## The fall back is a fact the caller has to be able to trace, or a site that
## meant to use clush cannot tell it is not.
out=$(run "$only_pdsh" auto 'fanout_resolve; printf "%s|%s" "$FANOUT_CMD" "$FANOUT_WHY"')
[[ "$out" == "pdsh|clush is not installed here, falling back to pdsh" ]] &&
    ok "and says so in FANOUT_WHY" ||
    bad "the fallback was silent: [$out]"

out=$(run "$both" auto 'fanout_resolve; printf "%s|%s" "$FANOUT_CMD" "$FANOUT_WHY"')
[[ "$out" == "clush|" ]] &&
    ok "and there is nothing to say when clush was there all along" ||
    bad "a note was made about a choice with no surprise in it: [$out]"

echo "== -R ssh is spelled out =="

## pdsh picks its rcmd module at build time and several packaged builds default
## to rsh, so the default is not portable between sites.
out=$(run "$only_pdsh" auto 'fanout n[1-4] "hostname"')
[[ "$out" == *"-R ssh -w"* ]] &&
    ok "the pdsh form names its transport: $out" ||
    bad "pdsh was called without -R ssh: $out"

out=$(run "$only_clush" auto 'fanout n[1-4] "hostname"')
[[ "$out" == *"-R"* ]] &&
    bad "the clush form carries pdsh's flag: $out" ||
    ok "the clush form does not: $out"

echo "== a pinned tool is not quietly substituted =="

out=$(run "$both" pdsh 'fanout n[1-4] "hostname"')
case "$out" in
    pdsh*) ok "FANOUT_TOOL=pdsh uses pdsh even where clush exists" ;;
    *)     bad "a pinned pdsh was overridden: $out" ;;
esac

out=$(run "$only_clush" clush 'fanout n[1-4] "hostname"')
case "$out" in
    clush*) ok "FANOUT_TOOL=clush uses clush" ;;
    *)      bad "a pinned clush was not used: $out" ;;
esac

## The case that must not fall back: the site named a tool and it is missing.
run "$only_pdsh" clush 'fanout n[1-4] "hostname"' >/dev/null 2>&1 &&
    bad "FANOUT_TOOL=clush fell back to pdsh instead of refusing" ||
    ok "a pinned tool that is missing refuses rather than substituting"
out=$(run "$only_pdsh" clush 'fanout_resolve; printf "%s" "$FANOUT_WHY"')
[[ "$out" == *"clush is not installed"* ]] &&
    ok "and names the tool it could not find: $out" ||
    bad "the refusal did not say why: [$out]"

echo "== neither installed =="

run "$neither" auto 'fanout n[1-4] "hostname"' >/dev/null 2>&1 &&
    bad "fanout returned success with no tool to run" ||
    ok "fanout fails when there is nothing to run it with"
out=$(run "$neither" auto 'fanout_resolve; printf "%s" "$FANOUT_WHY"')
[[ "$out" == "neither clush nor pdsh is installed here" ]] &&
    ok "and says which two it looked for" ||
    bad "the reason is not usable: [$out]"

echo "== a fan-out is bounded =="

## Neither tool limits the command by default, and a node that answers the ssh
## and then blocks on a hung mount holds the whole fan-out open for ever. Both
## spell the pair the same way, which is the only reason one function covers
## them. See docs/explanation/architecture.md#a-fan-out-is-bounded.
out=$(run "$only_clush" auto 'fanout n[1-4] "hostname"')
[[ "$out" == *"-t 10 -u 60"* ]] &&
    ok "clush is given both timeouts: $out" ||
    bad "clush was called unbounded: $out"

out=$(run "$only_pdsh" auto 'fanout n[1-4] "hostname"')
[[ "$out" == *"-t 10 -u 60"* ]] &&
    ok "pdsh is given both timeouts: $out" ||
    bad "pdsh was called unbounded: $out"

out=$(run "$both" auto 'FANOUT_CONNECT_TIMEOUT=3 FANOUT_COMMAND_TIMEOUT=25 fanout n1 "hostname"')
[[ "$out" == *"-t 3 -u 25"* ]] &&
    ok "SETTINGS decides both: $out" ||
    bad "the settings were not honoured: $out"

## A site that empties or fat-fingers one of these gets the default, not an
## unbounded fan-out and not a tool that refuses to start.
out=$(run "$both" auto 'FANOUT_CONNECT_TIMEOUT= FANOUT_COMMAND_TIMEOUT=soon fanout n1 "hostname"')
[[ "$out" == *"-t 10 -u 60"* ]] &&
    ok "a non-numeric value falls back rather than passing it through: $out" ||
    bad "a bad value reached the tool: $out"

## 0 is how both tools spell "no limit", so a site can turn it off deliberately.
out=$(run "$both" auto 'FANOUT_COMMAND_TIMEOUT=0 fanout n1 "hostname"')
[[ "$out" == *"-u 0"* ]] &&
    ok "0 is passed through as the tools' own 'no limit': $out" ||
    bad "0 was overridden: $out"

echo "== the example an operator is given =="

## Both spellings, always: a site has one of the two and nobody should have to
## translate. This is the line check_trigger-debug.sh and check_dmesg.sh print.
out=$(run "$both" auto "fanout_example 'n[1-4]' 'dmesg | tail -5'")
if grep -q "clush -w n\[1-4\] 'dmesg | tail -5'" <<<"$out" &&
   grep -q "pdsh -R ssh -w n\[1-4\] 'dmesg | tail -5'" <<<"$out"; then
    ok "prints both forms of the same command"
else
    bad "the example is not both spellings: $out"
fi
[[ "$(wc -l <<<"$out")" -eq 2 ]] &&
    ok "two lines, nothing else" ||
    bad "expected two lines: $out"

echo "== grouping identical rows =="

## clubak ships with clush and dshbak with pdsh, so a site that installed either
## family has the pair -- nobody needs pdsh just for the grouped report.
for d in "$both" "$only_clush"; do
    printf '#!/bin/bash\necho clubak "$*"\n' > "$d/clubak"; chmod 755 "$d/clubak"
done
for d in "$both" "$only_pdsh"; do
    printf '#!/bin/bash\necho dshbak "$*"\n' > "$d/dshbak"; chmod 755 "$d/dshbak"
done

out=$(run "$both" auto 'bak_resolve && printf "%s" "${BAK_CMD[*]}"')
[[ "$out" == "clubak -b" ]] &&
    ok "with both installed, clubak is preferred" ||
    bad "expected 'clubak -b', got [$out]"

out=$(run "$only_pdsh" auto 'bak_resolve && printf "%s" "${BAK_CMD[*]}"')
[[ "$out" == "dshbak -c" ]] &&
    ok "with only pdsh installed, dshbak is used" ||
    bad "expected 'dshbak -c', got [$out]"

out=$(run "$both" pdsh 'bak_resolve && printf "%s" "${BAK_CMD[*]}"')
[[ "$out" == "dshbak -c" ]] &&
    ok "FANOUT_TOOL=pdsh takes dshbak, so one setting picks both tools" ||
    bad "the pinned family was not honoured for the grouping: [$out]"

## The guard that matters: a missing tool empties stdout while the pipeline
## still exits 0, which reads exactly like "no nodes match".
run "$neither" auto 'bak_resolve' &&
    bad "bak_resolve claimed a tool with neither installed" ||
    ok "with neither installed it refuses, so the caller can print ungrouped"

out=$(run "$both" auto 'printf "n1: DONE\n" | bak')
[[ "$out" == "clubak -b" ]] &&
    ok "bak pipes stdin through the resolved tool" ||
    bad "bak did not run the tool: [$out]"

echo "== every caller goes through it =="

## The rule is that nothing calls clush or pdsh directly. A new direct call is
## how the FANOUT_TOOL setting stops meaning anything.
##
## Heredoc bodies are skipped rather than pattern-matched away: every --help
## block in the tree prints both spellings for an operator to paste, and those
## are the thing this rule exists to produce, not to forbid.
find_strays() {
    local f
    for f in $(git -C "$home" ls-files '*.sh' 2>/dev/null); do
        case "$f" in tests/*|fanout.sh) continue ;; esac
        awk -v file="$f" '
            ## <<WORD or <<-WORD or <<"WORD": body runs until the delimiter.
            heredoc != "" {
                line = $0; gsub(/^[ \t]+/, "", line)
                if (line == heredoc) heredoc = ""
                next
            }
            match($0, /<<-?[ ]*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*/) {
                d = substr($0, RSTART, RLENGTH)
                gsub(/^<<-?[ ]*['"'"'"]?/, "", d)
                heredoc = d
                next
            }
            ## A comment, or a quoted string: not a command.
            /^[ \t]*#/ { next }
            ## clush or pdsh as the first word of a command.
            /(^|[;&|(]|[[:space:]]then|[[:space:]]do|\$\()[[:space:]]*(clush|pdsh)[[:space:]]/ {
                printf "%s:%d:%s\n", file, NR, $0
            }
        ' "$home/$f"
    done
}
strays=$(find_strays)
if [[ -z "$strays" ]]; then
    ok "no script calls clush or pdsh outside fanout.sh"
else
    bad "a direct call bypasses FANOUT_TOOL:"
    printf '       %s\n' "$strays"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
