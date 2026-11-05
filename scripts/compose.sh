#!/usr/bin/env bash
# SPDX-License-Identifier: CC0-1.0
#
# Adds one verified app build to the published repository, signs, and lays out the Pages site.
#
#   compose.sh --base REPO --import REPO --source-json FILE --run-json FILE --site DIR
#
# --base is the fetched published repository (fetch-published.sh; empty for bootstrap) and becomes
# site/repo. Every ref already published is kept: refs of other apps are never touched, and the
# run fails if any would be lost. New commits get the published commit as parent (continuous
# history), are signed with SIGNING_FPR in GNUPGHOME (gpg-setup.sh), and must come from a newer
# release tag than the published one (no downgrades; the same tag and commit again is a no-op).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

base="" import="" source_json="" run_json="" site=""
while (($#)); do
    case "$1" in
        --base) base="$2"; shift 2 ;;
        --import) import="$2"; shift 2 ;;
        --source-json) source_json="$2"; shift 2 ;;
        --site) site="$2"; shift 2 ;;
        --run-json) run_json="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[[ -d "$base" && -d "$import" && -f "$source_json" && -f "$run_json" && -n "$site" ]] || die "missing arguments"
[[ ! -e "$site" ]] || die "$site exists"
[[ -n "${SIGNING_FPR:-}" && -n "${GNUPGHOME:-}" ]] || die "no signing key set up (gpg-setup.sh); refusing to publish unsigned"
check_pinned_key
[[ "$SIGNING_FPR" == "$(pinned_fingerprint)" ]] || die "signing key is not the pinned key"

json() { python3 -I -c 'import json,sys; v=json.load(open(sys.argv[1])); [v:=v[k] for k in sys.argv[2:]]; print(v)' "$source_json" "$@"; }
app_id="$(json app_id)"
tag="$(json source_tag)"
commit="$(json source_commit)"
validate_app_id "$app_id" || die "invalid app id"
expected_repo="$(app_field "$app_id" source_repo)"
jq -e --arg r "$expected_repo" --arg t "$tag" --arg c "$commit" '.source_repo == $r and .tag == $t and .commit == $c' "$run_json" >/dev/null \
    || die "RUN.json does not describe this build of $expected_repo"
# Signed into each commit: source, run and build identity (validated by validate-source.sh).
body="$(jq -r --slurpfile s "$source_json" '"source-repo=\(.source_repo)\nsource-tag=\(.tag)\nsource-commit=\(.commit)\nsource-run=\(.run_id)/\(.run_attempt)\npackaging-commit=\(.packaging_commit)\n" + (if .dispatch_branch_sha then "source-branch=\(.dispatch_branch)@\(.dispatch_branch_sha)\n" else "" end) + "runtime=\($s[0].runtime.ref)@\($s[0].runtime.commit)\nsdk=\($s[0].sdk.ref)@\($s[0].sdk.commit)\nmanifest-sha256=\($s[0].rendered_manifest_sha256)\n" + ($s[0].packaging_files | to_entries | map("packaging-file=\(.key)@\(.value)") | join("\n"))' "$run_json")"
title="$(app_field "$app_id" title)"
depth="$(config prune_depth)"
limit="$(config site_limit_bytes)"

mkdir -p "$site"
cp -a "$base" "$site/repo"
repo="$site/repo"
mapfile -t before < <(ostree --repo="$repo" refs | sort)

# The release a published commit came from, as recorded in its signed commit message.
published_field() {
    ostree --repo="$repo" show "$1" | sed -n "s/^ *source-$2=\([^ ]*\)\$/\1/p" | head -n1
}

mapfile -t refs < <(python3 -I -c 'import json,sys; print("\n".join(sorted(json.load(open(sys.argv[1]))["refs"])))' "$source_json")
changed=0
for ref in "${refs[@]}"; do
    if ostree --repo="$repo" rev-parse "$ref" >/dev/null 2>&1; then
        old_tag="$(published_field "$ref" tag)"
        old_commit="$(published_field "$ref" commit)"
        [[ -n "$old_tag" ]] || die "$ref: the published commit records no source tag; refusing to replace it"
        if [[ "$old_tag" == "$tag" ]]; then
            [[ "$old_commit" == "$commit" ]] || die "$ref: $tag was published from $old_commit, not $commit"
            note "$ref: $tag is already published; unchanged"
            continue
        fi
        tag_is_newer "$old_tag" "$tag" || die "$ref: $tag is not newer than the published $old_tag (no downgrades)"
    fi
    # Same content as the build, the published head as parent, signed, source recorded.
    flatpak build-commit-from --no-update-summary \
        --src-repo="$import" --src-ref="$ref" \
        --gpg-sign="$SIGNING_FPR" --gpg-homedir="$GNUPGHOME" \
        --subject="$app_id $tag" \
        --body="$body" \
        "$repo" "$ref" >&2
    changed=1
done

# Summary, appstream, pruning and deltas over the whole repository (all apps), signed.
flatpak build-update-repo \
    --gpg-sign="$SIGNING_FPR" --gpg-homedir="$GNUPGHOME" \
    --title="$(config title)" --default-branch=stable \
    --prune --prune-depth="$depth" \
    --generate-static-deltas --static-delta-ignore-ref='*.Debug' --static-delta-ignore-ref='*.Sources' \
    "$repo" >&2

# Nothing published before may be missing now.
mapfile -t after < <(ostree --repo="$repo" refs | sort)
missing="$(comm -23 <(printf '%s\n' "${before[@]}" | sed '/^$/d') <(printf '%s\n' "${after[@]}"))"
[[ -z "$missing" ]] || die "refs would be lost: $missing"

# Verify as a client would, trusting only the pinned key: signed summary and every commit.
check="$(mktemp -d)"
trap 'rm -rf "$check"' EXIT
ostree init --mode=bare-user --repo="$check/c"
ostree --repo="$check/c" remote add --gpg-import="$PINNED_KEY" \
    --set=gpg-verify=true --set=gpg-verify-summary=true pub "file://$(cd "$repo" && pwd -P)"
mapfile -t listed < <(ostree --repo="$check/c" remote refs pub | sed 's/^pub://' | sort)
((${#listed[@]})) || die "the signed summary lists no refs"
for ref in "${listed[@]}"; do
    ostree --repo="$check/c" pull --commit-metadata-only pub "$ref" >/dev/null || die "$ref does not verify with the pinned key"
done

python3 -I "$PUBLISHER_ROOT/scripts/site.py" --site "$site" --config "$CONFIG" --apps "$APPS" --key "$PINNED_KEY"

size="$(du -sb "$site" | cut -f1)"
((size < limit)) || die "site is $size bytes, over the limit of $limit (GitHub Pages allows 1 GB); lower prune_depth or remove apps"
note "site $site: $size bytes, ${#after[@]} refs, changed=$changed"
