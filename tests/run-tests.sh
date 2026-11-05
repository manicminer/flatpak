#!/usr/bin/env bash
# SPDX-License-Identifier: CC0-1.0
#
# Offline tests of the publisher with an EPHEMERAL RSA signing key made here (never a real one),
# synthetic apps and file:// repositories. Needs flatpak, ostree, gpg, python3. No network.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/tests/isolate.sh"
source "$root/scripts/lib.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/publisher-test.XXXXXX")"
trap 'for h in "$T"/*/gpg-agent.conf; do gpgconf --homedir "${h%/*}" --kill all >/dev/null 2>&1 || true; done; rm -rf "$T"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
expect_ok() { local name="$1"; shift; if "$@" >"$T/last.log" 2>&1; then ok "$name"; else bad "$name"; sed 's/^/     /' "$T/last.log" | tail -20; fi; }
expect_fail() { local name="$1" pattern="$2"; shift 2; if "$@" >"$T/last.log" 2>&1; then bad "$name (succeeded)"; elif grep -q -- "$pattern" "$T/last.log"; then ok "$name"; else bad "$name (wrong error)"; sed 's/^/     /' "$T/last.log" | tail -10; fi; }

# --- Ephemeral keys --------------------------------------------------------------------------
PASS="test-passphrase-$RANDOM-$RANDOM"
# Every secret-key operation is --batch --pinentry-mode loopback with an explicit passphrase, and
# every agent has pinentry-program /usr/bin/false: a missed case fails, it never prompts.
mkkey() { # home uid passphrase ("" = unprotected)
    gpg_harden_home "$1"
    if [[ -n "$3" ]]; then
        gpg --homedir "$1" --batch --quiet --passphrase "$3" --pinentry-mode loopback \
            --quick-generate-key "$2" rsa2048 sign 1d 2>/dev/null
    else
        printf 'Key-Type: RSA\nKey-Length: 2048\nKey-Usage: sign\nName-Real: %s\nExpire-Date: 1d\n%%no-protection\n%%commit\n' "$2" \
            | gpg --homedir "$1" --batch --quiet --pinentry-mode loopback --gen-key 2>/dev/null
    fi
    gpg --homedir "$1" --batch --with-colons --list-keys | awk -F: '$1=="fpr"{print $10; exit}'
}
FPR="$(mkkey "$T/keyhome" "Publisher Test <test@example.org>" "$PASS")"
# Unprotected, so signing forged summaries with it needs no passphrase at all.
ATTACKER_FPR="$(mkkey "$T/attacker" "Attacker <attacker@example.org>" "")"
mkdir -p "$T/keys"
gpg --homedir "$T/keyhome" --batch --export "$FPR" >"$T/keys/pub.gpg"
echo "$FPR" >"$T/keys/FINGERPRINT"
ARMORED="$(gpg --homedir "$T/keyhome" --batch --pinentry-mode loopback --passphrase "$PASS" --armor --export-secret-keys "$FPR")"
ATTACKER_ARMORED="$(gpg --homedir "$T/attacker" --batch --pinentry-mode loopback --passphrase "" --armor --export-secret-keys "$ATTACKER_FPR")"
gpgconf --homedir "$T/keyhome" --kill all

# --- No prompt can ever appear --------------------------------------------------------------------
[[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" && "$GNUPGHOME" == "$HOME/gnupg" && "$DBUS_SESSION_BUS_ADDRESS" != *"/run/user/"* ]] \
    && ok "isolated: no display, private HOME/GNUPGHOME/D-Bus" || bad "test environment not isolated"
# Without a cached passphrase every route to the protected key must fail fast instead of prompting.
fails_closed() { local rc=0; timeout 60 "$@" </dev/null >"$T/last.log" 2>&1 || rc=$?; ((rc != 0 && rc != 124)); }
fails_closed gpg --homedir "$T/keyhome" --local-user "$FPR" --detach-sign -o "$T/x.sig" "$T/keys/FINGERPRINT" \
    && ok "fail closed: gpg signing without passphrase (default pinentry mode)" || bad "gpg signing without passphrase did not fail closed"
ostree init --mode=archive-z2 --repo="$T/nopass"
fails_closed flatpak build-update-repo --gpg-sign="$FPR" --gpg-homedir="$T/keyhome" "$T/nopass" \
    && ok "fail closed: OSTree/Flatpak signing without passphrase" || bad "OSTree signing without passphrase did not fail closed"
gpgconf --homedir "$T/keyhome" --kill all

export PUBLISHER_PINNED_KEY="$T/keys/pub.gpg" PUBLISHER_PINNED_FINGERPRINT="$T/keys/FINGERPRINT"
export PUBLISHER_APPS="$T/apps.json" PUBLISHER_CONFIG="$T/config.json"
cat >"$PUBLISHER_APPS" <<'EOF'
{"apps": {
 "org.example.Alpha": {"title": "Alpha", "source_repo": "example/alpha", "workflow_path": ".github/workflows/flatpak.yml",
   "dispatch_branch": "master", "tag_regex": "^v[0-9]+\\.[0-9]+$", "branch": "stable", "arches": ["x86_64"], "extra_refs": ["Locale"], "max_repo_tar_bytes": 10000000,
   "packaging_prefix": "packaging/flatpak/",
   "permissions": {"Context": {"shared": ["network", "ipc"], "filesystems": ["xdg-config/kdeglobals:ro"]}, "Session Bus Policy": {"org.example.Ok": "talk"}}},
 "org.example.Beta": {"title": "Beta", "source_repo": "example/beta", "workflow_path": ".github/workflows/flatpak.yml",
   "dispatch_branch": "main", "tag_regex": "^v[0-9]+\\.[0-9]+$", "branch": "stable", "arches": ["x86_64"], "extra_refs": [], "max_repo_tar_bytes": 10000000,
   "packaging_prefix": "packaging/flatpak/", "permissions": {}}
}}
EOF
sed "s|\"repo_url\": \"[^\"]*\"|\"repo_url\": \"file://$T/live/repo\"|" "$root/config.json" >"$PUBLISHER_CONFIG"

# --- Synthetic builds, as an app repository's packaging makes them ----------------------------
RC=$(printf 'a%.0s' {1..64}) SC=$(printf 'b%.0s' {1..64})
# PKG_COMMIT (packaging revision, default: the tag's commit) and BUILD_TAMPER (run on $out/repo before
# packing) adjust a build.
build() { # out app_id tag commit content [extra-metadata-line]
    local out="$1" id="$2" tag="$3" commit="$4" content="$5" extra="${6:-}" d
    d="$(mktemp -d "$T/b.XXXX")"
    mkdir -p "$d/app/files/bin" "$d/app/export/share/applications" "$out"
    printf '{"id": "%s", "runtime-commit": "%s", "sdk-commit": "%s"}\n' "$id" "$RC" "$SC" >"$d/app/files/manifest.json"
    printf '{"id": "%s"}\n' "$id" >"$out/pkg-manifest.json"
    printf '#!/bin/sh\necho %s\n' "$content" >"$d/app/files/bin/hello"
    chmod +x "$d/app/files/bin/hello"
    printf '[Application]\nname=%s\nruntime=org.example.Platform/x86_64/1\nsdk=org.example.Sdk/x86_64/1\ncommand=hello\n%s\n' "$id" "$extra" >"$d/app/metadata"
    printf '[Desktop Entry]\nType=Application\nName=%s\nExec=hello\n' "$id" >"$d/app/export/share/applications/$id.desktop"
    ostree init --mode=archive-z2 --repo="$out/repo"
    flatpak build-export --arch=x86_64 "$out/repo" "$d/app" stable >/dev/null 2>&1
    if [[ "$id" == org.example.Alpha ]]; then
        mkdir -p "$d/loc/usr/share/locale" "$d/loc/files"; echo "$content" >"$d/loc/usr/share/locale/x"
        printf '[Runtime]\nname=%s.Locale\n' "$id" >"$d/loc/metadata"
        flatpak build-export --runtime --arch=x86_64 "$out/repo" "$d/loc" stable >/dev/null 2>&1
    fi
    [[ -z "${BUILD_TAMPER:-}" ]] || (cd "$out" && eval "$BUILD_TAMPER")
    tar --sort=name --owner=0 --group=0 -C "$out" -cf "$out/repo.tar" repo
    python3 -I - "$out" "$id" "$tag" "$commit" "${PKG_COMMIT:-$commit}" "$RC" "$SC" >"$out/SOURCE.json" <<'EOF'
import hashlib, json, subprocess, sys
out, app, tag, commit, pkg, rc, sc = sys.argv[1:]
refs = {r: subprocess.run(["ostree", f"--repo={out}/repo", "rev-parse", r], capture_output=True, text=True, check=True).stdout.strip()
        for r in subprocess.run(["ostree", f"--repo={out}/repo", "refs"], capture_output=True, text=True, check=True).stdout.split()}
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
print(json.dumps({"format": 2, "app_id": app, "arch": "x86_64", "branch": "stable", "source_tag": tag, "source_commit": commit,
                  "version": tag[1:], "refs": refs, "repo_tar": "repo.tar", "repo_tar_sha256": sha(f"{out}/repo.tar"),
                  "packaging_commit": pkg, "packaging_files": {f"packaging/flatpak/{app}.json": sha(f"{out}/pkg-manifest.json")},
                  "rendered_manifest_sha256": "c" * 64,
                  "runtime": {"ref": "org.example.Platform/x86_64/1", "commit": rc}, "sdk": {"ref": "org.example.Sdk/x86_64/1", "commit": sc}}))
EOF
    printf '{"source_repo": "example/%s", "run_id": 1, "run_attempt": 1, "event": "push", "created_at": "2026-11-01T00:00:00Z", "tag": "%s", "commit": "%s", "packaging_commit": "%s"}\n' \
        "$(tr A-Z a-z <<<"${id##*.}")" "$tag" "$commit" "${PKG_COMMIT:-$commit}" >"$out/RUN.json"
    rm -rf "$out/repo" "$d"
}
C1=1111111111111111111111111111111111111111 C2=2222222222222222222222222222222222222222 C3=3333333333333333333333333333333333333333

# The digest of the live summary: what the ledger records after a confirmed deployment.
live_sha() { sha256sum "$T/live/repo/summary" | cut -d' ' -f1; }
# publish NAME APP TAG COMMIT BUILD_DIR [--bootstrap]: the whole pipeline into $T/live (atomic swap)
publish() {
    local name="$1" app="$2" tag="$3" commit="$4" bdir="$5"; shift 5
    local w="$T/run-$name"
    rm -rf "$w"; mkdir -p "$w"
    "$root/scripts/verify-import.sh" --dir "$bdir" --app-id "$app" --tag "$tag" --commit "$commit" --arch x86_64 --out "$w/import" || return 1
    local fetch=("$@"); [[ " $* " == *" --bootstrap "* || ! -f "$T/live/repo/summary" ]] || fetch+=(--expect-summary-sha256 "$(live_sha)")
    [[ " $* " == *" --bootstrap "* || -f "$T/live/repo/summary" ]] || fetch+=(--expect-summary-sha256 "$(printf '0%.0s' {1..64})")
    "$root/scripts/fetch-published.sh" --out "$w/base" "${fetch[@]}" || return 1
    (
        export FLATPAK_GPG_PRIVATE_KEY="${KEY_OVERRIDE-$ARMORED}" FLATPAK_GPG_PASSPHRASE="${PASS_OVERRIDE-$PASS}" FLATPAK_GPG_FINGERPRINT="${FPR_OVERRIDE-$FPR}"
        source "$root/scripts/lib.sh"; source "$root/scripts/gpg-setup.sh"
        gpg_setup
        "$root/scripts/compose.sh" --base "$w/base" --import "$w/import" --source-json "$bdir/SOURCE.json" --run-json "$bdir/RUN.json" --site "$w/site"
    ) || return 1
    rm -rf "$T/live.old"; [[ -d "$T/live" ]] && mv "$T/live" "$T/live.old"; mv "$w/site" "$T/live"
}

build "$T/a1" org.example.Alpha v1.0 "$C1" alpha-1
build "$T/a2" org.example.Alpha v1.1 "$C2" alpha-2
build "$T/a0" org.example.Alpha v0.9 "$C3" alpha-0
build "$T/b1" org.example.Beta v2.0 "$C1" beta-1

expect_fail "no repository without explicit bootstrap" "only a run with bootstrap=true" publish boot0 org.example.Alpha v1.0 "$C1" "$T/a1"
expect_ok "bootstrap publishes the first app" publish boot org.example.Alpha v1.0 "$C1" "$T/a1" --bootstrap
expect_fail "bootstrap refused once a repository exists" "already published" publish boot2 org.example.Alpha v1.0 "$C1" "$T/a1" --bootstrap
expect_ok "second app added" publish beta org.example.Beta v2.0 "$C1" "$T/b1"
refs_after_beta="$(ostree --repo="$T/live/repo" refs | sort | tr '\n' ' ')"
[[ "$refs_after_beta" == *app/org.example.Alpha/x86_64/stable* && "$refs_after_beta" == *app/org.example.Beta/x86_64/stable* && "$refs_after_beta" == *runtime/org.example.Alpha.Locale/x86_64/stable* ]] \
    && ok "first app kept when publishing the second" || bad "refs after second app: $refs_after_beta"
alpha1="$(ostree --repo="$T/live/repo" rev-parse app/org.example.Alpha/x86_64/stable)"
beta1="$(ostree --repo="$T/live/repo" rev-parse app/org.example.Beta/x86_64/stable)"
expect_ok "update of the first app" publish alpha2 org.example.Alpha v1.1 "$C2" "$T/a2"
alpha2="$(ostree --repo="$T/live/repo" rev-parse app/org.example.Alpha/x86_64/stable)"
[[ "$(ostree --repo="$T/live/repo" rev-parse "$alpha2^")" == "$alpha1" ]] && ok "update's parent is the published commit (continuous history)" || bad "update parent"
[[ "$(ostree --repo="$T/live/repo" rev-parse app/org.example.Beta/x86_64/stable)" == "$beta1" ]] && ok "other app's commit untouched" || bad "other app changed"
ostree --repo="$T/live/repo" show "$alpha2" | grep -q 'source-tag=v1.1' && ok "source tag recorded in the commit" || bad "source record"
shown="$(ostree --repo="$T/live/repo" show "$alpha2")"
grep -q "packaging-commit=$C2" <<<"$shown" && grep -q "runtime=org.example.Platform/x86_64/1@$RC" <<<"$shown" && grep -q "sdk=org.example.Sdk/x86_64/1@$SC" <<<"$shown" \
    && grep -q 'packaging-file=packaging/flatpak/org.example.Alpha.json@' <<<"$shown" && grep -q 'source-run=1/1' <<<"$shown" \
    && ok "build identity (packaging, runtime/SDK commits, files, run) signed into the commit" || bad "build identity record"
ls "$T/live/repo/deltas" >/dev/null 2>&1 && [[ -n "$(find "$T/live/repo/deltas" -type f | head -1)" ]] && ok "static deltas generated" || bad "no static deltas"
expect_fail "downgrade refused" "not newer" publish down org.example.Alpha v0.9 "$C3" "$T/a0"
expect_ok "same release again is a no-op" publish again org.example.Alpha v1.1 "$C2" "$T/a2"
[[ "$(ostree --repo="$T/live/repo" rev-parse app/org.example.Alpha/x86_64/stable)" == "$alpha2" ]] && ok "no-op keeps the commit" || bad "no-op changed the commit"
build "$T/a2x" org.example.Alpha v1.1 "$C3" alpha-2x
expect_fail "same tag from another commit refused" "was published from" publish retag org.example.Alpha v1.1 "$C3" "$T/a2x"

# A client trusting the .flatpakrepo can install and update.
flatpakrepo="$T/live/manicminer.flatpakrepo"
grep -q "^GPGKey=$(base64 -w0 "$T/keys/pub.gpg")\$" "$flatpakrepo" && ok ".flatpakrepo embeds the pinned key" || bad ".flatpakrepo key"
grep -q '^RuntimeRepo=https://dl.flathub.org/repo/flathub.flatpakrepo$' "$T/live/org.example.Alpha.flatpakref" && ok ".flatpakref names Flathub as runtime repository" || bad ".flatpakref runtime repo"
cp "$flatpakrepo" "$T/repo1"; publish beta2 org.example.Beta v2.0 "$C1" "$T/b1" >/dev/null 2>&1
cmp -s "$T/repo1" "$T/live/manicminer.flatpakrepo" && ok ".flatpakrepo bytes stable across runs" || bad ".flatpakrepo changed"
ostree init --mode=bare-user --repo="$T/client"
ostree --repo="$T/client" remote add --gpg-import="$T/keys/pub.gpg" --set=gpg-verify-summary=true m "file://$T/live/repo"
expect_ok "client pulls with signature verification" ostree --repo="$T/client" pull m app/org.example.Alpha/x86_64/stable

# Attacker scenarios.
cp -a "$T/live" "$T/forged"
flatpak build-update-repo --gpg-sign="$ATTACKER_FPR" --gpg-homedir="$T/attacker" "$T/forged/repo" >/dev/null 2>&1 || true
rm -f "$T/forged/repo/summary.sig"
GNUPGHOME="$T/attacker" flatpak build-update-repo --gpg-sign="$ATTACKER_FPR" --gpg-homedir="$T/attacker" "$T/forged/repo" >/dev/null 2>&1 || true
expect_fail "base signed by another key refused" "" "$root/scripts/fetch-published.sh" --out "$T/fx" --url "file://$T/forged/repo"
expect_fail "wrong passphrase refused without prompting" "wrong passphrase" timeout 120 env PASS_OVERRIDE=nope bash -c "$(declare -f publish build live_sha); $(declare -p T root ARMORED PASS FPR); publish wp org.example.Alpha v1.1 $C2 $T/a2"
expect_fail "fingerprint variable must match the pin" "does not match" env FPR_OVERRIDE="$ATTACKER_FPR" bash -c "$(declare -f publish live_sha); $(declare -p T root ARMORED PASS FPR); publish wf org.example.Alpha v1.1 $C2 $T/a2"
expect_fail "other secret key refused" "not (only) the pinned key" env KEY_OVERRIDE="$ATTACKER_ARMORED" bash -c "$(declare -f publish live_sha); $(declare -p T root ARMORED PASS FPR); publish wk org.example.Alpha v1.1 $C2 $T/a2"
expect_fail "missing key refused (no unsigned fallback)" "refusing to publish unsigned" env KEY_OVERRIDE= bash -c "$(declare -f publish live_sha); $(declare -p T root ARMORED PASS FPR); publish nk org.example.Alpha v1.1 $C2 $T/a2"
expect_ok "signing GNUPGHOME has an agent that cannot prompt" bash -c '
    export FLATPAK_GPG_PRIVATE_KEY="$1" FLATPAK_GPG_PASSPHRASE="$2" FLATPAK_GPG_FINGERPRINT="$3"
    source "$4/scripts/lib.sh"; source "$4/scripts/gpg-setup.sh"; gpg_setup
    grep -qx "pinentry-program /usr/bin/false" "$GNUPGHOME/gpg-agent.conf" && grep -qx batch "$GNUPGHOME/gpg.conf"' _ "$ARMORED" "$PASS" "$FPR" "$root"
if grep -rqF -e "$PASS" -e "PRIVATE KEY BLOCK" "$T"/last.log "$T"/run-*/ 2>/dev/null; then bad "secret material in logs or outputs"; else ok "no secret material in logs or outputs"; fi
[[ -z "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'publisher-gnupg.*' -user "$(id -u)" 2>/dev/null)" ]] && ok "temporary GNUPGHOME removed" || bad "GNUPGHOME left behind"

# Import validation.
expect_fail "tag mismatch refused" "source_tag" "$root/scripts/verify-import.sh" --dir "$T/a1" --app-id org.example.Alpha --tag v1.1 --commit "$C1" --arch x86_64 --out "$T/vi1"
expect_fail "commit mismatch refused" "source_commit" "$root/scripts/verify-import.sh" --dir "$T/a1" --app-id org.example.Alpha --tag v1.0 --commit "$C2" --arch x86_64 --out "$T/vi2"
expect_fail "app not in allowlist refused" "not in the allowlist" "$root/scripts/verify-import.sh" --dir "$T/a1" --app-id org.example.Gamma --tag v1.0 --commit "$C1" --arch x86_64 --out "$T/vi3"
expect_fail "other app's build refused" "app_id" "$root/scripts/verify-import.sh" --dir "$T/b1" --app-id org.example.Alpha --tag v2.0 --commit "$C1" --arch x86_64 --out "$T/vi4"
cp -a "$T/a1" "$T/a1t"; printf 'x' >>"$T/a1t/repo.tar"
expect_fail "tampered repo.tar refused" "digest" "$root/scripts/verify-import.sh" --dir "$T/a1t" --app-id org.example.Alpha --tag v1.0 --commit "$C1" --arch x86_64 --out "$T/vi5"
# Permissions: only those approved for the app in apps.json.
n=0
for grant in 'filesystems=host;' 'filesystems=/home/tom;' 'filesystems=~/Documents;' 'filesystems=xdg-run/foo;' 'filesystems=home:ro;' \
    'sockets=session-bus;' 'devices=all;' 'shared=network;ipc;\nfeatures=devel;'; do
    n=$((n + 1))
    build "$T/perm$n" org.example.Alpha v1.2 "$C1" p$n "$(printf '\n[Context]\n%b' "$grant")"
    expect_fail "unapproved permission refused: $grant" "unapproved permission" "$root/scripts/verify-import.sh" --dir "$T/perm$n" --app-id org.example.Alpha --tag v1.2 --commit "$C1" --arch x86_64 --out "$T/vp$n"
done
build "$T/af" org.example.Alpha v1.2 "$C1" spawn $'\n[Session Bus Policy]\norg.freedesktop.Flatpak=talk'
expect_fail "host command execution refused" "unapproved Session Bus Policy" "$root/scripts/verify-import.sh" --dir "$T/af" --app-id org.example.Alpha --tag v1.2 --commit "$C1" --arch x86_64 --out "$T/vi7"
build "$T/aown" org.example.Alpha v1.2 "$C1" own $'\n[Session Bus Policy]\norg.example.Ok=own'
expect_fail "approved bus name with a wider policy refused" "unapproved Session Bus Policy" "$root/scripts/verify-import.sh" --dir "$T/aown" --app-id org.example.Alpha --tag v1.2 --commit "$C1" --arch x86_64 --out "$T/vi8"
build "$T/apol" org.example.Alpha v1.2 "$C1" pol $'\n[Policy dconf]\nkeys=x'
expect_fail "unknown permission section refused" "is not allowed" "$root/scripts/verify-import.sh" --dir "$T/apol" --app-id org.example.Alpha --tag v1.2 --commit "$C1" --arch x86_64 --out "$T/vi9"
build "$T/aok" org.example.Alpha v1.2 "$C1" fine $'\n[Context]\nshared=network;\nfilesystems=xdg-config/kdeglobals:ro;\n[Session Bus Policy]\norg.example.Ok=talk'
expect_ok "approved permissions accepted" "$root/scripts/verify-import.sh" --dir "$T/aok" --app-id org.example.Alpha --tag v1.2 --commit "$C1" --arch x86_64 --out "$T/vi10"
# Build identity.
build "$T/arc" org.example.Alpha v1.2 "$C1" rc
python3 -I -c 'import json,sys; p=sys.argv[1]; j=json.load(open(p)); j["runtime"]["commit"]="d"*64; json.dump(j,open(p,"w"))' "$T/arc/SOURCE.json"
expect_fail "runtime commit other than the build record refused" "runtime commit" "$root/scripts/verify-import.sh" --dir "$T/arc" --app-id org.example.Alpha --tag v1.2 --commit "$C1" --arch x86_64 --out "$T/vi11"
build "$T/apf" org.example.Alpha v1.2 "$C1" pf
python3 -I -c 'import json,sys; p=sys.argv[1]; j=json.load(open(p)); j["packaging_files"]={"../../etc/x": "e"*64}; json.dump(j,open(p,"w"))' "$T/apf/SOURCE.json"
expect_fail "packaging file outside the packaging prefix refused" "bad packaging file" "$root/scripts/verify-import.sh" --dir "$T/apf" --app-id org.example.Alpha --tag v1.2 --commit "$C1" --arch x86_64 --out "$T/vi12"
# The build's OSTree configuration is replaced, not carried over.
BUILD_TAMPER='printf "[remote \"evil\"]\nurl=http://attacker.invalid/\ngpg-verify=false\n[core]\nadd-remotes-config-dir=true\n" >>repo/config; mkdir -p repo/remotes.d; printf "[remote \"x\"]\nurl=http://x.invalid/\n" >repo/remotes.d/x.conf' \
    build "$T/acfg" org.example.Alpha v1.2 "$C1" cfg
expect_ok "build with its own remotes and core options imported" "$root/scripts/verify-import.sh" --dir "$T/acfg" --app-id org.example.Alpha --tag v1.2 --commit "$C1" --arch x86_64 --out "$T/vi13"
[[ "$(cat "$T/vi13/config")" == $'[core]\nrepo_version=1\nmode=archive-z2' && ! -e "$T/vi13/remotes.d" ]] && ! ostree --repo="$T/vi13" remote list | grep -q . \
    && ok "imported repository config normalized (no remotes, no core options)" || bad "imported config: $(cat "$T/vi13/config")"
for k in packaging_commit packaging_files rendered_manifest_sha256 runtime sdk; do
    rm -rf "$T/anoid"; cp -a "$T/a1" "$T/anoid"; jq "del(.$k)" "$T/a1/SOURCE.json" >"$T/anoid/SOURCE.json"
    expect_fail "build without $k (no build identity) refused" "lacks" "$root/scripts/verify-import.sh" --dir "$T/anoid" --app-id org.example.Alpha --tag v1.0 --commit "$C1" --arch x86_64 --out "$T/vi-$k"
done
rm -rf "$T/anoid"; cp -a "$T/a1" "$T/anoid"; jq '.packaging_files["packaging/flatpak/../../x"] = ("0" * 64)' "$T/a1/SOURCE.json" >"$T/anoid/SOURCE.json"
expect_fail "packaging file path outside the packaging prefix refused" "bad packaging file" "$root/scripts/verify-import.sh" --dir "$T/anoid" --app-id org.example.Alpha --tag v1.0 --commit "$C1" --arch x86_64 --out "$T/vi-pf"

# Safe extraction.
mkdir -p "$T/evil/repo"; echo x >"$T/evil/repo/f"
ln -s /etc/passwd "$T/evil/repo/link"
tar -C "$T/evil" -cf "$T/symlink.tar" repo
expect_fail "symlink member refused" "not a regular file" python3 -I "$root/scripts/safe-extract.py" "$T/symlink.tar" "$T/se1" --allow-prefix repo/
python3 -I - "$T" <<'EOF'
import io, sys, tarfile
t = sys.argv[1]
def mk(name, **kw):
    with tarfile.open(f"{t}/{name}.tar", "w") as tf:
        for member, data, typ in kw["members"]:
            ti = tarfile.TarInfo(member); ti.size = len(data); ti.type = typ
            if typ == tarfile.LNKTYPE: ti.linkname = "repo/f"; ti.size = 0
            tf.addfile(ti, io.BytesIO(data) if typ == tarfile.REGTYPE else None)
mk("dotdot", members=[("repo/../../x", b"x", tarfile.REGTYPE)])
mk("abs", members=[("/tmp/x", b"x", tarfile.REGTYPE)])
mk("hard", members=[("repo/f", b"x", tarfile.REGTYPE), ("repo/h", b"", tarfile.LNKTYPE)])
mk("dev", members=[("repo/d", b"", tarfile.CHRTYPE)])
mk("outside", members=[("other/x", b"x", tarfile.REGTYPE)])
mk("dup", members=[("repo/f", b"x", tarfile.REGTYPE), ("repo/f", b"y", tarfile.REGTYPE)])
EOF
for c in dotdot abs hard dev outside dup; do
    expect_fail "tar member: $c refused" "refused" python3 -I "$root/scripts/safe-extract.py" "$T/$c.tar" "$T/se-$c" --allow-prefix repo/
done
mkdir "$T/exists"
expect_fail "existing destination refused" "exists" python3 -I "$root/scripts/safe-extract.py" "$T/a1/repo.tar" "$T/exists" --allow-prefix repo/

# --- Base freshness: only the summary the ledger recorded as deployed is a base ---------------
expect_fail "older signed snapshot refused as base (no rollback)" "ledger expects" \
    "$root/scripts/fetch-published.sh" --out "$T/fold" --url "file://$T/live.old/repo" --expect-summary-sha256 "$(live_sha)"
expect_ok "current snapshot with the recorded digest accepted" \
    "$root/scripts/fetch-published.sh" --out "$T/fcur" --url "file://$T/live/repo" --expect-summary-sha256 "$(live_sha)"
expect_fail "base without a ledger digest refused" "required" "$root/scripts/fetch-published.sh" --out "$T/fnone" --url "file://$T/live/repo"

# --- Ledger decisions ----------------------------------------------------------------------------
L="$root/scripts/ledger.py"
D=$(printf 'd%.0s' {1..64}) P=$(printf 'e%.0s' {1..64}) O=$(printf 'f%.0s' {1..64})
mkstate() { # file deployed [pending]
    python3 -I -c 'import json,sys; d={"summary_sha256":sys.argv[2],"refs":{"app/org.example.Alpha/x86_64/stable":{"commit":"1"*64,"tag":"v1.1"}},"builds":[],"publisher_run":"1/1"}
p=None if len(sys.argv)<4 else {"summary_sha256":sys.argv[3],"refs":{"app/org.example.Alpha/x86_64/stable":{"commit":"2"*64,"tag":"v1.2"}},"builds":[],"publisher_run":"2/1"}
json.dump({"format":1,"deployed":d,"pending":p},open(sys.argv[1],"w"))' "$@"
}
decide() { python3 -I "$L" decide "$@" | jq -r '"\(.action) \(.base) \(.update)"'; }
check() { local name="$1" want="$2"; shift 2; local got; got="$(decide "$@" 2>&1)"; [[ "$got" == "$want" ]] && ok "$name" || bad "$name: got '$got', want '$want'"; }
mkstate "$T/s-dep.json" "$D"; mkstate "$T/s-pend.json" "$D" "$P"
check "ledger: no ledger, no bootstrap -> blocked" "block  none" --state "$T/none.json" --live "$D"
check "ledger: bootstrap of an empty site" "publish  none" --state "$T/none.json" --live none --bootstrap
check "ledger: bootstrap refused once deployed" "block  none" --state "$T/s-dep.json" --live none --bootstrap
check "ledger: live = deployed -> publish on it" "publish $D none" --state "$T/s-dep.json" --live "$D"
check "ledger: live older than deployed (stale CDN/rollback) -> blocked" "block  none" --state "$T/s-dep.json" --live "$O"
check "ledger: pending deployment now live -> confirmed" "publish $P confirm" --state "$T/s-pend.json" --live "$P"
check "ledger: uncertain deployment blocks the next run" "block  none" --state "$T/s-pend.json" --live "$D"
check "ledger: owner reconcile of a deployment that never went live" "publish $D abandon" --state "$T/s-pend.json" --live "$D" --reconcile
check "ledger: reconcile cannot accept an older snapshot" "block  none" --state "$T/s-pend.json" --live "$O" --reconcile
check "ledger: owner accepts an explicit live digest" "publish $O accept" --state "$T/s-pend.json" --live "$O" --accept "$O"
check "ledger: accept refused when live differs" "block  none" --state "$T/s-dep.json" --live "$D" --accept "$O"
python3 -I "$L" published --state "$T/s-pend.json" --update confirm --live "$P" | grep -qx '{"org.example.Alpha": "v1.2"}' \
    && ok "ledger: published tags follow a confirmed deployment" || bad "ledger published tags"
echo '{"app/org.example.Alpha/x86_64/stable": {"commit": "'"$(printf '3%.0s' {1..64})"'", "tag": "v1.3"}}' >"$T/refs.json"; echo '[]' >"$T/builds.json"
expect_fail "ledger: second pending refused" "already pending" python3 -I "$L" pending --state "$T/s-pend.json" --summary "$O" --refs "$T/refs.json" --builds "$T/builds.json" --run 9/1
expect_ok "ledger: pending after confirming the previous one" sh -c "python3 -I '$L' pending --state '$T/s-pend.json' --update confirm --live '$P' --summary '$O' --refs '$T/refs.json' --builds '$T/builds.json' --run 9/1 >'$T/s-new.json'"
[[ "$(jq -r '.deployed.summary_sha256 + " " + .pending.summary_sha256' "$T/s-new.json")" == "$P $O" ]] && ok "ledger: pending recorded before deployment" || bad "ledger pending content"
expect_fail "ledger: deployed only for the pending digest" "not the pending one" python3 -I "$L" deployed --state "$T/s-new.json" --summary "$D"
python3 -I "$L" deployed --state "$T/s-new.json" --summary "$O" | jq -e --arg o "$O" '.deployed.summary_sha256 == $o and .pending == null' >/dev/null \
    && ok "ledger: deployment confirmed" || bad "ledger deployed"
# First publication whose deployment failed or is uncertain: the ledger records the empty site
# explicitly; recovery is an explicit owner action, never an older or foreign snapshot.
python3 -I "$L" pending --state "$T/none.json" --summary "$P" --refs "$T/refs.json" --builds "$T/builds.json" --run 1/1 >"$T/s-boot.json"
check "ledger bootstrap: failed/uncertain first deployment blocks a plain run" "block  none" --state "$T/s-boot.json" --live none
check "ledger bootstrap: first deployment went live late -> confirmed" "publish $P confirm" --state "$T/s-boot.json" --live "$P"
check "ledger bootstrap: reconcile of a first deployment that never went live -> empty base" "publish  abandon" --state "$T/s-boot.json" --live none --reconcile
check "ledger bootstrap: bootstrap retry after a failed first deployment -> empty base" "publish  abandon" --state "$T/s-boot.json" --live none --bootstrap
check "ledger bootstrap: reconcile refused when another site is live" "block  none" --state "$T/s-boot.json" --live "$O" --reconcile
check "ledger bootstrap: bootstrap retry refused when another site is live" "block  none" --state "$T/s-boot.json" --live "$O" --bootstrap
check "ledger bootstrap: bootstrap retry refused when the pending one is live" "block  none" --state "$T/s-boot.json" --live "$P" --bootstrap
check "ledger bootstrap: bootstrap refused after a real deployment (pending, site gone)" "block  none" --state "$T/s-pend.json" --live none --bootstrap
check "ledger bootstrap: reconcile refused after a real deployment (site gone)" "block  none" --state "$T/s-pend.json" --live none --reconcile
check "ledger bootstrap: deployed site gone -> blocked" "block  none" --state "$T/s-dep.json" --live none
expect_ok "ledger bootstrap: retry records a new pending on the empty base" sh -c "python3 -I '$L' pending --state '$T/s-boot.json' --update abandon --live none --summary '$O' --refs '$T/refs.json' --builds '$T/builds.json' --run 2/1 >'$T/s-boot2.json'"
jq -e --arg o "$O" '.deployed.summary_sha256 == ("0" * 64) and .deployed.refs == {} and .pending.summary_sha256 == $o' "$T/s-boot2.json" >/dev/null \
    && ok "ledger bootstrap: retry keeps the empty deployed base" || bad "ledger bootstrap retry content: $(cat "$T/s-boot2.json")"
python3 -I "$L" update --state "$T/s-boot.json" --update abandon --live none >"$T/s-boot3.json"
check "ledger bootstrap: abandoned first deployment, empty site -> publish on empty base" "publish  none" --state "$T/s-boot3.json" --live none
check "ledger bootstrap: abandoned first deployment, unknown site live -> blocked" "block  none" --state "$T/s-boot3.json" --live "$O"
[[ "$(python3 -I "$L" published --state "$T/s-boot.json" --update abandon --live none)" == "{}" ]] && ok "ledger bootstrap: nothing counted as published after abandon" || bad "ledger bootstrap published"
expect_fail "ledger: abandon of a real deployment with the site gone refused" "not the deployed one" python3 -I "$L" update --state "$T/s-pend.json" --update abandon --live none
expect_fail "ledger: the empty-site marker is never a pending summary" "empty-site" python3 -I "$L" pending --state "$T/none.json" --summary "$(printf '0%.0s' {1..64})" --refs "$T/refs.json" --builds "$T/builds.json" --run 1/1
echo '{"x; rm -rf /": {"commit": "1"}}' >"$T/badrefs.json"
expect_fail "ledger: malformed refs refused" "refs must map" python3 -I "$L" pending --state "$T/s-dep.json" --summary "$O" --refs "$T/badrefs.json" --builds "$T/builds.json" --run 9/1

# --- Ledger branch: compare-and-swap writes --------------------------------------------------------
G="$root/scripts/ledger-git.sh"
git init -q --bare "$T/state.git"
[[ "$("$G" read --remote "$T/state.git" --out "$T/l0.json")" == none && ! -e "$T/l0.json" ]] && ok "ledger branch: none yet" || bad "ledger read none"
h1="$("$G" write --remote "$T/state.git" --expect none --file "$T/s-dep.json" --message one)"
[[ "$h1" =~ ^[0-9a-f]{40}$ ]] && ok "ledger branch: first write" || bad "ledger first write"
expect_fail "ledger branch: write from a stale head refused (another run)" "moved" "$G" write --remote "$T/state.git" --expect none --file "$T/s-pend.json" --message two
h2="$("$G" write --remote "$T/state.git" --expect "$h1" --file "$T/s-pend.json" --message two)"
[[ "$("$G" read --remote "$T/state.git" --out "$T/l2.json")" == "$h2" ]] && cmp -s "$T/l2.json" "$T/s-pend.json" && ok "ledger branch: CAS write and read back" || bad "ledger CAS read back"
expect_fail "ledger branch: unreachable remote is an error, not an empty ledger" "cannot read" "$G" read --remote "$T/missing.git" --out "$T/l3.json"
[[ "$(git --git-dir="$T/state.git" ls-tree --name-only publisher-state)" == state.json ]] && ok "ledger branch holds state.json only" || bad "ledger branch content"

# --- Discovery and validation against fixture APIs (fake gh, never the network) ----------------
export GH_FIXTURES="$T/fix"; mkdir -p "$GH_FIXTURES" "$T/bin"; cp "$root/tests/fake-gh" "$T/bin/gh"
FX() { python3 -I "$root/tests/fixtures.py" "$GH_FIXTURES" "$@"; }
SINCE=2026-10-06 TODAY=2026-11-05 MASTER=4444444444444444444444444444444444444444
C4=5555555555555555555555555555555555555555 C5=6666666666666666666666666666666666666666 C6=7777777777777777777777777777777777777777
build "$T/f-a12" org.example.Alpha v1.2 "$C4" alpha-12
build "$T/f-a13" org.example.Alpha v1.3 "$C5" alpha-13
PKG_COMMIT="$MASTER" build "$T/f-b21" org.example.Beta v2.1 "$C6" beta-21
FX repo example/alpha; FX repo example/beta
FX tag example/alpha v1.2 "$C4"; FX tag example/alpha v1.3 "$C5"; FX tag example/beta v2.1 "$C6"
# The allowlisted branches, resolved by the publisher itself (never from the source workflow):
# alpha's master is ahead of both release tags; beta's main moved on after the dispatch (MASTER),
# so the dispatch's tag (C6) and packaging commit are both ancestors of the newer head.
AHEAD=8888888888888888888888888888888888888888 MAINHEAD=9999999999999999999999999999999999999999
FX branch example/alpha master "$AHEAD"; FX branch example/beta main "$MAINHEAD"
FX compare example/alpha "$C4" "$AHEAD" ahead; FX compare example/alpha "$C5" "$AHEAD" ahead
FX compare example/beta "$C6" "$MAINHEAD" ahead; FX compare example/beta "$MASTER" "$MAINHEAD" ahead; FX compare example/beta "$C1" "$MAINHEAD" ahead
FX file example/alpha packaging/flatpak/org.example.Alpha.json "$C4" "$T/f-a12/pkg-manifest.json"
echo '{"id": "tampered"}' >"$T/other.json"
FX file example/alpha packaging/flatpak/org.example.Alpha.json "$C5" "$T/other.json"   # a13 declares another digest
FX file example/beta packaging/flatpak/org.example.Beta.json "$MASTER" "$T/f-b21/pkg-manifest.json"
FX run example/alpha '{"id": 501, "app_id": "org.example.Alpha", "event": "push", "head_branch": "v1.2", "head_sha": "'"$C4"'", "created_at": "2026-11-01T10:00:00Z"}' "$T/f-a12"
FX run example/alpha '{"id": 502, "app_id": "org.example.Alpha", "event": "push", "head_branch": "v1.3", "head_sha": "'"$C5"'", "created_at": "2026-11-02T10:00:00Z"}' "$T/f-a13"
FX run example/beta '{"id": 503, "app_id": "org.example.Beta", "event": "workflow_dispatch", "head_branch": "main", "head_sha": "'"$MASTER"'", "display_title": "Flatpak v2.1", "created_at": "2026-11-01T12:00:00Z"}' "$T/f-b21"
filler="$(python3 -I -c 'import json; print(json.dumps([{"id": 1000+i, "event": "pull_request", "head_branch": "pr", "head_sha": "0"*40, "created_at": "2026-10-20T00:00:00Z"} for i in range(100)]))')"
FX runs example/alpha flatpak.yml "$SINCE" 1 "$filler"
FX runs example/alpha flatpak.yml "$SINCE" 2 '[
 {"id": 502, "event": "push", "head_branch": "v1.3", "head_sha": "'"$C5"'", "created_at": "2026-11-02T10:00:00Z"},
 {"id": 501, "event": "push", "head_branch": "v1.2", "head_sha": "'"$C4"'", "created_at": "2026-11-01T10:00:00Z"},
 {"id": 499, "event": "push", "head_branch": "v1.0", "head_sha": "'"$C1"'", "created_at": "2026-10-30T10:00:00Z"},
 {"id": 498, "event": "push", "head_branch": "v1.9;evil", "head_sha": "'"$C1"'", "created_at": "2026-10-30T11:00:00Z"},
 {"id": 497, "event": "push", "head_branch": "v1.8", "head_sha": "'"$C1"'", "path": ".github/workflows/other.yml", "created_at": "2026-10-30T12:00:00Z"}]'
FX runs example/beta flatpak.yml "$SINCE" 1 '[
 {"id": 503, "event": "workflow_dispatch", "head_branch": "main", "head_sha": "'"$MASTER"'", "display_title": "Flatpak v2.1", "created_at": "2026-11-01T12:00:00Z"},
 {"id": 504, "event": "workflow_dispatch", "head_branch": "feature", "head_sha": "'"$MASTER"'", "display_title": "Flatpak v2.2", "created_at": "2026-11-01T13:00:00Z"}]'
echo '{"org.example.Alpha": "v1.1", "org.example.Beta": "v2.0"}' >"$T/published.json"
PATH="$T/bin:$PATH" python3 -I "$root/scripts/discover.py" --apps "$PUBLISHER_APPS" --config "$PUBLISHER_CONFIG" --published "$T/published.json" --today "$TODAY" >"$T/disc.tsv" 2>"$T/last.log" \
    && [[ "$(cut -f2,3,5 "$T/disc.tsv" | tr '\t\n' ' |')" == "501 org.example.Alpha v1.2|503 org.example.Beta v2.1|502 org.example.Alpha v1.3|" ]] \
    && ok "discovery: all pages, every app, oldest first, only newer allowlisted-workflow builds" || bad "discovery: $(cat "$T/disc.tsv" "$T/last.log")"
expect_ok "plan: validates in order, skips an invalid build, keeps the others" env PATH="$T/bin:$PATH" "$root/scripts/plan.sh" --published "$T/published.json" --out "$T/validated" --today "$TODAY"
[[ "$(jq -r 'map("\(.run_id) \(.tag)") | join(",")' "$T/validated/plan.json")" == "501 v1.2,503 v2.1" ]] && grep -q 'skipped example/alpha run 502' "$T/last.log" \
    && ok "plan: v1.2 and the other app's v2.1 queued; tampered v1.3 skipped with a warning" || bad "plan: $(cat "$T/validated/plan.json")"
jq -e --arg m "$MASTER" '.packaging_commit == $m and .event == "workflow_dispatch"' "$T/validated/001/RUN.json" >/dev/null && ok "plan: run identity recorded (dispatch packaging commit)" || bad "RUN.json"
! grep -qv '^repos/example/' "$GH_FIXTURES/calls.log" && ok "only fixture API paths of allowlisted repositories requested" || bad "unexpected API calls"
vs() { env PATH="$T/bin:$PATH" "$root/scripts/validate-source.sh" "$@"; }
FX repo example/private private
python3 -I -c 'import json,sys; p=sys.argv[1]; a=json.load(open(p)); a["apps"]["org.example.Alpha"]["source_repo"]="example/private"; json.dump(a,open(p,"w"))' "$(cp "$PUBLISHER_APPS" "$T/apps-priv.json"; echo "$T/apps-priv.json")"
expect_fail "validate: private source repository refused" "not a public repository" env PUBLISHER_APPS="$T/apps-priv.json" PATH="$T/bin:$PATH" "$root/scripts/validate-source.sh" --app-id org.example.Alpha --source-repo example/private --tag v1.2 --run-id 501 --out "$T/v1"
expect_fail "validate: run of another tag refused" "did not build" vs --app-id org.example.Alpha --source-repo example/alpha --tag v1.3 --run-id 501 --out "$T/v2"
expect_fail "validate: packaging file digest differs from the source repository" "differs from example/alpha" vs --app-id org.example.Alpha --source-repo example/alpha --tag v1.3 --run-id 502 --out "$T/v3"
FX run example/beta '{"id": 505, "app_id": "org.example.Beta", "event": "workflow_dispatch", "head_branch": "main", "head_sha": "'"$MASTER"'", "display_title": "Flatpak v2.2", "created_at": "2026-11-01T12:00:00Z"}' "$T/f-b21"
expect_fail "validate: dispatch naming another tag refused" "is not a main build of v2.1" vs --app-id org.example.Beta --source-repo example/beta --tag v2.1 --run-id 505 --out "$T/v4"
FX run example/beta '{"id": 506, "app_id": "org.example.Beta", "event": "workflow_dispatch", "head_branch": "main", "head_sha": "'"$C1"'", "display_title": "Flatpak v2.1", "created_at": "2026-11-01T12:00:00Z"}' "$T/f-b21"
expect_fail "validate: packaging commit other than the run's refused" "packaging commit" vs --app-id org.example.Beta --source-repo example/beta --tag v2.1 --run-id 506 --out "$T/v5"
FX run example/beta '{"id": 507, "app_id": "org.example.Beta", "event": "workflow_dispatch", "head_branch": "main", "head_sha": "'"$MASTER"'", "display_title": "Flatpak v2.1", "created_at": "2026-11-01T12:00:00Z"}' "$T/f-b21" bad-digest
expect_fail "validate: artifact digest mismatch refused" "digest mismatch" vs --app-id org.example.Beta --source-repo example/beta --tag v2.1 --run-id 507 --out "$T/v6"
FX run example/beta '{"id": 508, "app_id": "org.example.Beta", "event": "workflow_dispatch", "head_branch": "main", "head_sha": "'"$MASTER"'", "display_title": "Flatpak v2.1", "path": ".github/workflows/evil.yml", "created_at": "2026-11-01T12:00:00Z"}' "$T/f-b21"
expect_fail "validate: other workflow refused" "is not a successful" vs --app-id org.example.Beta --source-repo example/beta --tag v2.1 --run-id 508 --out "$T/v7"
jq -e --arg h "$MAINHEAD" '.dispatch_branch == "main" and .dispatch_branch_sha == $h and .dispatch_branch_protected == true' "$T/validated/001/RUN.json" >/dev/null \
    && ok "validate: resolved branch head SHA recorded in RUN.json (provenance)" || bad "RUN.json branch provenance: $(cat "$T/validated/001/RUN.json")"
# Ancestry against the resolved allowlisted branch head, checked by the publisher itself.
D1=a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1 D2=b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2 D3=c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3
build "$T/f-a14" org.example.Alpha v1.4 "$D1" alpha-14
FX tag example/alpha v1.4 "$D1"; FX file example/alpha packaging/flatpak/org.example.Alpha.json "$D1" "$T/f-a14/pkg-manifest.json"
FX run example/alpha '{"id": 601, "app_id": "org.example.Alpha", "event": "push", "head_branch": "v1.4", "head_sha": "'"$D1"'", "created_at": "2026-11-03T10:00:00Z"}' "$T/f-a14"
FX compare example/alpha "$D1" "$AHEAD" diverged
expect_fail "validate: tag push whose commit diverged from the allowlisted branch refused" "is not on master" vs --app-id org.example.Alpha --source-repo example/alpha --tag v1.4 --run-id 601 --out "$T/va1"
FX compare example/alpha "$D1" "$AHEAD" behind
expect_fail "validate: tag commit newer than the resolved branch head refused" "is not on master" vs --app-id org.example.Alpha --source-repo example/alpha --tag v1.4 --run-id 601 --out "$T/va2"
rm -f "$GH_FIXTURES/$(printf 'repos/example/alpha/compare/%s...%s?per_page=1' "$D1" "$AHEAD" | sed 's/[^A-Za-z0-9]/_/g')"
expect_fail "validate: missing comparison fails closed" "cannot compare" vs --app-id org.example.Alpha --source-repo example/alpha --tag v1.4 --run-id 601 --out "$T/va3"
FX compare example/alpha "$D1" "$AHEAD" identical
expect_ok "validate: tag push at the branch head (identical) accepted" vs --app-id org.example.Alpha --source-repo example/alpha --tag v1.4 --run-id 601 --out "$T/va4"
# Dispatch from master's packaging, but that packaging commit is no longer on master (force-push).
PKG_COMMIT="$D2" build "$T/f-b22" org.example.Beta v2.2 "$C6" beta-22
FX tag example/beta v2.2 "$C6"; FX file example/beta packaging/flatpak/org.example.Beta.json "$D2" "$T/f-b22/pkg-manifest.json"
FX run example/beta '{"id": 602, "app_id": "org.example.Beta", "event": "workflow_dispatch", "head_branch": "main", "head_sha": "'"$D2"'", "display_title": "Flatpak v2.2", "created_at": "2026-11-03T10:00:00Z"}' "$T/f-b22"
FX compare example/beta "$D2" "$MAINHEAD" diverged
expect_fail "validate: dispatch whose packaging commit is not on the branch refused" "packaging commit $D2 is not on main" vs --app-id org.example.Beta --source-repo example/beta --tag v2.2 --run-id 602 --out "$T/va5"
FX compare example/beta "$D2" "$MAINHEAD" ahead
expect_ok "validate: dispatch with packaging and tag both ancestors of the branch head accepted" vs --app-id org.example.Beta --source-repo example/beta --tag v2.2 --run-id 602 --out "$T/va6"
# A dispatch on another branch claiming the allowlisted tag, and a source-side "on master" claim
# that the publisher's own comparison contradicts.
FX run example/beta '{"id": 603, "app_id": "org.example.Beta", "event": "workflow_dispatch", "head_branch": "feature", "head_sha": "'"$D2"'", "display_title": "Flatpak v2.2", "created_at": "2026-11-03T10:00:00Z"}' "$T/f-b22"
expect_fail "validate: dispatch on a foreign branch refused" "is not a main build" vs --app-id org.example.Beta --source-repo example/beta --tag v2.2 --run-id 603 --out "$T/va7"
FX tag example/beta v2.3 "$D3"; PKG_COMMIT="$D2" build "$T/f-b23" org.example.Beta v2.3 "$D3" beta-23
FX file example/beta packaging/flatpak/org.example.Beta.json "$D2" "$T/f-b23/pkg-manifest.json"
FX run example/beta '{"id": 604, "app_id": "org.example.Beta", "event": "workflow_dispatch", "head_branch": "main", "head_sha": "'"$D2"'", "display_title": "Flatpak v2.3", "created_at": "2026-11-03T10:00:00Z"}' "$T/f-b23"
FX compare example/beta "$D3" "$MAINHEAD" diverged
expect_fail "validate: dispatch building a tag that is not on the branch refused" "v2.3 ($D3) is not on main" vs --app-id org.example.Beta --source-repo example/beta --tag v2.3 --run-id 604 --out "$T/va8"
rm -f "$GH_FIXTURES/$(printf 'repos/example/beta/branches/main' | sed 's/[^A-Za-z0-9]/_/g')"
expect_fail "validate: unresolvable allowlisted branch fails closed" "cannot resolve branch main" vs --app-id org.example.Beta --source-repo example/beta --tag v2.2 --run-id 602 --out "$T/va9"
FX branch example/beta main "$MAINHEAD" unprotected
expect_ok "validate: unprotected branch still checked by ancestry (protection recorded)" vs --app-id org.example.Beta --source-repo example/beta --tag v2.2 --run-id 602 --out "$T/va10"
jq -e '.dispatch_branch_protected == false' "$T/va10/RUN.json" >/dev/null && ok "validate: branch protection state recorded" || bad "branch protection not recorded"
python3 -I "$root/tests/check-workflow-modes.py" "$root" >"$T/last.log" 2>&1 && ok "workflows: directly run scripts are executable with a shebang" || { bad "workflow script modes"; cat "$T/last.log"; }
mkdir -p "$T/wm/.github/workflows" "$T/wm/p"; printf '#!/bin/bash\n' >"$T/wm/p/ci.sh"; chmod 644 "$T/wm/p/ci.sh"
printf '      - run: src/p/ci.sh\n' >"$T/wm/.github/workflows/w.yml"
expect_fail "workflows: a mode 0644 script run directly is caught" "mode 0644" python3 -I "$root/tests/check-workflow-modes.py" "$T/wm" --strip-prefix src/

# Signing several builds in order on the ledger-matched base; other apps' refs kept.
beta_before="$(ostree --repo="$T/live/repo" rev-parse app/org.example.Beta/x86_64/stable)"
expect_ok "sign-all: builds of two apps added in plan order" bash -c "
    export FLATPAK_GPG_PRIVATE_KEY=\"\$1\" FLATPAK_GPG_PASSPHRASE=\"\$2\" FLATPAK_GPG_FINGERPRINT=\"\$3\"
    source '$root/scripts/lib.sh'; source '$root/scripts/gpg-setup.sh'; gpg_setup
    '$root/scripts/fetch-published.sh' --out '$T/sa-base' --expect-summary-sha256 '$(live_sha)' &&
    '$root/scripts/sign-all.sh' --validated '$T/validated' --base '$T/sa-base' --site '$T/sa-site' --state-out '$T/sa-state'" _ "$ARMORED" "$PASS" "$FPR"
[[ "$(jq -r '."app/org.example.Alpha/x86_64/stable".tag + " " + ."app/org.example.Beta/x86_64/stable".tag' "$T/sa-state/refs.json")" == "v1.2 v2.1" ]] \
    && [[ "$(ostree --repo="$T/sa-site/repo" rev-parse app/org.example.Beta/x86_64/stable^)" == "$beta_before" ]] \
    && ostree --repo="$T/sa-site/repo" rev-parse runtime/org.example.Alpha.Locale/x86_64/stable >/dev/null \
    && ok "sign-all: both apps updated with continuous history, Locale kept, ledger refs written" || bad "sign-all result: $(cat "$T/sa-state/refs.json" 2>/dev/null)"
ostree --repo="$T/sa-site/repo" show app/org.example.Beta/x86_64/stable | grep -q "source-branch=main@$MAINHEAD" \
    && ok "compose: resolved branch head signed into the commit body" || bad "compose does not record the branch head"

# --- Public key export (bootstrap) -----------------------------------------------------------------
grouped="$(sed 's/..../& /g' <<<"$FPR" | tr A-F a-f)"
expect_ok "key export: configured key (grouped, lower-case fingerprint) exported" env FLATPAK_GPG_PRIVATE_KEY="$ARMORED" FLATPAK_GPG_FINGERPRINT="$grouped" "$root/scripts/export-public-key.sh" --out "$T/kx"
cp "$T/last.log" "$T/kx.log"
[[ "$(cat "$T/kx/FINGERPRINT")" == "$FPR" && "$(source "$root/scripts/lib.sh"; key_file_fingerprint "$T/kx/manicminer-flatpak.gpg")" == "$FPR" ]] \
    && (cd "$T/kx" && sha256sum -c --quiet SHA256SUMS) && ok "key export: public key and fingerprint match the configured key" || bad "key export content"
if gpg --homedir "$T/keyhome" --batch --list-packets "$T/kx/manicminer-flatpak.gpg" 2>/dev/null | grep -qi secret \
    || grep -rqaF -e "PRIVATE KEY" -e "$PASS" "$T/kx" "$T/kx.log"; then bad "key export: secret material in artifact or log"; else ok "key export: no private data in the artifact or log"; fi
gpg_harden_home "$T/kxhome"; gpg --homedir "$T/kxhome" --batch --quiet --import "$T/kx/manicminer-flatpak.gpg" 2>/dev/null
[[ -z "$(gpg --homedir "$T/kxhome" --batch --list-secret-keys 2>/dev/null)" ]] && ok "key export: importing the artifact yields no secret key" || bad "key export: secret key importable"
gpgconf --homedir "$T/kxhome" --kill all >/dev/null 2>&1 || true
expect_fail "key export: other configured fingerprint refused" "not the configured" env FLATPAK_GPG_PRIVATE_KEY="$ARMORED" FLATPAK_GPG_FINGERPRINT="$ATTACKER_FPR" "$root/scripts/export-public-key.sh" --out "$T/kx2"
[[ ! -e "$T/kx2" ]] && ok "key export: nothing written on mismatch" || bad "key export wrote output on mismatch"
expect_fail "key export: secret with two keys refused" "exactly one primary key" env FLATPAK_GPG_PRIVATE_KEY="$ARMORED"$'\n'"$ATTACKER_ARMORED" FLATPAK_GPG_FINGERPRINT="$FPR" "$root/scripts/export-public-key.sh" --out "$T/kx3"
expect_fail "key export: short fingerprint refused" "full 40-digit" env FLATPAK_GPG_PRIVATE_KEY="$ARMORED" FLATPAK_GPG_FINGERPRINT="${FPR:24}" "$root/scripts/export-public-key.sh" --out "$T/kx4"
[[ -z "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'publisher-gnupg.*' -user "$(id -u)" 2>/dev/null)" ]] && ok "key export: temporary GNUPGHOME removed" || bad "key export left GNUPGHOME"

# Size ceiling.
python3 -I -c 'import json,sys; c=json.load(open(sys.argv[1])); c["site_limit_bytes"]=1000; json.dump(c,open(sys.argv[1],"w"))' "$PUBLISHER_CONFIG"
build "$T/a3" org.example.Alpha v1.3 "$C3" alpha-3
expect_fail "site over the size limit refused" "over the limit" publish big org.example.Alpha v1.3 "$C3" "$T/a3"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
