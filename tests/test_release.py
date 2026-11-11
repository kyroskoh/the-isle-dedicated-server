#!/usr/bin/env python3
"""
tests/test_release.py - release notes from CHANGELOG.md (tools/release_notes.py, used by the release workflow).
    python3 -m unittest -v tests/test_release.py
"""
import os
import re
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "tools"))
import release_notes  # noqa: E402

SAMPLE = """# Changelog

## [Unreleased]

## [1.2.0] - 2026-01-02

### Added
- New thing. See [PRD.md](PRD.md), [the docs](./docs/x.md#a), [site](https://example.org) and [top](#top).

## [1.1.0] - 2026-01-01

### Fixed
- Old bug.

[Unreleased]: https://example.org/compare/v1.2.0...HEAD
[1.2.0]: https://example.org/releases/tag/v1.2.0
"""


class ReleaseNotesTest(unittest.TestCase):
    def test_section_stops_at_next_heading(self):
        date, body = release_notes.section(SAMPLE, "1.2.0")
        self.assertEqual(date, "2026-01-02")
        self.assertTrue(body.startswith("### Added\n- New thing."))
        self.assertEqual(release_notes.section(SAMPLE, "1.1.0")[1], "### Fixed\n- Old bug.", "stops at the link references")

    def test_missing_or_empty(self):
        self.assertIsNone(release_notes.notes(SAMPLE, "9.9.9", "o/r"))
        self.assertIsNone(release_notes.notes(re.sub(r"### Added\n- New thing[^\n]*\n", "", SAMPLE), "1.2.0", "o/r"))
        self.assertIsNone(release_notes.section(SAMPLE, "1.2")[1], "1.2 must not match 1.2.0")

    def test_notes_have_links_and_credit(self):
        out = release_notes.notes(SAMPLE, "1.2.0", "o/r")
        self.assertIn("https://github.com/o/r/blob/v1.2.0/INSTALL.md", out)
        self.assertIn("Made with ❤️ by [Kyros Koh](https://github.com/kyroskoh)", out)
        self.assertIn("[PRD.md](https://github.com/o/r/blob/v1.2.0/PRD.md)", out)
        self.assertIn("[the docs](https://github.com/o/r/blob/v1.2.0/docs/x.md#a)", out)
        self.assertIn("[site](https://example.org)", out)
        self.assertIn("[top](#top)", out)

    def test_cli(self):
        tool = os.path.join(REPO, "tools", "release_notes.py")
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as handle:
            handle.write(SAMPLE)
        try:
            ok = subprocess.run([sys.executable, tool, "v1.2.0", "--changelog", handle.name], stdout=subprocess.PIPE, universal_newlines=True)
            self.assertEqual(ok.returncode, 0)
            self.assertTrue(ok.stdout.startswith("### Added"))
            self.assertEqual(subprocess.run([sys.executable, tool, "1.3.0", "--changelog", handle.name], stderr=subprocess.PIPE).returncode, 1)
            self.assertEqual(subprocess.run([sys.executable, tool, "latest", "--changelog", handle.name], stderr=subprocess.PIPE).returncode, 2)
        finally:
            os.unlink(handle.name)

    def test_current_version_has_notes(self):
        """the release workflow would refuse the tag otherwise"""
        with open(os.path.join(REPO, "VERSION")) as handle:
            version = handle.read().strip()
        with open(os.path.join(REPO, "CHANGELOG.md"), encoding="utf-8") as handle:
            text = handle.read()
        self.assertTrue(release_notes.notes(text, version, "o/r"), "CHANGELOG.md needs a '## [%s]' section" % version)
        self.assertRegex(text, r"(?m)^## \[%s\] - \d{4}-\d{2}-\d{2}$" % re.escape(version))


if __name__ == "__main__":
    unittest.main()
