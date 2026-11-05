#!/usr/bin/env bash
# SPDX-License-Identifier: CC0-1.0
#
# Finds and validates what this run publishes (no secrets): discovered builds oldest first, at most
# max_builds_per_run, each newer than the app's tag before it. A build that fails validation is
# skipped with a warning (the next newer one of that app may still go), never fatal for others.
#
#   plan.sh --published FILE --out DIR [--today YYYY-MM-DD]
#
# DIR/NNN/ holds each validated build; DIR/plan.json lists them in publication order.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

published="" out="" today=()
while (($#)); do
    case "$1" in
        --published) published="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        --today) today=(--today "$2"); shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[[ -f "$published" && -n "$out" && ! -e "$out" ]] || die "usage: plan.sh --published FILE --out NEWDIR"
max="$(config max_builds_per_run)"
mkdir -p "$out"
candidates="$(python3 -I "$PUBLISHER_ROOT/scripts/discover.py" --apps "$APPS" --config "$CONFIG" --published "$published" "${today[@]}")"
declare -A current
while IFS= read -r app; do
    current[$app]="$(jq -r --arg a "$app" '.[$a] // ""' "$published")"
done < <(jq -r '.apps | keys[]' "$APPS")
n=0
plan='[]'
while IFS=$'\t' read -r created run_id app_id repo tag; do
    [[ -n "$run_id" ]] || continue
    ((n < max)) || { note "more builds waiting; the next run continues with them"; break; }
    if [[ -n "${current[$app_id]}" ]] && ! tag_is_newer "${current[$app_id]}" "$tag"; then
        continue
    fi
    d="$(printf '%03d' "$n")"
    if "$PUBLISHER_ROOT/scripts/validate-source.sh" --app-id "$app_id" --source-repo "$repo" --tag "$tag" --run-id "$run_id" --out "$out/$d"; then
        current[$app_id]="$tag"
        plan="$(jq --arg d "$d" --arg a "$app_id" --arg t "$tag" --argjson r "$run_id" '. + [{dir: $d, app_id: $a, tag: $t, run_id: $r}]' <<<"$plan")"
        n=$((n + 1))
    else
        rm -rf "${out:?}/$d"
        echo "::warning::skipped $repo run $run_id ($tag): validation failed"
    fi
done <<<"$candidates"
jq . <<<"$plan" >"$out/plan.json"
note "$n build(s) to publish"
