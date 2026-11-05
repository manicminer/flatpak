#!/usr/bin/env bash
# SPDX-License-Identifier: CC0-1.0
#
# Publishes a REAL app build directory (SOURCE.json + repo.tar from an app's packaging) with an
# EPHEMERAL key into a local site, then installs it from that site with signature verification
# into a SCRATCH Flatpak installation. Offline apart from the runtime already installed there.
#
#   FLATPAK_USER_DIR=<scratch> integration-real-build.sh BUILD_DIR APP_ID TAG COMMIT
# Runs isolated (tests/isolate.sh); key operations never prompt (README: tests).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISOLATE_KEEP=FLATPAK_USER_DIR source "$root/tests/isolate.sh"
source "$root/scripts/lib.sh"
bdir="$1" app="$2" tag="$3" commit="$4"
[[ -n "${FLATPAK_USER_DIR:-}" && "$FLATPAK_USER_DIR" != */.local/share/flatpak ]] || { echo "scratch FLATPAK_USER_DIR required" >&2; exit 1; }
T="$(mktemp -d)"
trap 'gpgconf --homedir "$T/k" --kill all >/dev/null 2>&1 || true; flatpak --user uninstall -y --noninteractive "$app//stable" >/dev/null 2>&1 || true; flatpak --user remote-delete --force itest >/dev/null 2>&1 || true; rm -rf "$T"' EXIT
gpg_harden_home "$T/k"
PASS="itest-$RANDOM$RANDOM"
gpg --homedir "$T/k" --batch --quiet --passphrase "$PASS" --pinentry-mode loopback --quick-generate-key "Integration <i@example.org>" rsa3072 sign 1d 2>/dev/null
FPR="$(gpg --homedir "$T/k" --batch --with-colons --list-keys | awk -F: '$1=="fpr"{print $10; exit}')"
mkdir "$T/keys"; gpg --homedir "$T/k" --batch --export "$FPR" >"$T/keys/pub.gpg"; echo "$FPR" >"$T/keys/FINGERPRINT"
export PUBLISHER_PINNED_KEY="$T/keys/pub.gpg" PUBLISHER_PINNED_FINGERPRINT="$T/keys/FINGERPRINT" PUBLISHER_CONFIG="$T/config.json"
sed "s|\"repo_url\": \"[^\"]*\"|\"repo_url\": \"file://$T/site/repo\"|" "$root/config.json" >"$PUBLISHER_CONFIG"
arch=x86_64
"$root/scripts/verify-import.sh" --dir "$bdir" --app-id "$app" --tag "$tag" --commit "$commit" --arch "$arch" --out "$T/import"
"$root/scripts/fetch-published.sh" --out "$T/base" --url "file://$T/nonexistent" --bootstrap
(
    export FLATPAK_GPG_PRIVATE_KEY="$(gpg --homedir "$T/k" --batch --pinentry-mode loopback --passphrase "$PASS" --armor --export-secret-keys "$FPR")"
    export FLATPAK_GPG_PASSPHRASE="$PASS" FLATPAK_GPG_FINGERPRINT="$FPR"
    source "$root/scripts/lib.sh"; source "$root/scripts/gpg-setup.sh"
    gpg_setup
    unset FLATPAK_GPG_PRIVATE_KEY FLATPAK_GPG_PASSPHRASE
    jq -n --arg r "$(app_field "$app" source_repo)" --slurpfile s "$bdir/SOURCE.json" '{source_repo: $r, run_id: 0, run_attempt: 1, event: "local", created_at: "1970-01-01T00:00:00Z",
        tag: $s[0].source_tag, commit: $s[0].source_commit, packaging_commit: $s[0].packaging_commit}' >"$T/RUN.json"
    "$root/scripts/compose.sh" --base "$T/base" --import "$T/import" --source-json "$bdir/SOURCE.json" --run-json "$T/RUN.json" --site "$T/site"
)
# Install as a user would from the .flatpakrepo (Url rewritten to the local site), signature checked.
sed "s|^Url=.*|Url=file://$T/site/repo|" "$T/site/manicminer.flatpakrepo" >"$T/local.flatpakrepo"
flatpak --user remote-add --if-not-exists itest "$T/local.flatpakrepo"
flatpak --user remote-ls itest --columns=ref
flatpak --user install -y --noninteractive itest "$app//stable" >/dev/null
flatpak --user info "$app//stable" | grep -E 'Ref|Commit|Subject|Origin'
flatpak --user run --command=sh "$app//stable" -c 'test -x /app/bin/krdc && command -v krdc-avd-signin-handler >/dev/null && echo binaries-present'
echo "integration: published with an ephemeral key, installed with signature verification: OK"
