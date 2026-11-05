#!/usr/bin/env bash
# SPDX-License-Identifier: CC0-1.0
#
# Sourced by the signing step. Imports the signing key from the environment into a new private
# GNUPGHOME (0700), checks it is the pinned key, and seeds gpg-agent with the passphrase so
# OSTree/Flatpak can sign without a terminal. Sets GNUPGHOME and SIGNING_FPR; registers cleanup.
#
# Environment (secrets): FLATPAK_GPG_PRIVATE_KEY (ASCII-armored secret key), FLATPAK_GPG_PASSPHRASE
# Environment (variable): FLATPAK_GPG_FINGERPRINT (40 hex digits; grouped display form accepted)
# The key and passphrase are never echoed, written to the log or exported; the secret material
# only lives in the temporary GNUPGHOME and the agent, both removed on exit.
# shellcheck shell=bash

gpg_cleanup() {
    if [[ -n "${GNUPGHOME:-}" && -d "$GNUPGHOME" ]]; then
        gpgconf --homedir "$GNUPGHOME" --kill all >/dev/null 2>&1 || true
        rm -rf "$GNUPGHOME"
    fi
}

gpg_setup() {
    local fpr_var want
    [[ -n "${FLATPAK_GPG_PRIVATE_KEY:-}" ]] || die "FLATPAK_GPG_PRIVATE_KEY is not set; refusing to publish unsigned"
    [[ -n "${FLATPAK_GPG_PASSPHRASE:-}" ]] || die "FLATPAK_GPG_PASSPHRASE is not set"
    fpr_var="$(normalize_fingerprint "${FLATPAK_GPG_FINGERPRINT:-}")" \
        || die "FLATPAK_GPG_FINGERPRINT must be the full 40-digit fingerprint (spaces allowed)"
    want="$(pinned_fingerprint)"
    [[ "$fpr_var" == "$want" ]] || die "FLATPAK_GPG_FINGERPRINT does not match keys/FINGERPRINT"
    check_pinned_key

    GNUPGHOME="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/publisher-gnupg.XXXXXXXX")"
    export GNUPGHOME
    trap gpg_cleanup EXIT
    gpg_harden_home "$GNUPGHOME" $'allow-preset-passphrase\ndefault-cache-ttl 7200\nmax-cache-ttl 7200\n'

    # Only the secret key, via a pipe from the environment: no file, no argument, no trace.
    if ! printenv FLATPAK_GPG_PRIVATE_KEY | gpg --batch --pinentry-mode error --quiet --import 2>/dev/null; then
        die "importing the signing key failed"
    fi
    local secret_fprs
    secret_fprs="$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1=="sec"{s=1;next} s&&$1=="fpr"{print $10; s=0}')"
    [[ "$secret_fprs" == "$want" ]] || die "the imported secret key is not (only) the pinned key"
    local algo
    algo="$(gpg --batch --with-colons --list-secret-keys "$want" | awk -F: '$1=="sec"{print $4; exit}')"
    [[ "$algo" == 1 ]] || die "the signing key is not an RSA key"

    # Seed the agent with the passphrase for every signing-capable key grip of the key.
    local preset grips grip
    preset="$(gpgconf --list-dirs libexecdir)/gpg-preset-passphrase"
    [[ -x "$preset" ]] || die "gpg-preset-passphrase not found"
    gpg-connect-agent /bye >/dev/null 2>&1
    grips="$(gpg --batch --with-colons --with-keygrip --list-secret-keys "$want" | awk -F: '$1=="grp"{print $10}')"
    [[ -n "$grips" ]] || die "no key grips"
    for grip in $grips; do
        printenv FLATPAK_GPG_PASSPHRASE | "$preset" --preset "$grip" || die "seeding the passphrase failed"
    done
    # Prove signing works without a prompt before touching the repository.
    if ! printf 'probe' | gpg --batch --pinentry-mode error --local-user "$want" --detach-sign -o /dev/null 2>/dev/null; then
        die "signing with the key failed (wrong passphrase?)"
    fi
    SIGNING_FPR="$want"
    export SIGNING_FPR
}
