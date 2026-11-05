#!/usr/bin/env python3
# SPDX-License-Identifier: CC0-1.0
"""Lists successful builds of every allowlisted app that are newer than what is published, oldest
first: all pages of runs of the allowlisted workflow within discovery_days (the artifact retention
of app repositories), so runs that a sweep missed, or that failed to publish, come again.

  discover.py --apps F --config F --published F [--today YYYY-MM-DD]

--published: JSON {app_id: published tag}. Prints TSV: created_at run_id app_id source_repo tag.
Uses `gh api` (tests put a fixture-serving gh first on PATH). Validation happens afterwards."""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys


def api(path):
    r = subprocess.run(["gh", "api", "-H", "Accept: application/vnd.github+json", path], capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"discover: GET {path} failed: {r.stderr.strip()[:300]}")
    return json.loads(r.stdout)


def newer(old, new):
    """Same order as lib.sh tag_is_newer (sort -V)."""
    if not old:
        return True
    if old == new:
        return False
    out = subprocess.run(["sort", "-V"], input=f"{old}\n{new}\n", capture_output=True, text=True, check=True).stdout
    return out.splitlines()[-1] == new


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--apps", required=True)
    p.add_argument("--config", required=True)
    p.add_argument("--published", required=True)
    p.add_argument("--today", default=datetime.date.today().isoformat())
    a = p.parse_args()
    apps = json.load(open(a.apps))["apps"]
    cfg = json.load(open(a.config))
    published = json.load(open(a.published))
    since = (datetime.date.fromisoformat(a.today) - datetime.timedelta(days=int(cfg["discovery_days"]))).isoformat()
    found = []
    for app_id, app in sorted(apps.items()):
        repo, path = app["source_repo"], app["workflow_path"]
        tag_re = re.compile(app["tag_regex"])
        page = 1
        while True:
            data = api(f"repos/{repo}/actions/workflows/{os.path.basename(path)}/runs"
                       f"?status=success&created=%3E%3D{since}&per_page=100&page={page}")
            runs = data.get("workflow_runs", [])
            for r in runs:
                if r.get("path") != path or r.get("repository", {}).get("full_name") != repo or r.get("conclusion") != "success":
                    continue
                if r.get("event") == "push":
                    tag = r.get("head_branch", "")
                elif r.get("event") == "workflow_dispatch" and r.get("head_branch") == app["dispatch_branch"]:
                    tag = (r.get("display_title") or "").removeprefix("Flatpak ")
                else:
                    continue
                if len(tag) > 100 or not tag_re.search(tag) or not newer(published.get(app_id, ""), tag):
                    continue
                found.append((r["created_at"], int(r["id"]), app_id, repo, tag))
            if len(runs) < 100:
                break
            page += 1
            if page > 50:
                sys.exit(f"discover: more than 5000 runs of {repo}; lower discovery_days")
    for row in sorted(found):
        print("\t".join(map(str, row)))


if __name__ == "__main__":
    main()
