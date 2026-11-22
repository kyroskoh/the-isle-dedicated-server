#!/usr/bin/env python3
"""
release_notes.py - release notes for one version, taken from CHANGELOG.md (used by .github/workflows/release.yml).

    release_notes.py 1.13.0 [--changelog CHANGELOG.md] [--repo owner/name]

Prints the body of the "## [1.13.0] - date" section (up to the next "## [" heading) followed by install links and
the project credit. Exits 1 if the section is missing or empty, so a tag without notes fails loudly instead of
publishing an empty release.
"""
import argparse
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")


def section(text, version):
    """(date, body) of the "## [version]" section, or (None, None)"""
    lines = text.splitlines()
    head = re.compile(r"^## \[%s\](?:\s*-\s*(\S+))?\s*$" % re.escape(version))
    for i, line in enumerate(lines):
        m = head.match(line)
        if not m:
            continue
        body = []
        for nxt in lines[i + 1:]:
            if nxt.startswith("## [") or re.match(r"^\[[^\]]+\]: ", nxt):
                break
            body.append(nxt)
        return m.group(1), "\n".join(body).strip()
    return None, None


def notes(text, version, repo):
    date, body = section(text, version)
    if not body:
        return None
    url = "https://github.com/%s" % repo
    # relative links (e.g. [PRD.md](PRD.md)) do not resolve on a release page: point them at the tagged files
    body = re.sub(r"\]\((?!https?://|mailto:|#)([^)\s]+)\)", lambda m: "](%s/blob/v%s/%s)" % (url, version, m.group(1).lstrip("./")), body)
    return "\n".join([
        body, "", "---", "",
        "**Install or update:** [INSTALL.md](%s/blob/v%s/INSTALL.md) · **Docker:** [DOCKER.md](%s/blob/v%s/DOCKER.md)"
        " · **Full changelog:** [CHANGELOG.md](%s/blob/v%s/CHANGELOG.md)" % (url, version, url, version, url, version),
        "",
        "Made with ❤️ by [Kyros Koh](https://github.com/kyroskoh)", ""])


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    ap.add_argument("version", help="e.g. 1.13.0 (a leading v is ignored)")
    ap.add_argument("--changelog", default=os.path.join(REPO, "CHANGELOG.md"))
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "kyroskoh/the-isle-dedicated-server"))
    args = ap.parse_args(argv)
    version = args.version.lstrip("v")
    if not VERSION_RE.match(version):
        print("Not a version (X.Y.Z): %s" % args.version, file=sys.stderr)
        return 2
    with open(args.changelog, encoding="utf-8") as handle:
        out = notes(handle.read(), version, args.repo)
    if not out:
        print("CHANGELOG has no notes for %s - add a '## [%s] - date' section first" % (version, version), file=sys.stderr)
        return 1
    sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
