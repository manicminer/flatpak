#!/usr/bin/env python3
# SPDX-License-Identifier: CC0-1.0
"""Every .sh/.py script a workflow runs directly (as the command, not via bash/python3/source)
must be committed executable with a shebang, or the hosted step fails with "Permission denied".

  check-workflow-modes.py REPO_ROOT [--strip-prefix P]...   (P: a checkout path, e.g. packaging-src/)
"""
import os, re, stat, sys

CMD = re.compile(r'(?:^-?|\$\(|;|&&|\|\||\||\bthen|\bdo|\belse)\s*(?:run:\s*)?([A-Za-z0-9_./${}-]+\.(?:sh|py))(?=[\s)"]|$)')


def main():
    root, prefixes = sys.argv[1], []
    args = sys.argv[2:]
    while args:
        if args[0] != "--strip-prefix":
            sys.exit(f"unknown argument {args[0]}")
        prefixes.append(args[1]); args = args[2:]
    wfdir = os.path.join(root, ".github", "workflows")
    bad, seen = [], 0
    for wf in sorted(os.listdir(wfdir)):
        if not wf.endswith((".yml", ".yaml")):
            continue
        for n, line in enumerate(open(os.path.join(wfdir, wf), encoding="utf-8"), 1):
            if line.lstrip().startswith("#"):
                continue
            for m in CMD.finditer(line.strip()):
                path = m.group(1)
                for p in prefixes:
                    if path.startswith(p):
                        path = path[len(p):]
                f = os.path.join(root, path)
                seen += 1
                if not os.path.isfile(f):
                    bad.append(f"{wf}:{n}: {m.group(1)} not found in {root}")
                elif not os.stat(f).st_mode & stat.S_IXUSR:
                    bad.append(f"{wf}:{n}: {path} is run directly but mode {stat.S_IMODE(os.stat(f).st_mode):04o}")
                elif not open(f, "rb").read(2) == b"#!":
                    bad.append(f"{wf}:{n}: {path} has no shebang")
    for b in bad:
        print(b)
    print(f"{seen} direct script invocations checked, {len(bad)} bad")
    sys.exit(1 if bad or not seen else 0)


if __name__ == "__main__":
    main()
