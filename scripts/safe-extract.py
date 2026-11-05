#!/usr/bin/env python3
# SPDX-License-Identifier: CC0-1.0
"""Extracts an untrusted .zip or .tar without trusting its member names or types.

Only regular files and directories are accepted: no symbolic or hard links, devices, FIFOs,
absolute paths, '..', backslashes, control characters or duplicate names. Every member must lie
under one of --allow-prefix (path prefixes, e.g. 'repo/'), or be one of --allow-file. Sizes are
bounded in total and per member. Modes are not taken from the archive (files 0644, dirs 0755).
The destination must not exist yet: nothing already on disk is followed or overwritten.
"""
import argparse
import os
import stat
import sys
import tarfile
import zipfile

NAME_OK = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-+/=")


def fail(msg):
    sys.exit(f"safe-extract: refused: {msg}")


def check_name(name, args):
    if not name or len(name) > 512 or not set(name) <= NAME_OK:
        fail(f"member name {name!r}")
    stripped = name.rstrip("/")
    parts = stripped.split("/")
    if name.startswith("/") or any(p in ("", ".", "..") for p in parts):
        fail(f"member path {name!r}")
    if stripped in args.allow_file:
        return stripped
    if not any((stripped + "/").startswith(p) or stripped == p.rstrip("/") for p in args.allow_prefix):
        fail(f"member {name!r} outside allowed paths")
    return stripped


def main():
    p = argparse.ArgumentParser()
    p.add_argument("archive")
    p.add_argument("dest")
    p.add_argument("--allow-prefix", action="append", default=[])
    p.add_argument("--allow-file", action="append", default=[])
    p.add_argument("--max-total", type=int, default=600 * 1024 * 1024)
    p.add_argument("--max-members", type=int, default=500000)
    args = p.parse_args()
    if os.path.lexists(args.dest):
        fail(f"destination {args.dest} exists")
    members = []  # (name, is_dir, size, opener)
    if zipfile.is_zipfile(args.archive):
        z = zipfile.ZipFile(args.archive)
        for info in z.infolist():
            mode = info.external_attr >> 16
            is_dir = info.is_dir()
            if mode and not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
                fail(f"{info.filename!r} is not a regular file or directory")
            if info.flag_bits & 0x1:
                fail("encrypted member")
            members.append((info.filename, is_dir, info.file_size, lambda i=info: z.open(i)))
    else:
        t = tarfile.open(args.archive, mode="r:")  # uncompressed only: sizes are what they say
        for info in t.getmembers():
            if not (info.isreg() or info.isdir()):
                fail(f"{info.name!r} is not a regular file or directory")
            if info.sparse is not None:
                fail("sparse member")
            members.append((info.name, info.isdir(), info.size, lambda i=info: t.extractfile(i)))
    if len(members) > args.max_members:
        fail("too many members")
    seen = set()
    total = 0
    plan = []
    for name, is_dir, size, opener in members:
        clean = check_name(name, args)
        if clean in seen:
            if is_dir:
                continue
            fail(f"duplicate member {clean!r}")
        seen.add(clean)
        total += size
        if total > args.max_total:
            fail("archive too large")
        plan.append((clean, is_dir, size, opener))
    # Files may not double as directories.
    files = {c for c, d, _, _ in plan if not d}
    for c in seen:
        parts = c.split("/")
        for i in range(1, len(parts)):
            if "/".join(parts[:i]) in files:
                fail(f"{c!r} is below a file")
    os.mkdir(args.dest, 0o755)
    dest_fd = os.open(args.dest, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for clean, is_dir, size, opener in sorted(plan, key=lambda m: m[0]):
            parts = clean.split("/")
            dirs = parts if is_dir else parts[:-1]
            fd = os.dup(dest_fd)
            try:
                for d in dirs:
                    try:
                        os.mkdir(d, 0o755, dir_fd=fd)
                    except FileExistsError:
                        pass
                    nfd = os.open(d, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                    os.close(fd)
                    fd = nfd
                if not is_dir:
                    out = os.open(parts[-1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644, dir_fd=fd)
                    written = 0
                    with os.fdopen(out, "wb") as w, opener() as r:
                        while True:
                            chunk = r.read(1 << 20)
                            if not chunk:
                                break
                            written += len(chunk)
                            if written > size:
                                fail(f"{clean!r} larger than declared")
                            w.write(chunk)
                    if written != size:
                        fail(f"{clean!r} shorter than declared")
            finally:
                os.close(fd)
    finally:
        os.close(dest_fd)


if __name__ == "__main__":
    main()
