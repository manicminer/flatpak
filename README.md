# manicminer Flatpak repository (unofficial)

Shared, signed Flatpak repository for apps built from manicminer repositories, served by GitHub
Pages at <https://manicminer.github.io/flatpak/> (OSTree repo under `repo/`). Not Flathub.

```sh
flatpak remote-add --user --if-not-exists manicminer https://manicminer.github.io/flatpak/manicminer.flatpakrepo
```

## How publication works

1. An app repository (allowlisted in `apps.json`, **public** only) builds **unsigned**
   (`repo.tar` + `SOURCE.json` artifact) on a release-tag push, or on a dispatch on its allowlisted
   branch naming an existing tag (`run-name: Flatpak <tag>`). It never sees the signing key and
   never calls this repository.
2. `Publish` (`.github/workflows/publish.yml`) runs every 15 minutes and by hand, one run at a time
   (`concurrency: publish-pages`; runs GitHub skips or cancels are harmless, the next sweep
   recomputes everything). A tag build is normally published 15-30 minutes after it succeeds.
   - **plan** (contents/actions read, no secrets): reads the ledger (below) and the live summary
     digest and stops unless they agree; discovers all successful runs of each app's allowlisted
     workflow within `discovery_days` (= app artifact retention, 30), all pages, and keeps those
     newer than the published tag; validates them **oldest first**, at most `max_builds_per_run`
     (rest next sweep). An invalid build is skipped with a warning, never blocking other builds.
     Validation: public repository, tag → commit, run = allowlisted workflow, successful, push of
     that tag at that commit (or dispatch on the allowlisted branch), **ancestry checked by the
     publisher itself** (never trusting the source workflow's own check): the allowlisted branch is
     resolved once to its head SHA and both the tag's commit and the packaging commit must equal it
     or be its ancestors (compare API on exact SHAs; missing branch/comparison, diverged or newer
     commits are refused), one unexpired artifact with
     its digest, safe extraction, refs exactly as declared, `ostree fsck`, exactly the per-app
     approved permissions in `apps.json` (anything else, e.g. a new filesystem, socket, device or
     bus name, waits for central review), OSTree config replaced by a clean one, and build
     identity: packaging commit = the run's commit, every packaging file digest re-checked in the
     source repository at that commit, rendered manifest digest, runtime/SDK commits matching
     flatpak-builder's record in the app.
   - **sign** (environment `flatpak-signing`, contents read): fetches the live repository, verified
     with the **pinned** key in `keys/` and required to have the ledger's summary digest; key into
     a temporary 0700 GNUPGHOME (agent without pinentry), fingerprint checked against
     `keys/FINGERPRINT` and `vars.FLATPAK_GPG_FINGERPRINT` (grouped display form accepted); each
     build committed on the published parent (no downgrade, same tag+commit no-op, same tag from
     another commit refused); build identity signed into the commit body; signed summary, deltas,
     prune; fails if a published ref would be lost or the site exceeds `site_limit_bytes`.
   - **record-pending → deploy → record-deployed**: see the ledger.

## Ledger (deployment state)

Branch `publisher-state`, file `state.json`: the `deployed` summary SHA-256 with published refs
and tags, and at most one `pending` deployment. Written only by small jobs with `contents: write`
and no secrets or downloaded code, by compare-and-swap (a commit on exactly the head the run read, pushed
without force). The pending digest is recorded **before** deploying; a run whose CDN wait times out leaves
it pending. The next run then:

- live = pending → confirms it and continues;
- live = deployed (old) or anything else → **stops** (an uncertain deployment never lets an older
  snapshot become the base).

Recovery (by hand, `Publish` inputs): `reconcile=true` when the pending deployment never went live
and the live summary still equals the deployed one (drops the pending entry; its builds are
rediscovered); `accept_summary_sha256=<sha>` to accept the current live summary after checking it
(it must equal the live digest; the sign job still verifies its signature with the pinned key).
`bootstrap=true` only for the very first publication (no ledger, no live summary), or to retry it:
a first deployment that never went live leaves the ledger's deployed digest as the **empty-site
marker** (`000…0`, no refs) with the attempt pending. While the site is still absent (HTTP 404),
`bootstrap=true` or `reconcile=true` drops that pending entry and starts again from an empty
repository; if the attempt did go live it is confirmed as usual. Both are refused once a real
deployment is recorded or any other summary is live.

## One-time setup (owner)

1. Signing key, dedicated (not a personal key), generated offline; secrets
   `FLATPAK_GPG_PRIVATE_KEY` (armored), `FLATPAK_GPG_PASSPHRASE` in environment
   `flatpak-signing` (default branch only), variable `FLATPAK_GPG_FINGERPRINT`.
2. Public key from the configured secret, no re-export of the private key needed: run
   **Export public signing key** (`export-public-key.yml`, manual, same environment). It imports
   the secret only into a temporary GNUPGHOME, requires exactly one primary key equal to
   `FLATPAK_GPG_FINGERPRINT`, and uploads `manicminer-flatpak.gpg` (public, binary), `FINGERPRINT`
   and `SHA256SUMS` as an artifact. It publishes, signs and commits nothing. Review, then commit
   them as `keys/manicminer-flatpak.gpg` + `keys/FINGERPRINT` here and as
   `packaging/flatpak/manicminer-flatpak.gpg` in each app repository (release bundles).
3. In each app repository, protect the allowlisted dispatch branch (no force pushes, no deletion,
   changes by pull request). The publisher re-checks ancestry against that branch's head SHA,
   resolved at validation time and recorded as `dispatch_branch_sha` in RUN.json and
   `source-branch=<branch>@<sha>` in the signed commit body (`dispatch_branch_protected` records
   whether protection was on); a rewritten branch makes older builds unpublishable, not trusted.
4. Pages: *Settings → Pages → Source: GitHub Actions*. Actions may write the `publisher-state` branch.
5. First publication: build the first tag in the app repository, then run `Publish` with
   `bootstrap=true`.

Adding an app: an entry in `apps.json` (public source repo, workflow path, dispatch branch, tag
pattern, arches, extra refs, approved permissions).

## Tests

All offline; GitHub APIs are served from fixtures by `tests/fake-gh`. `tests/run-tests.sh`:
ephemeral keys, synthetic apps; continuity, other apps kept, downgrade/retag, key pinning,
passphrase, fingerprint, no unsigned fallback, safe extraction, permissions, ledger decisions and
CAS (including a failed or uncertain first deployment and its retry), discovery (pagination,
order, other apps), validation (including branch/tag/packaging ancestry against the resolved
branch head), key export, and `tests/check-workflow-modes.py` (scripts a workflow runs directly
are executable with a shebang). `tests/integration-real-build.sh`
publishes a real app build with an ephemeral key and installs it with signature verification
into a scratch installation.

Safety: tests run via `tests/isolate.sh` (scrubbed environment, private HOME/XDG/GNUPGHOME and
`dbus-run-session`, no display). Every test secret-key operation is `--batch --pinentry-mode
loopback` with an explicit passphrase, and every GNUPGHOME (tests and the publisher) has
`pinentry-program /usr/bin/false`, so a missed case fails instead of prompting; tests check that
signing without a passphrase fails closed. (A test pinentry once reached a desktop session.)

## Limitations

x86_64 only; no OSTree collection IDs; history depth `prune_depth` (3); Pages CDN caching may
delay updates; signing key expiry (2 years) must be extended and re-exported before it lapses
(the public key bytes then change: commit the new `keys/` file; clients get it from the next
`.flatpakrepo`/bundle, existing remotes need `flatpak remote-modify --gpg-import`).
