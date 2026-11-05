#!/usr/bin/env bash
# SPDX-License-Identifier: CC0-1.0
#
# Reads and compare-and-swap writes state.json on the ledger branch (config state_branch).
#
#   ledger-git.sh read  --remote URL --out FILE          prints the branch head, or "none"
#   ledger-git.sh write --remote URL --expect HEAD|none --file FILE --message MSG
#                                                        prints the new head
#
# A write commits on top of exactly HEAD and pushes without force, so it fails if anyone else
# moved the branch since HEAD was read. Auth (write): GIT_TOKEN in the environment, passed to git
# as an HTTP header through GIT_CONFIG_* (never on a command line, never stored).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cmd="${1:-}"; shift || true
remote="" out="" expect="" file="" message=""
while (($#)); do
    case "$1" in
        --remote) remote="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        --expect) expect="$2"; shift 2 ;;
        --file) file="$2"; shift 2 ;;
        --message) message="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
branch="$(config state_branch)"
[[ -n "$remote" ]] || die "--remote is required"
if [[ -n "${GIT_TOKEN:-}" ]]; then
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="http.https://github.com/.extraheader"
    GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GIT_TOKEN" | base64 -w0)"
    export GIT_CONFIG_VALUE_0
fi
export GIT_TERMINAL_PROMPT=0
w="$(mktemp -d)"
trap 'rm -rf "$w"' EXIT
git -C "$w" init -q
git -C "$w" config user.name "manicminer Flatpak publisher"
git -C "$w" config user.email "publisher@users.noreply.github.com"

# "No ledger yet" only if the remote answers and lacks the branch; any failure stops.
listed="$(git -C "$w" ls-remote "$remote" "refs/heads/$branch")" || die "cannot read $remote"
head="none"
if [[ -n "$listed" ]]; then
    git -C "$w" fetch -q --depth=1 "$remote" "refs/heads/$branch" || die "cannot fetch $branch"
    head="$(git -C "$w" rev-parse FETCH_HEAD)"
fi

case "$cmd" in
    read)
        [[ -n "$out" ]] || die "--out is required"
        rm -f "$out"
        if [[ "$head" != none ]]; then
            git -C "$w" show "$head:state.json" >"$out" || die "$branch has no state.json"
        fi
        printf '%s\n' "$head" ;;
    write)
        [[ "$expect" == none || "$expect" =~ ^[0-9a-f]{40}$ ]] || die "--expect must be a commit or none"
        [[ -f "$file" && -n "$message" ]] || die "--file and --message are required"
        [[ "$head" == "$expect" ]] || die "the ledger moved: $head, expected $expect (another publisher run?)"
        blob="$(git -C "$w" hash-object -w "$file")"
        tree="$(printf '100644 blob %s\tstate.json\n' "$blob" | git -C "$w" mktree)"
        parent=(); [[ "$head" != none ]] && parent=(-p "$head")
        new="$(git -C "$w" commit-tree "$tree" "${parent[@]}" -m "$message")"
        git -C "$w" push -q "$remote" "$new:refs/heads/$branch" || die "ledger push rejected (moved concurrently?)"
        printf '%s\n' "$new" ;;
    *) die "usage: ledger-git.sh read|write ..." ;;
esac
