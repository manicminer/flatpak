#!/usr/bin/env bash
# SPDX-License-Identifier: CC0-1.0
#
# One-time bootstrap: derives the PUBLIC half of the configured signing key, for review and commit
# as keys/manicminer-flatpak.gpg + keys/FINGERPRINT. Needs no pinned key (that is what it makes)
# and no passphrase. Publishes, signs and commits nothing.
#
#   export-public-key.sh --out DIR
#
# Environment: FLATPAK_GPG_PRIVATE_KEY (secret), FLATPAK_GPG_FINGERPRINT (variable; grouped
# display form accepted). The secret key lives only in a temporary GNUPGHOME, removed on exit.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

out=""
while (($#)); do
    case "$1" in
        --out) out="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[[ -n "$out" && ! -e "$out" ]] || die "--out must name a new directory"
[[ -n "${FLATPAK_GPG_PRIVATE_KEY:-}" ]] || die "FLATPAK_GPG_PRIVATE_KEY is not set"
want="$(normalize_fingerprint "${FLATPAK_GPG_FINGERPRINT:-}")" \
    || die "FLATPAK_GPG_FINGERPRINT must be the full 40-digit fingerprint (spaces allowed)"

GNUPGHOME="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/publisher-gnupg.XXXXXXXX")"
export GNUPGHOME
cleanup() {
    gpgconf --homedir "$GNUPGHOME" --kill all >/dev/null 2>&1 || true
    rm -rf "$GNUPGHOME"
}
trap cleanup EXIT
gpg_harden_home "$GNUPGHOME"
printenv FLATPAK_GPG_PRIVATE_KEY | gpg --batch --pinentry-mode error --quiet --import 2>/dev/null || die "importing the key failed"
unset FLATPAK_GPG_PRIVATE_KEY

# Exactly one key, and it is the configured one: nothing else is ever exported or trusted.
mapfile -t prim < <(gpg --batch --with-colons --list-secret-keys | awk -F: '$1=="sec"{s=1;next} s&&$1=="fpr"{print $10; s=0}')
[[ "${#prim[@]}" == 1 ]] || die "FLATPAK_GPG_PRIVATE_KEY must hold exactly one primary key, it holds ${#prim[@]}"
[[ "${prim[0]}" == "$want" ]] || die "the secret key is ${prim[0]}, not the configured FLATPAK_GPG_FINGERPRINT $want"
algo="$(gpg --batch --with-colons --list-secret-keys "$want" | awk -F: '$1=="sec"{print $4; exit}')"
[[ "$algo" == 1 ]] || die "the signing key is not an RSA key"

stage="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pubkey.XXXXXXXX")"
trap 'cleanup; rm -rf "$stage"' EXIT
gpg --batch --export-options export-minimal --export "$want" >"$stage/manicminer-flatpak.gpg"
# The file must be a public key only: no secret packets, exactly the configured key.
if gpg --batch --list-packets "$stage/manicminer-flatpak.gpg" 2>/dev/null | grep -qi 'secret'; then
    die "export contains secret key packets"
fi
[[ "$(key_file_fingerprint "$stage/manicminer-flatpak.gpg")" == "$want" ]] || die "exported key is not $want"
printf '%s\n' "$want" >"$stage/FINGERPRINT"
(cd "$stage" && sha256sum manicminer-flatpak.gpg FINGERPRINT >SHA256SUMS)
mkdir -p "$out"
cp "$stage/manicminer-flatpak.gpg" "$stage/FINGERPRINT" "$stage/SHA256SUMS" "$out/"
note "exported the public key $want"
