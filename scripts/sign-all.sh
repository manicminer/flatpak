#!/usr/bin/env bash
# SPDX-License-Identifier: CC0-1.0
#
# Signing step: adds the validated builds (plan.sh output) one after another, in plan order, to the
# fetched base and lays out the site. A build no newer than what the base (signed, ledger-matched)
# already has is skipped. Needs gpg_setup (gpg-setup.sh) done by the caller.
#
#   sign-all.sh --validated DIR --base REPO --site DIR --state-out DIR
#
# --state-out gets refs.json ({ref: {commit, tag}}) and builds.json (RUN.json of each build
# added) for the ledger. No site is made when nothing changed.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

validated="" base="" site="" state_out=""
while (($#)); do
    case "$1" in
        --validated) validated="$2"; shift 2 ;;
        --base) base="$2"; shift 2 ;;
        --site) site="$2"; shift 2 ;;
        --state-out) state_out="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[[ -f "$validated/plan.json" && -d "$base" && -n "$site" && ! -e "$site" && -n "$state_out" ]] || die "missing arguments"
w="$(mktemp -d)"
trap 'rm -rf "$w"' EXIT
cur="$base" builds='[]' i=0
while IFS=$'\t' read -r d app_id tag; do
    b="$validated/$d"
    commit="$(jq -r .commit "$b/RUN.json")"
    arch="$(app_field "$app_id" arches | head -n1)"
    branch="$(app_field "$app_id" branch)"
    "$PUBLISHER_ROOT/scripts/verify-import.sh" --dir "$b" --app-id "$app_id" --tag "$tag" --commit "$commit" --arch "$arch" --out "$w/import-$d"
    ref="app/$app_id/$arch/$branch"
    if ostree --repo="$cur" rev-parse "$ref" >/dev/null 2>&1; then
        old="$(ostree --repo="$cur" show "$ref" | sed -n 's/^ *source-tag=\([^ ]*\)$/\1/p' | head -n1)"
        if [[ -n "$old" ]] && ! tag_is_newer "$old" "$tag"; then
            note "$app_id $tag: the base already has $old; skipped"
            continue
        fi
    fi
    "$PUBLISHER_ROOT/scripts/compose.sh" --base "$cur" --import "$w/import-$d" --source-json "$b/SOURCE.json" --run-json "$b/RUN.json" --site "$w/site-$i"
    cur="$w/site-$i/repo" last="$w/site-$i"
    builds="$(jq --slurpfile r "$b/RUN.json" '. + $r' <<<"$builds")"
    i=$((i + 1))
done < <(jq -r '.[] | [.dir, .app_id, .tag] | @tsv' "$validated/plan.json")
mkdir -p "$state_out"
if ((i == 0)); then
    note "nothing new to publish"
    exit 0
fi
mv "$last" "$site"
jq . <<<"$builds" >"$state_out/builds.json"
refs='{}'
while IFS= read -r ref; do
    c="$(ostree --repo="$site/repo" rev-parse "$ref")"
    t="$(ostree --repo="$site/repo" show "$ref" | sed -n 's/^ *source-tag=\([^ ]*\)$/\1/p' | head -n1)"
    refs="$(jq --arg r "$ref" --arg c "$c" --arg t "$t" '. + {($r): {commit: $c, tag: $t}}' <<<"$refs")"
done < <(ostree --repo="$site/repo" refs | grep -E '^(app|runtime)/' | sort)
jq . <<<"$refs" >"$state_out/refs.json"
note "site ready: $i build(s) added"
