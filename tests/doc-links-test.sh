#!/bin/bash
#
# Checks every `docs/<page>.md#<anchor>` reference in the tree against the
# headings that actually exist.
#
# The comment convention here is that reasoning lives in docs/ and the code
# carries a one-line pointer at it. That makes ~400 anchors load-bearing and
# invisible: nothing renders them, so a heading reworded during an unrelated
# edit leaves the pointer resolving to the top of the page, and the reader gets
# a plausible-looking document that does not answer the question they clicked
# for. Nobody notices, because the link is not broken enough to look broken.
#
# The slug rule below is GitHub's, reimplemented because the anchors have to
# resolve in GitLab's blob view and in whatever renders the deployed tree at
# /cluster/bringup/docs/. Dots are dropped, underscores are kept -- the two
# that have been got wrong by hand.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$home" || exit 1

pass=0
fail=0

ok()  { printf 'ok       %-46s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL     %-46s %s\n' "$1" "$2"; fail=$((fail + 1)); }

anchors=$(mktemp) || exit 1
refs=$(mktemp) || exit 1
trap 'rm -f "$anchors" "$refs"' EXIT

## Headings, skipping fenced blocks: docs/reference/health-checks.md documents a check
## file whose own lines start with `#`, and contributor docs quote shell comments.
## Duplicate slugs in one file take the -1, -2 suffixes the renderers assign.
## No `{1,6}` here: mawk before 1.3.4-20240123 -- which is what Debian bookworm
## ships, and what CI runs -- takes an interval expression literally and matches
## no heading at all. `#+` with an explicit length test is portable.
find_headings() {
    awk '
        /^(```|~~~)/ { fence = !fence; next }
        !fence && /^#+[ \t]/ {
            match($0, /^#+/)
            if (RLENGTH > 6) next
            line = $0
            sub(/^#+[ \t]+/, "", line)
            sub(/[ \t]+#*[ \t]*$/, "", line)
            slug = tolower(line)
            gsub(/[^a-z0-9 _-]/, "", slug)
            gsub(/ /, "-", slug)
            key = FILENAME "#" slug
            if (key in seen) { n = seen[key]++; key = key "-" n }
            else seen[key] = 1
            print key
        }
    ' "$@"
}

mapfile -t pages < <(find docs -name '*.md' | sort)
if [[ "${#pages[@]}" -eq 0 ]]; then
    echo "no pages under docs/ -- has the tree moved?" >&2
    exit 1
fi
mapfile -t root_pages < <(find . -maxdepth 1 -name '*.md' -printf '%f\n' | sort)
find_headings "${pages[@]}" "${root_pages[@]}" | sort -u >"$anchors"

## Every anchored reference fails identically when this file comes out empty, so
## the one broken thing reads as several hundred broken things. Say which it is.
if [[ ! -s "$anchors" ]]; then
    echo "found no headings in ${#pages[@]} pages -- the heading match is broken," >&2
    echo "not the links. Check awk: $(awk -W version 2>&1 | head -1)" >&2
    exit 1
fi

## Every reference, with the file it was written in, because resolving a
## relative link needs to know where the reader is standing.
##
## Three things have to come out of the line before the paths do: external URLs
## (the testing plan is a .md in another repo over https), the label half of
## `[settings.md](docs/reference/settings.md)`, which is a page name that is not a link,
## and the sentence period after `See docs/reference/settings.md#burn-in.`, which the
## path characters would otherwise swallow.
mapfile -t sources < <(
    find . -path ./.git -prune -o \
        \( -name '*.sh' -o -name '*.sbatch' -o -name '*.md' -o -name '*.yml' \
           -o -name '*.py' \) \
        -print | sed 's|^\./||' | sort
)

awk '
    { line = $0
      gsub(/https?:\/\/[^ )>`]*/, " ", line)
      gsub(/\[[^]]*\]\(/, "(", line)
      while (match(line, /[a-zA-Z0-9_.\/-]+\.md(#[a-zA-Z0-9_.-]+)?/)) {
          ref = substr(line, RSTART, RLENGTH)
          line = substr(line, RSTART + RLENGTH)
          sub(/[.,;:]+$/, "", ref)
          print FILENAME ":" FNR ":" ref
      }
    }
' "${sources[@]}" >"$refs"

if [[ ! -s "$refs" ]]; then
    echo "found no .md references at all -- the grep has stopped matching" >&2
    exit 1
fi

seen_bad=""

while IFS= read -r hit; do
    src="${hit%%:*}"
    rest="${hit#*:}"
    lineno="${rest%%:*}"
    ref="${rest#*:}"

    target="${ref%%#*}"
    anchor=""
    [[ "$ref" == *#* ]] && anchor="${ref#*#}"

    ## A path is written either relative to the file it sits in, or from the
    ## repo root -- `actions/launch_job.sh` says `docs/explanation/sequencing.md`, meaning
    ## the top-level docs/, not actions/docs/. Accept both, prefer the local.
    path=""
    for cand in "$(dirname "$src")/$target" "$target"; do
        ## docs/../README.md and README.md are the same page and must not key
        ## the anchor table twice.
        cand="${cand#./}"
        while [[ "$cand" == */../* ]]; do
            cand=$(sed 's|[^/][^/]*/\.\./||' <<<"$cand")
        done
        if [[ -f "$cand" ]]; then path="$cand"; break; fi
    done

    ## An unresolvable path is only this tree's problem when it is pointing
    ## into this tree. docs/explanation/containers.md names a file in the validation-mops
    ## repo, which is prose about somewhere else, not a broken link.
    if [[ -z "$path" ]]; then
        if [[ "$target" == docs/* || "$target" == ../* || -n "$anchor" ]]; then
            bad "$src:$lineno" "no such page: $target"
        fi
        continue
    fi

    [[ -z "$anchor" ]] && continue

    if grep -qxF "$path#$anchor" "$anchors"; then
        continue
    fi

    ## Report each dead anchor once however many files point at it, but name
    ## one of them, so the fix starts somewhere.
    if [[ "$seen_bad" != *"|$path#$anchor|"* ]]; then
        seen_bad="$seen_bad|$path#$anchor|"
        near=$(grep -F "$path#" "$anchors" | sed "s|^$path#||" |
               grep -iF -- "${anchor%%-*}" | head -3 | paste -sd', ')
        if [[ -n "$near" ]]; then
            bad "$path#$anchor" "no such heading (from $src:$lineno) -- near: $near"
        else
            bad "$path#$anchor" "no such heading (from $src:$lineno)"
        fi
    fi
done <"$refs"

## Counted, not just checked: a regex that quietly stops matching would
## otherwise pass this suite by finding nothing to complain about.
total=$(wc -l <"$refs")
anchored=$(grep -c '#' "$refs")
[[ "$fail" -eq 0 ]] && ok "all references resolve" "$total links, $anchored anchored"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
