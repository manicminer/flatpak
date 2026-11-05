# SPDX-License-Identifier: CC0-1.0
# shellcheck shell=bash
# Sourced first by every test script: re-runs it with a scrubbed environment, a private HOME, XDG
# dirs, GNUPGHOME (agent without pinentry) and D-Bus session, and no display, so no test can reach
# the user's desktop, keyring or GPG home. Names in ISOLATE_KEEP pass through unchanged.
# The private TMPDIR is short (/tmp) because gpg-agent sockets live in each GNUPGHOME when there
# is no /run/user, and socket paths are limited to 108 bytes.
if [[ -z "${ISOLATED_TEST:-}" ]]; then
    _h="$(mktemp -d /tmp/t.XXXXXX)"
    mkdir -m 700 "$_h/run" "$_h/gnupg" "$_h/tmp"
    printf 'pinentry-program /usr/bin/false\n' >"$_h/gnupg/gpg-agent.conf"
    printf 'batch\nno-tty\n' >"$_h/gnupg/gpg.conf"
    _keep=()
    for _v in ${ISOLATE_KEEP:-}; do [[ -n "${!_v+x}" ]] && _keep+=("$_v=${!_v}"); done
    _rc=0
    env -i PATH="$PATH" TMPDIR="$_h/tmp" LANG=C.UTF-8 HOME="$_h" XDG_RUNTIME_DIR="$_h/run" \
        XDG_CONFIG_HOME="$_h/.config" XDG_DATA_HOME="$_h/.local/share" XDG_CACHE_HOME="$_h/.cache" \
        GNUPGHOME="$_h/gnupg" QT_QPA_PLATFORM=offscreen ISOLATED_TEST=1 "${_keep[@]}" \
        dbus-run-session -- bash "$0" "$@" || _rc=$?
    gpgconf --homedir "$_h/gnupg" --kill all >/dev/null 2>&1 || true
    rm -rf "$_h"
    exit "$_rc"
fi
