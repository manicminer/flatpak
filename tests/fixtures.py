#!/usr/bin/env python3
# SPDX-License-Identifier: CC0-1.0
"""Writes GitHub REST API fixtures for tests/fake-gh (no live API is ever used).

  fixtures.py FIXDIR repo REPO [private]
  fixtures.py FIXDIR tag REPO TAG COMMIT
  fixtures.py FIXDIR file REPO PATH REF CONTENT_FILE
  fixtures.py FIXDIR run REPO JSON BUILD_DIR [bad-digest]   one run with its artifact
  fixtures.py FIXDIR runs REPO WORKFLOW_FILE SINCE PAGE JSON_LIST
  fixtures.py FIXDIR branch REPO BRANCH SHA [unprotected]
  fixtures.py FIXDIR compare REPO BASE HEAD STATUS     STATUS: identical|ahead|behind|diverged
"""
import base64, hashlib, io, json, os, re, sys, zipfile


def put(fix, path, data):
    with open(os.path.join(fix, re.sub(r"[^A-Za-z0-9]", "_", path)), "wb") as f:
        f.write(data if isinstance(data, bytes) else json.dumps(data).encode())


def run_record(repo, spec):
    r = {"id": spec["id"], "path": spec.get("path", ".github/workflows/flatpak.yml"), "event": spec["event"],
         "status": "completed", "conclusion": spec.get("conclusion", "success"), "head_branch": spec["head_branch"],
         "head_sha": spec["head_sha"], "display_title": spec.get("display_title", "Flatpak"), "run_attempt": 1,
         "created_at": spec["created_at"], "repository": {"full_name": repo}, "head_repository": {"full_name": repo}}
    return r


def main():
    fix, cmd, repo, *rest = sys.argv[1:]
    if cmd == "repo":
        private = bool(rest and rest[0] == "private")
        put(fix, f"repos/{repo}", {"full_name": repo, "private": private, "visibility": "private" if private else "public"})
    elif cmd == "tag":
        tag, commit = rest
        put(fix, f"repos/{repo}/git/ref/tags/{tag}", {"ref": f"refs/tags/{tag}", "object": {"type": "commit", "sha": commit}})
    elif cmd == "file":
        path, ref, content = rest
        data = open(content, "rb").read()
        put(fix, f"repos/{repo}/contents/{path}?ref={ref}", {"type": "file", "encoding": "base64", "content": base64.encodebytes(data).decode()})
    elif cmd == "run":
        spec, bdir = json.loads(rest[0]), rest[1]
        put(fix, f"repos/{repo}/actions/runs/{spec['id']}", run_record(repo, spec))
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            for n in ("SOURCE.json", "repo.tar"):
                z.write(os.path.join(bdir, n), n)
        data = buf.getvalue()
        digest = hashlib.sha256(b"x" if rest[2:] == ["bad-digest"] else data).hexdigest()
        aid = spec["id"] * 10
        name = spec.get("artifact", "flatpak-%s-x86_64" % spec["app_id"])
        put(fix, f"repos/{repo}/actions/runs/{spec['id']}/artifacts?name={name}&per_page=100",
            {"artifacts": [{"id": aid, "name": name, "expired": False, "digest": "sha256:" + digest, "size_in_bytes": len(data)}]})
        put(fix, f"repos/{repo}/actions/artifacts/{aid}/zip", data)
    elif cmd == "branch":
        branch, sha = rest[:2]
        put(fix, f"repos/{repo}/branches/{branch}", {"name": branch, "commit": {"sha": sha}, "protected": rest[2:] != ["unprotected"]})
    elif cmd == "compare":
        base, head, status = rest
        ahead, behind = {"identical": (0, 0), "ahead": (3, 0), "behind": (0, 2), "diverged": (3, 2)}[status]
        merge_base = base if status in ("identical", "ahead") else ("9" * 40 if status == "diverged" else head)
        put(fix, f"repos/{repo}/compare/{base}...{head}?per_page=1",
            {"status": status, "ahead_by": ahead, "behind_by": behind, "base_commit": {"sha": base},
             "merge_base_commit": {"sha": merge_base}, "commits": []})
    elif cmd == "runs":
        wf, since, page, specs = rest
        runs = [run_record(repo, s) for s in json.loads(specs)]
        put(fix, f"repos/{repo}/actions/workflows/{wf}/runs?status=success&created=%3E%3D{since}&per_page=100&page={page}",
            {"total_count": len(runs), "workflow_runs": runs})


if __name__ == "__main__":
    main()
