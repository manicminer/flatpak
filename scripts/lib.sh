# SPDX-License-Identifier: CC0-1.0
# shellcheck shell=bash
# Shared by the publisher scripts; sourced, not run.

die() {
    printf '%s: error: %s\n' "${0##*/}" "$*" >&2
    exit 1
}

note() {
    printf '%s: %s\n' "${0##*/}" "$*" >&2
}

PUBLISHER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${PUBLISHER_CONFIG:-$PUBLISHER_ROOT/config.json}"
APPS="${PUBLISHER_APPS:-$PUBLISHER_ROOT/apps.json}"

config() {
    python3 -I -c 'import json,sys; v=json.load(open(sys.argv[1]))[sys.argv[2]]; print(v)' "$CONFIG" "$1"
}

# The pinned public key: committed to this repository, never taken from the live site.
PINNED_KEY="${PUBLISHER_PINNED_KEY:-$PUBLISHER_ROOT/keys/manicminer-flatpak.gpg}"
PINNED_FINGERPRINT_FILE="${PUBLISHER_PINNED_FINGERPRINT:-$PUBLISHER_ROOT/keys/FINGERPRINT}"

# A fingerprint as GitHub variables may hold it: grouped display form ("ABCD 1234 …"), any case.
normalize_fingerprint() {
    local f
    f="$(tr -d '[:space:]' <<<"$1" | tr a-f A-F)"
    [[ "$f" =~ ^[0-9A-F]{40}$ ]] || return 1
    printf '%s\n' "$f"
}

pinned_fingerprint() {
    [[ -s "$PINNED_FINGERPRINT_FILE" ]] || die "no pinned fingerprint in $PINNED_FINGERPRINT_FILE (see README: signing key setup)"
    local fpr
    fpr="$(normalize_fingerprint "$(cat "$PINNED_FINGERPRINT_FILE")")" || die "pinned fingerprint must be 40 hex digits"
    printf '%s\n' "$fpr"
}

# Makes DIR a private GNUPGHOME that can never prompt: a passphrase request the agent cannot answer
# from its cache fails closed instead of opening a pinentry. EXTRA is appended to gpg-agent.conf.
gpg_harden_home() { # DIR [EXTRA]
    mkdir -p "$1"
    chmod 700 "$1"
    printf 'pinentry-program /usr/bin/false\n%s' "${2:-}" >"$1/gpg-agent.conf"
    printf 'batch\nno-tty\nno-greeting\nno-permission-warning\n' >"$1/gpg.conf"
}

# The fingerprint of the single primary key in a binary or armored public key file.
key_file_fingerprint() {
    local home out
    home="$(mktemp -d)"
    gpg_harden_home "$home"
    out="$(gpg --homedir "$home" --batch --with-colons --import-options show-only --import "$1" 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
    local count
    count="$(gpg --homedir "$home" --batch --with-colons --import-options show-only --import "$1" 2>/dev/null | grep -c '^pub:' || true)"
    rm -rf "$home"
    [[ "$count" == 1 ]] || die "$1 must contain exactly one public key"
    printf '%s\n' "$out"
}

check_pinned_key() {
    local want got
    want="$(pinned_fingerprint)"
    [[ -s "$PINNED_KEY" ]] || die "no pinned public key at $PINNED_KEY (see README: signing key setup)"
    got="$(key_file_fingerprint "$PINNED_KEY")"
    [[ "$got" == "$want" ]] || die "pinned key file is $got, pinned fingerprint is $want"
}

# Apps allowlist lookups: app_field APP_ID FIELD
app_field() {
    python3 -I - "$APPS" "$1" "$2" <<'EOF'
import json, sys
apps = json.load(open(sys.argv[1]))["apps"]
app = apps.get(sys.argv[2])
if app is None:
    sys.exit(f"app {sys.argv[2]!r} is not in the allowlist")
v = app[sys.argv[3]]
print("\n".join(v) if isinstance(v, list) else v)
EOF
}

validate_app_id() {
    [[ "${#1}" -le 255 && "$1" =~ ^[A-Za-z_][A-Za-z0-9_-]*(\.[A-Za-z_][A-Za-z0-9_-]*){2,}$ ]]
}

# Version order of two release tags of one app: succeeds if $2 is newer than $1.
tag_is_newer() {
    [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$2" ]]
}

# A GitHub API GET (gh api); tests put a fixture-serving gh first on PATH.
api() {
    gh api -H 'Accept: application/vnd.github+json' "$1"
}
