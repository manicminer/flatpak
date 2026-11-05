#!/usr/bin/env python3
# SPDX-License-Identifier: CC0-1.0
"""Writes the static files around the repository: the remote's .flatpakrepo, one .flatpakref per
app, the public key and an index page. Their bytes depend only on config.json, apps.json and the
pinned key, so they stay the same from run to run for one key."""
import argparse
import base64
import html
import json
import os


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--site", required=True)
    p.add_argument("--config", required=True)
    p.add_argument("--apps", required=True)
    p.add_argument("--key", required=True, help="pinned public key, binary (gpg --export)")
    a = p.parse_args()
    cfg = json.load(open(a.config))
    apps = json.load(open(a.apps))["apps"]
    with open(a.key, "rb") as f:
        key = f.read()
    if key.lstrip().startswith(b"-----BEGIN"):
        raise SystemExit("site: the pinned key must be binary (gpg --export), not armored")
    key_b64 = base64.b64encode(key).decode()
    name = cfg["remote_name"]

    write(os.path.join(a.site, f"{name}.flatpakrepo"), "\n".join([
        "[Flatpak Repo]",
        f"Title={cfg['title']}",
        f"Url={cfg['repo_url']}",
        f"Homepage={cfg['homepage']}",
        "Comment=Unofficial Flatpak builds by manicminer",
        "Description=Unofficial builds of forks and tools by manicminer. Not affiliated with Flathub or upstream projects.",
        f"DefaultBranch=stable",
        f"GPGKey={key_b64}",
        "",
    ]))
    rows = []
    for app_id, app in sorted(apps.items()):
        write(os.path.join(a.site, f"{app_id}.flatpakref"), "\n".join([
            "[Flatpak Ref]",
            f"Title={app['title']}",
            f"Name={app_id}",
            f"Branch={app['branch']}",
            f"Url={cfg['repo_url']}",
            f"SuggestRemoteName={name}",
            f"Homepage=https://github.com/{app['source_repo']}",
            "IsRuntime=false",
            f"RuntimeRepo={cfg['runtime_repo']}",
            f"GPGKey={key_b64}",
            "",
        ]))
        rows.append(f"<li><a href=\"{html.escape(app_id)}.flatpakref\">{html.escape(app['title'])}</a> "
                    f"(<code>{html.escape(app_id)}</code>, source: "
                    f"<a href=\"https://github.com/{html.escape(app['source_repo'])}\">{html.escape(app['source_repo'])}</a>)</li>")
    with open(os.path.join(a.site, f"{name}.gpg"), "wb") as f:
        f.write(key)
    write(os.path.join(a.site, "index.html"), f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>{html.escape(cfg['title'])}</title></head>
<body>
<h1>{html.escape(cfg['title'])}</h1>
<p>Unofficial builds; not affiliated with Flathub or the upstream projects.</p>
<pre>flatpak remote-add --user --if-not-exists {html.escape(name)} {html.escape(cfg['base_url'])}{html.escape(name)}.flatpakrepo</pre>
<ul>
{chr(10).join(rows)}
</ul>
</body></html>
""")
    # GitHub Pages must serve the repository's files as they are.
    write(os.path.join(a.site, ".nojekyll"), "")


if __name__ == "__main__":
    main()
