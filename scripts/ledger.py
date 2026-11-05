#!/usr/bin/env python3
# SPDX-License-Identifier: CC0-1.0
"""The publisher's deployment ledger (state.json on the publisher-state branch, see README.md).

It records the digest of the summary the publisher last deployed, and, from before a deployment
starts until it is confirmed, the digest it is deploying ("pending"). The next run only builds on
a live repository whose summary has exactly the recorded digest, so a stale CDN copy or an older
snapshot can never become the base; an unconfirmed deployment blocks until the live site shows it
or the owner reconciles explicitly. It holds digests, refs and build identities only, no secrets.

  ledger.py decide  --state F --live HEX|none [--bootstrap] [--reconcile] [--accept HEX]
  ledger.py pending --state F --summary HEX --refs F --builds F --run ID [--update KIND --live HEX]
  ledger.py deployed --state F --summary HEX
  ledger.py update  --state F --update KIND --live HEX
  ledger.py published --state F --update KIND --live HEX   {app_id: tag} the base has

--state names a file that may not exist (no ledger yet). New states are written to stdout.
"""
import argparse
import json
import os
import re
import sys

HEX = re.compile(r"[0-9a-f]{64}")
# The deployed digest of a ledger whose first publication never went live: the empty site (no
# summary, HTTP 404). Not a real summary digest; recovery from it starts an empty repository again.
EMPTY = "0" * 64
REF = re.compile(r"(app|runtime)/[A-Za-z0-9_.-]{1,255}/[A-Za-z0-9_]{1,32}/[A-Za-z0-9_.-]{1,64}")


def fail(msg):
    sys.exit(f"ledger: {msg}")


def load(path):
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        s = json.load(f)
    if s.get("format") != 1 or not HEX.fullmatch(str(s.get("deployed", {}).get("summary_sha256", ""))):
        fail("state.json is malformed; reconcile by hand (README: recovery)")
    if s.get("pending") is not None and not HEX.fullmatch(str(s["pending"].get("summary_sha256", ""))):
        fail("state.json pending entry is malformed")
    if s["deployed"]["summary_sha256"] == EMPTY and s["deployed"].get("refs"):
        fail("state.json: the empty site has refs")
    return s


def site(live):
    """The live summary as the ledger records it: an absent site is the empty-site marker."""
    return EMPTY if live == "none" else live


def digest(v, what):
    if not HEX.fullmatch(v or ""):
        fail(f"{what} must be a SHA-256 hex digest")
    return v


def decide(a):
    """What this run may do. Prints {action, base, update}: action publish|block, base the summary
    digest the base must have ("" = empty bootstrap repository), update the ledger change to
    record (none|confirm|abandon|accept)."""
    s = load(a.state)
    live = a.live
    if live != "none":
        digest(live, "--live")
    accept = digest(a.accept, "--accept") if a.accept else ""

    def out(action, base="", update="none", why=""):
        print(json.dumps({"action": action, "base": base, "update": update, "reason": why}))

    if a.bootstrap:
        if live != "none":
            return out("block", why="bootstrap refused: a live repository exists")
        if s is None:
            return out("publish", why="bootstrap of an empty repository")
        if s["deployed"]["summary_sha256"] != EMPTY:
            return out("block", why="bootstrap refused: the ledger records a deployed repository (its site is gone: accept or restore it by hand)")
        # The first publication never went live and the site is still absent: start it again.
        return out("publish", update="abandon" if s.get("pending") else "none",
                   why="bootstrap retry: the first deployment never went live")
    if accept:
        if live != accept:
            return out("block", why=f"the live summary is {live}, not the digest to accept {accept}")
        return out("publish", base=live, update="accept", why="owner accepted the live summary")
    if s is None:
        return out("block", why="no ledger: bootstrap, or reconcile with accept_summary_sha256 (README: recovery)")
    deployed, pending = s["deployed"]["summary_sha256"], s.get("pending")
    base = "" if deployed == EMPTY else deployed  # "" = an empty (bootstrap) base
    if pending is None:
        if site(live) == deployed:
            return out("publish", base=base)
        return out("block", why=f"the live summary is {live}, the ledger says {deployed}: CDN not current yet, or the site was changed outside the publisher")
    if live == pending["summary_sha256"]:
        return out("publish", base=live, update="confirm", why="the pending deployment is live")
    if site(live) == deployed and a.reconcile:
        return out("publish", base=base, update="abandon", why="owner reconciled: the pending deployment never went live")
    return out("block", why=f"deployment of {pending['summary_sha256']} unconfirmed (live: {live}); "
                           "wait for it, or check and run Publish with reconcile=true (README: recovery)")


def updated(s, kind, live):
    """The ledger after a decided update, before anything new is deployed."""
    if kind == "none":
        if s is None:
            return None
        return s
    if kind == "confirm":
        p = s["pending"]
        if live != p["summary_sha256"]:
            fail("confirm: live summary is not the pending one")
        return {"format": 1, "deployed": p, "pending": None}
    if kind == "abandon":
        if site(live) != s["deployed"]["summary_sha256"]:
            fail("abandon: live summary is not the deployed one")
        return {"format": 1, "deployed": s["deployed"], "pending": None}
    if kind == "accept":
        return {"format": 1, "deployed": {"summary_sha256": digest(live, "--live"), "refs": {}, "builds": [],
                                          "publisher_run": "accepted by the owner"}, "pending": None}
    fail(f"unknown update {kind}")


def read_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("cmd", choices=["decide", "pending", "deployed", "update", "published"])
    p.add_argument("--state", required=True)
    p.add_argument("--live", default="none")
    p.add_argument("--bootstrap", action="store_true")
    p.add_argument("--reconcile", action="store_true")
    p.add_argument("--accept", default="")
    p.add_argument("--summary", default="")
    p.add_argument("--refs")
    p.add_argument("--builds")
    p.add_argument("--run", default="")
    p.add_argument("--update", default="none")
    a = p.parse_args()

    if a.cmd == "decide":
        return decide(a)
    s = load(a.state)
    if a.cmd == "published":
        s = updated(s, a.update, a.live)
        refs = (s or {}).get("deployed", {}).get("refs", {})
        print(json.dumps({r.split("/")[1]: v["tag"] for r, v in refs.items() if r.startswith("app/") and v.get("tag")}))
        return
    if a.cmd == "update":
        s = updated(s, a.update, a.live)
    elif a.cmd == "pending":
        s = updated(s, a.update, a.live)
        if s is not None and s.get("pending") is not None:
            fail("a deployment is already pending")
        refs = read_json(a.refs)
        if not isinstance(refs, dict) or not refs or not all(
                REF.fullmatch(r) and HEX.fullmatch(str(v.get("commit", ""))) for r, v in refs.items()):
            fail("refs must map refs to commits")
        builds = read_json(a.builds)
        if not isinstance(builds, list):
            fail("builds must be a list")
        if not re.fullmatch(r"[0-9]{1,20}/[0-9]{1,6}", a.run):
            fail("--run must be RUN_ID/ATTEMPT")
        if digest(a.summary, "--summary") == EMPTY:
            fail("the empty-site marker is not a summary digest")
        entry = {"summary_sha256": a.summary, "refs": refs, "builds": builds, "publisher_run": a.run}
        if s is None:  # bootstrap: nothing was deployed before
            s = {"format": 1, "deployed": {"summary_sha256": EMPTY, "refs": {}, "builds": [], "publisher_run": "none"}, "pending": entry}
        else:
            s = dict(s, pending=entry)
    elif a.cmd == "deployed":
        if s is None or s.get("pending") is None or s["pending"]["summary_sha256"] != digest(a.summary, "--summary"):
            fail("deployed: that summary is not the pending one")
        s = {"format": 1, "deployed": s["pending"], "pending": None}
    if s is None:
        fail("nothing to write")
    json.dump(s, sys.stdout, indent=1, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
