#!/usr/bin/env bash
# SPDX-License-Identifier: CC0-1.0
#
# Unprivileged (no signing secrets). Checks one build of an allowlisted PUBLIC source repository
# against that repository's own records on GitHub, downloads the artifact of that exact run and
# verifies it (verify-import.sh). Reads public data only (GH_TOKEN of the publisher repository).
#
#   validate-source.sh --app-id ID --source-repo OWNER/NAME --tag TAG --run-id N --out DIR
#
# DIR gets SOURCE.json, repo.tar and RUN.json (the run's identity, recorded when publishing).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

app_id="" source_repo="" tag="" run_id="" out=""
while (($#)); do
    case "$1" in
        --app-id) app_id="$2"; shift 2 ;;
        --source-repo) source_repo="$2"; shift 2 ;;
        --tag) tag="$2"; shift 2 ;;
        --run-id) run_id="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
validate_app_id "$app_id" || die "invalid app id"
[[ "$source_repo" == "$(app_field "$app_id" source_repo)" ]] || die "$source_repo is not the allowlisted source of $app_id"
tag_regex="$(app_field "$app_id" tag_regex)"
[[ "${#tag}" -le 100 && "$tag" =~ $tag_regex ]] || die "tag does not match the allowlist pattern"
[[ "$run_id" =~ ^[0-9]{1,20}$ ]] || die "invalid run id"
[[ -n "$out" && ! -e "$out" ]] || die "--out must name a new directory"
workflow_path="$(app_field "$app_id" workflow_path)"
dispatch_branch="$(app_field "$app_id" dispatch_branch)"
prefix="$(app_field "$app_id" packaging_prefix)"
arch="$(app_field "$app_id" arches | head -n1)"

# Only public source repositories: their builds and records can be checked by anyone.
api "repos/$source_repo" | jq -e --arg r "$source_repo" '.full_name == $r and .private == false and .visibility == "public"' >/dev/null \
    || die "$source_repo is not a public repository"

# The tag must exist and name a commit (annotated tags are dereferenced).
ref="$(api "repos/$source_repo/git/ref/tags/$tag")"
[[ "$(jq -r .ref <<<"$ref")" == "refs/tags/$tag" ]] || die "no tag $tag"
type="$(jq -r .object.type <<<"$ref")"
commit="$(jq -r .object.sha <<<"$ref")"
if [[ "$type" == tag ]]; then
    commit="$(api "repos/$source_repo/git/tags/$commit" | jq -r 'select(.object.type == "commit") | .object.sha')"
fi
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "$tag does not name a commit"

# The run: the allowlisted workflow of that repository, finished successfully, for that tag: a
# push of the tag at that commit, or a dispatch on the allowlisted branch naming the tag (master
# packaging building an older tag). Its head commit is the packaging revision.
run="$(api "repos/$source_repo/actions/runs/$run_id")"
jq -e --arg repo "$source_repo" --arg path "$workflow_path" --argjson id "$run_id" \
    '.id == $id and .repository.full_name == $repo and .head_repository.full_name == $repo and .path == $path and .status == "completed" and .conclusion == "success"' \
    <<<"$run" >/dev/null || die "run $run_id is not a successful $workflow_path run of $source_repo"
event="$(jq -r .event <<<"$run")"
packaging_commit="$(jq -r .head_sha <<<"$run")"
case "$event" in
    push) jq -e --arg tag "$tag" --arg sha "$commit" '.head_branch == $tag and .head_sha == $sha' <<<"$run" >/dev/null \
        || die "run $run_id did not build $tag at $commit" ;;
    workflow_dispatch) jq -e --arg b "$dispatch_branch" --arg t "Flatpak $tag" '.head_branch == $b and .display_title == $t' <<<"$run" >/dev/null \
        || die "dispatched run $run_id is not a $dispatch_branch build of $tag" ;;
    *) die "run $run_id was started by $event" ;;
esac
[[ "$packaging_commit" =~ ^[0-9a-f]{40}$ ]] || die "run has no head commit"

# Ancestry, checked here and never taken from the source workflow (a tag can carry any workflow):
# the allowlisted branch is resolved ONCE to an immutable commit, and the tag's commit and the
# packaging commit must each equal it or be its ancestor (GitHub compare of exact SHAs). A missing
# branch or comparison, a diverged or newer commit refuses the build. The resolved head is recorded
# in RUN.json and signed into the published commit. The branch should be protected (no force
# push or deletion; README), so the head stays a descendant of every published build.
branch_rec="$(api "repos/$source_repo/branches/$dispatch_branch")" || die "cannot resolve branch $dispatch_branch of $source_repo"
branch_sha="$(jq -r --arg b "$dispatch_branch" 'select(.name == $b) | .commit.sha' <<<"$branch_rec")"
[[ "$branch_sha" =~ ^[0-9a-f]{40}$ ]] || die "cannot resolve branch $dispatch_branch of $source_repo"
branch_protected="$(jq -r '.protected == true' <<<"$branch_rec")"
on_branch() { # COMMIT: equal to or an ancestor of the resolved branch head
    local cmp
    cmp="$(api "repos/$source_repo/compare/$1...$branch_sha?per_page=1")" || die "cannot compare $1 with $dispatch_branch ($branch_sha)"
    jq -e --arg c "$1" '(.status == "identical" or .status == "ahead") and .behind_by == 0
        and .base_commit.sha == $c and .merge_base_commit.sha == $c' <<<"$cmp" >/dev/null
}
on_branch "$commit" || die "$tag ($commit) is not on $dispatch_branch ($branch_sha)"
on_branch "$packaging_commit" || die "packaging commit $packaging_commit is not on $dispatch_branch ($branch_sha)"

# Exactly one unexpired artifact of the expected name, with a digest checked on download.
name="flatpak-$app_id-$arch"
artifacts="$(api "repos/$source_repo/actions/runs/$run_id/artifacts?name=$name&per_page=100" | jq '[.artifacts[] | select(.name == "'"$name"'" and .expired == false)]')"
[[ "$(jq length <<<"$artifacts")" == 1 ]] || die "run $run_id has no single unexpired artifact $name (expired after the source repository's retention?)"
artifact_id="$(jq -r '.[0].id' <<<"$artifacts")"
digest="$(jq -r '.[0].digest // ""' <<<"$artifacts")"
size="$(jq -r '.[0].size_in_bytes' <<<"$artifacts")"
[[ "$artifact_id" =~ ^[0-9]+$ && "$digest" =~ ^sha256:[0-9a-f]{64}$ && "$size" =~ ^[0-9]+$ ]] || die "artifact record incomplete"
max="$(app_field "$app_id" max_repo_tar_bytes)"
((size <= max + 1048576)) || die "artifact is $size bytes"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
api "repos/$source_repo/actions/artifacts/$artifact_id/zip" >"$work/a.zip"
[[ "sha256:$(sha256sum "$work/a.zip" | cut -d' ' -f1)" == "$digest" ]] || die "artifact digest mismatch"
python3 -I "$PUBLISHER_ROOT/scripts/safe-extract.py" "$work/a.zip" "$work/x" --allow-file SOURCE.json --allow-file repo.tar --max-total "$((max + 1048576))"
"$PUBLISHER_ROOT/scripts/verify-import.sh" --dir "$work/x" --app-id "$app_id" --tag "$tag" --commit "$commit" --arch "$arch" --out "$work/repo"

# Build identity against the source repository: the packaging revision is the run's commit, and
# every packaging file the build declares has that digest at that revision (manifest required).
jq -e --arg c "$packaging_commit" '.packaging_commit == $c' "$work/x/SOURCE.json" >/dev/null \
    || die "SOURCE.json packaging commit is not the run's commit $packaging_commit"
jq -e --arg m "$prefix$app_id.json" '.packaging_files | has($m)' "$work/x/SOURCE.json" >/dev/null \
    || die "SOURCE.json does not record the manifest $prefix$app_id.json"
while IFS=$'\t' read -r path want; do
    got="$(api "repos/$source_repo/contents/$path?ref=$packaging_commit" | jq -r 'select(.type == "file" and .encoding == "base64") | .content' | base64 -d | sha256sum | cut -d' ' -f1)"
    [[ "$got" == "$want" ]] || die "$path differs from $source_repo at $packaging_commit"
done < <(jq -r '.packaging_files | to_entries[] | "\(.key)\t\(.value)"' "$work/x/SOURCE.json")

mkdir -p "$out"
cp "$work/x/SOURCE.json" "$work/x/repo.tar" "$out/"
jq -n --arg repo "$source_repo" --argjson id "$run_id" --arg tag "$tag" --arg commit "$commit" --argjson run "$run" \
    --arg branch "$dispatch_branch" --arg bsha "$branch_sha" --argjson prot "$branch_protected" \
    '{source_repo: $repo, run_id: $id, run_attempt: $run.run_attempt, event: $run.event, created_at: $run.created_at,
      tag: $tag, commit: $commit, packaging_commit: $run.head_sha,
      dispatch_branch: $branch, dispatch_branch_sha: $bsha, dispatch_branch_protected: $prot}' >"$out/RUN.json"
note "validated $source_repo run $run_id: $app_id $tag ($commit), packaging $packaging_commit, both on $dispatch_branch $branch_sha"
