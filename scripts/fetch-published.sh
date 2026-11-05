#!/usr/bin/env bash
# SPDX-License-Identifier: CC0-1.0
#
# Fetches the currently published repository, verified with the PINNED key only, as the base of
# the next publication: all refs of all apps, with up to prune_depth commits of history each.
#
#   fetch-published.sh --out DIR (--expect-summary-sha256 HEX | --bootstrap) [--url URL]
#
# The fetched summary must have exactly the digest the ledger recorded as deployed (ledger.py), so
# a stale CDN copy or older snapshot is never a base. A repository that does not exist yet (HTTP
# 404) is only accepted with --bootstrap.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

out="" url="" bootstrap=0 expect=""
while (($#)); do
    case "$1" in
        --out) out="$2"; shift 2 ;;
        --url) url="$2"; shift 2 ;;
        --bootstrap) bootstrap=1; shift ;;
        --expect-summary-sha256) expect="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
url="${url:-$(config repo_url)}"
depth="$(config prune_depth)"
[[ -n "$out" && ! -e "$out" ]] || die "--out must name a new directory"
((bootstrap)) || [[ "$expect" =~ ^[0-9a-f]{64}$ ]] || die "--expect-summary-sha256 (from the ledger) is required"
check_pinned_key

ostree init --mode=archive-z2 --repo="$out"

exists=1
case "$url" in
    file://*)
        [[ -f "${url#file://}/summary" ]] || exists=0 ;;
    https://*)
        code="$(curl -sS -o /dev/null -w '%{http_code}' --proto '=https' --max-time 60 "${url%/}/summary")" || die "cannot reach $url"
        case "$code" in
            200) ;;
            404) exists=0 ;;
            *) die "unexpected HTTP $code for ${url%/}/summary" ;;
        esac ;;
    *) die "repository URL must be https:// (or file:// in tests)" ;;
esac
if ((exists == 0)); then
    ((bootstrap)) || die "no published repository at $url; only a run with bootstrap=true may start an empty one"
    note "bootstrap: starting an empty repository"
    exit 0
fi
((bootstrap == 0)) || die "bootstrap requested, but a repository is already published at $url"

ostree --repo="$out" remote add --gpg-import="$PINNED_KEY" \
    --set=gpg-verify=true --set=gpg-verify-summary=true published "$url"
# Every ref of the signed summary, commits verified against the pinned key. Mirroring all refs
# keeps the exact summary the pull used, so its digest binds the refs to the ledger.
ostree --repo="$out" pull --mirror --depth="$depth" published
ostree --repo="$out" remote delete published
got="$(sha256sum "$out/summary" | cut -d' ' -f1)"
[[ "$got" == "$expect" ]] || die "published summary is $got, the ledger expects $expect (stale CDN copy or not the last deployment)"
mapfile -t refs < <(ostree --repo="$out" refs | sort)
((${#refs[@]})) || die "published repository lists no refs"
note "fetched ${#refs[@]} refs from $url"
