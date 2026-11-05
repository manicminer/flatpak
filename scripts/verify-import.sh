#!/usr/bin/env bash
# SPDX-License-Identifier: CC0-1.0
#
# Checks an extracted build (SOURCE.json + repo.tar, as made by an app's packaging) against what
# the publisher was asked to publish and the allowlist, and copies its declared refs, verified,
# into a fresh repository.
#
#   verify-import.sh --dir DIR --app-id ID --tag TAG --commit SHA --arch ARCH --out REPO_DIR
#
# Prints nothing secret; uses no secrets. REPO_DIR must not exist.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dir="" app_id="" tag="" commit="" arch="" out=""
while (($#)); do
    case "$1" in
        --dir) dir="$2"; shift 2 ;;
        --app-id) app_id="$2"; shift 2 ;;
        --tag) tag="$2"; shift 2 ;;
        --commit) commit="$2"; shift 2 ;;
        --arch) arch="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
validate_app_id "$app_id" || die "invalid app id"
tag_regex="$(app_field "$app_id" tag_regex)"
[[ "$tag" =~ $tag_regex ]] || die "tag does not match the allowlist pattern of $app_id"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "commit must be a full SHA-1"
app_field "$app_id" arches | grep -qxF -- "$arch" || die "arch $arch not allowed for $app_id"
branch="$(app_field "$app_id" branch)"
max_tar="$(app_field "$app_id" max_repo_tar_bytes)"
prefix="$(app_field "$app_id" packaging_prefix)"

[[ -f "$dir/SOURCE.json" && ! -L "$dir/SOURCE.json" ]] || die "SOURCE.json missing"
[[ -f "$dir/repo.tar" && ! -L "$dir/repo.tar" ]] || die "repo.tar missing"
size="$(stat -c %s "$dir/repo.tar")"
((size <= max_tar)) || die "repo.tar is $size bytes, more than $max_tar"

# Expected refs: the app and its allowed extensions, for this arch and branch only.
expected=("app/$app_id/$arch/$branch")
while IFS= read -r ext; do
    [[ -n "$ext" ]] && expected+=("runtime/$app_id.$ext/$arch/$branch")
done < <(app_field "$app_id" extra_refs)

python3 -I - "$dir/SOURCE.json" "$dir/repo.tar" "$app_id" "$tag" "$commit" "$arch" "$branch" "$prefix" "${expected[@]}" <<'PY'
import hashlib, json, re, sys
src, tar, app_id, tag, commit, arch, branch, prefix, *expected = sys.argv[1:]
H64, H40 = re.compile(r"[0-9a-f]{64}"), re.compile(r"[0-9a-f]{40}")
with open(src, encoding="utf-8") as f:
    j = json.loads(f.read(65536))
want = {"format": 2, "app_id": app_id, "source_tag": tag, "source_commit": commit, "arch": arch, "branch": branch, "repo_tar": "repo.tar"}
for k, v in want.items():
    if j.get(k) != v:
        sys.exit(f"verify-import: SOURCE.json {k} is {j.get(k)!r}, expected {v!r}")
refs = j.get("refs")
if not isinstance(refs, dict) or "app/%s/%s/%s" % (app_id, arch, branch) not in refs:
    sys.exit("verify-import: SOURCE.json lacks the app ref")
for ref, rev in refs.items():
    if ref not in expected:
        sys.exit(f"verify-import: ref {ref!r} is not allowed")
    if not H64.fullmatch(str(rev)):
        sys.exit(f"verify-import: bad commit for {ref}")
# Build identity: packaging revision and the packaging files used (with digests), the rendered
# manifest, and the exact runtime and SDK commits.
if not H40.fullmatch(str(j.get("packaging_commit"))):
    sys.exit("verify-import: SOURCE.json lacks the packaging commit")
files = j.get("packaging_files")
if not isinstance(files, dict) or not files:
    sys.exit("verify-import: SOURCE.json lacks packaging_files")
for path, digest in files.items():
    if not (path.startswith(prefix) and re.fullmatch(r"[A-Za-z0-9._/+-]{1,200}", path)
            and ".." not in path.split("/") and H64.fullmatch(str(digest))):
        sys.exit(f"verify-import: bad packaging file entry {path!r}")
if not H64.fullmatch(str(j.get("rendered_manifest_sha256"))):
    sys.exit("verify-import: SOURCE.json lacks the rendered manifest digest")
for k in ("runtime", "sdk"):
    v = j.get(k)
    if not (isinstance(v, dict) and re.fullmatch(r"[A-Za-z0-9._-]+/%s/[A-Za-z0-9._-]+" % re.escape(arch), str(v.get("ref")))
            and H64.fullmatch(str(v.get("commit")))):
        sys.exit(f"verify-import: SOURCE.json lacks the {k} ref and commit")
h = hashlib.sha256()
with open(tar, "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        h.update(chunk)
if h.hexdigest() != j.get("repo_tar_sha256"):
    sys.exit("verify-import: repo.tar digest does not match SOURCE.json")
PY

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
python3 -I "$PUBLISHER_ROOT/scripts/safe-extract.py" "$dir/repo.tar" "$stage/x" --allow-prefix repo/ --max-total "$((max_tar * 2))"
[[ -f "$stage/x/repo/config" ]] || die "repo.tar holds no OSTree repository"
grep -qx 'mode=archive-z2' "$stage/x/repo/config" || die "repository is not an archive-z2 repository"
# The build's own configuration (remotes, core options) is never used: replaced by a minimal one,
# and only the declared refs' objects are copied, verified, into a fresh repository.
printf '[core]\nrepo_version=1\nmode=archive-z2\n' >"$stage/x/repo/config"
rm -rf "$stage/x/repo/remotes.d" "$stage/x/repo/refs/remotes" "$stage/x/repo/refs/mirrors"
mkdir -p "$stage/x/repo/refs/remotes" "$stage/x/repo/refs/mirrors"

# The repository's refs must be exactly those SOURCE.json names, at those commits.
mapfile -t actual < <(ostree --repo="$stage/x/repo" refs | sort)
mapfile -t declared < <(python3 -I -c 'import json,sys; print("\n".join(sorted(json.load(open(sys.argv[1]))["refs"])))' "$dir/SOURCE.json")
[[ "${actual[*]}" == "${declared[*]}" ]] || die "repository refs (${actual[*]}) differ from SOURCE.json (${declared[*]})"
for ref in "${actual[@]}"; do
    rev="$(ostree --repo="$stage/x/repo" rev-parse "$ref")"
    want="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["refs"][sys.argv[2]])' "$dir/SOURCE.json" "$ref")"
    [[ "$rev" == "$want" ]] || die "$ref is at $rev, SOURCE.json says $want"
done
repo="$stage/clean"
ostree init --mode=archive-z2 --repo="$repo"
ostree --repo="$repo" pull-local --untrusted "$stage/x/repo" "${actual[@]}" >/dev/null 2>&1 || die "repository objects do not verify"
rm -rf "$stage/x"
ostree --repo="$repo" fsck --quiet >/dev/null || die "repository fails fsck"

# The app's metadata must name the app itself.
meta="$(ostree --repo="$repo" cat "app/$app_id/$arch/$branch" /metadata)"
grep -qx "name=$app_id" <<<"$meta" || die "app metadata names another application"
# Permissions: exactly those approved for this app in apps.json. Any other grant (filesystem,
# socket, device, feature, bus name, policy section) needs central review first.
problem="$(python3 -I -c '
import configparser, json, sys
approved = json.load(open(sys.argv[1]))["apps"][sys.argv[2]]["permissions"]
c = configparser.ConfigParser(interpolation=None, strict=True, delimiters=("=",))
c.optionxform = str
c.read_string(sys.stdin.read())
for section in c.sections():
    if section in ("Application", "Environment", "Build") or section.startswith("Extension "):
        continue
    if section not in ("Context", "Session Bus Policy", "System Bus Policy"):
        print(f"metadata section [{section}] is not allowed"); sys.exit()
    ok = approved.get(section, {})
    for key, value in c[section].items():
        if section == "Context":
            extra = [v for v in value.split(";") if v and v not in ok.get(key, [])]
            if extra:
                print(f"unapproved permission {key}={chr(59).join(extra)}"); sys.exit()
        elif ok.get(key) != value:
            print(f"unapproved {section} entry {key}={value}"); sys.exit()
' "$APPS" "$app_id" <<<"$meta" 2>&1)"
[[ -z "$problem" ]] || die "$problem"
for ref in "${actual[@]}"; do
    [[ "$ref" == app/* ]] && continue
    ! ostree --repo="$repo" cat "$ref" /metadata | grep -qE '^\[(Context|Session Bus Policy|System Bus Policy)\]' \
        || die "$ref requests permissions"
done

# The runtime and SDK SOURCE.json names are those flatpak-builder recorded in the app.
built="$(ostree --repo="$repo" cat "app/$app_id/$arch/$branch" /files/manifest.json 2>/dev/null)" \
    || die "app has no /files/manifest.json (flatpak-builder build record)"
python3 -I -c '
import json, sys
m, s = json.loads(sys.argv[1]), json.load(open(sys.argv[2]))
meta = dict(l.split("=", 1) for l in sys.argv[3].splitlines() if "=" in l)
for k in ("runtime", "sdk"):
    if s[k]["commit"] != m.get(k + "-commit"):
        sys.exit(f"verify-import: {k} commit in SOURCE.json differs from the build record")
    if s[k]["ref"] != meta.get(k):
        sys.exit(f"verify-import: {k} ref in SOURCE.json differs from the app metadata")
' "$built" "$dir/SOURCE.json" "$meta"

[[ ! -e "$out" ]] || die "$out exists"
mv "$repo" "$out"
note "verified $app_id $tag ($commit) for $arch: ${actual[*]}"
