#!/usr/bin/env python3
"""
Tests for scripts/check_updates.py — standard library only, so there is
nothing to install, and no network: HTTP calls are replaced with canned
responses, which lets the suite run identically on a laptop and in CI.

    python3 -m unittest discover -s tests -v
    make test

The value of these tests is not coverage: it is that the way this script goes
wrong is SILENT. If release selection wrongly discards a valid release,
nothing raises — the checker reports "no updates", which is indistinguishable
from there genuinely being none, and a host can sit on a vulnerable version
for months. Every test below pins one concrete way of failing like that.
"""

import importlib.util
import json
import os
import unittest
from unittest import mock

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

_spec = importlib.util.spec_from_file_location(
    "check_updates", os.path.join(BASE, "scripts", "check_updates.py"))
cu = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cu)


def fake_response(payload, text=None):
    """A stand-in HTTP response exposing only what the module uses."""
    resp = mock.Mock()
    resp.json.return_value = payload
    resp.text = text if text is not None else json.dumps(payload)
    resp.raise_for_status.return_value = None
    return resp


def gh_release(tag, prerelease=False, name=None, draft=False):
    return {"tag_name": tag, "prerelease": prerelease,
            "name": name if name is not None else tag, "draft": draft}


# ──────────────────────────────────────────────────────────────────────────
class TestExtractSemver(unittest.TestCase):
    """From a version string to a comparable tuple."""

    def test_common_formats(self):
        cases = {
            "v15.0.3":     (15, 0, 3),
            "2.15.0":      (2, 15, 0),
            "1.37.3":      (1, 37, 3),
            "v2.28.0":     (2, 28, 0),
            "n8n@2.39.10": (2, 39, 10),   # monorepo tag
            "15.0":        (15, 0, 0),    # implicit patch
            "10":          (10, 0, 0),    # single-number Docker tag
            "v8":          (8, 0, 0),
        }
        for text, expected in cases.items():
            with self.subTest(text=text):
                self.assertEqual(cu.extract_semver(text), expected)

    def test_non_versions_yield_zero(self):
        # (0,0,0) is the sentinel: determine_bump treats it as "not
        # comparable" instead of inventing a comparison.
        for text in ("latest", "", "stable", "edge"):
            with self.subTest(text=text):
                self.assertEqual(cu.extract_semver(text), (0, 0, 0))

    def test_2_39_10_is_greater_than_2_39_9(self):
        # The comparison is between integers, not strings: "2.39.9" sorts
        # above "2.39.10" lexicographically, which is the mistake to rule out.
        self.assertGreater(cu.extract_semver("2.39.10"),
                           cu.extract_semver("2.39.9"))


# ──────────────────────────────────────────────────────────────────────────
class TestDetermineBump(unittest.TestCase):

    def test_classification(self):
        cases = [
            ((1, 0, 0), (2, 0, 0), "major", True),
            ((2, 33, 6), (2, 39, 10), "minor", False),
            ((1, 37, 1), (1, 37, 3), "patch", False),
            ((1, 37, 3), (1, 37, 3), "none", False),
            ((1, 37, 3), (1, 37, 1), "none", False),   # backwards: no update
        ]
        for current, latest, bump, major in cases:
            with self.subTest(current=current, latest=latest):
                self.assertEqual(cu.determine_bump(current, latest), (bump, major))

    def test_non_comparable_version(self):
        self.assertEqual(cu.determine_bump((0, 0, 0), (1, 2, 3)), ("unknown", False))
        self.assertEqual(cu.determine_bump((1, 2, 3), (0, 0, 0)), ("unknown", False))


# ──────────────────────────────────────────────────────────────────────────
class TestIsStableRelease(unittest.TestCase):
    """
    The pre-release filter works on the release TITLE, which on several forges
    is a sentence rather than a number. A bare substring match on "rc" or
    "dev" hits ordinary words and makes real releases disappear.
    """

    def test_rejects_prereleases(self):
        for title in ("v1.2.3-rc.1", "v1.2.3-RC2", "v2.0.0-beta", "v2.0.0-beta.3",
                      "1.0-alpha", "nightly", "v3.0-preview", "v1.0.0rc1",
                      "2.0.0-dev", "v4.0-TEST"):
            with self.subTest(title=title):
                self.assertFalse(cu.is_stable_release(title),
                                 f"{title!r} should have been rejected")

    def test_keeps_legitimate_descriptive_titles(self):
        # Each of these contains a keyword as a substring of an ordinary word:
        # architectu(rc)e, sou(rc)e, sea(rc)h, fo(rc)e, (dev)ice, la(test).
        for title in ("v2.0.0 architecture rewrite",
                      "Release 3.1 — source cleanup",
                      "v1.0 search improvements",
                      "v9.9 force push fix",
                      "v4.0 device support",
                      "v5.0 developer experience",
                      "latest",
                      "v6.0 greatest hits",
                      "v7.0 performance"):
            with self.subTest(title=title):
                self.assertTrue(cu.is_stable_release(title),
                                f"{title!r} is a stable release and should not "
                                f"have been rejected")


# ──────────────────────────────────────────────────────────────────────────
class TestParseImage(unittest.TestCase):

    def test_splits_image_and_tag(self):
        cases = {
            "postgres:18-alpine":
                ("postgres", "18-alpine", "18"),
            "codeberg.org/forgejo/forgejo:15.0.9":
                ("codeberg.org/forgejo/forgejo", "15.0.9", "15.0.9"),
            "ghcr.io/gethomepage/homepage:v1.13.2":
                ("ghcr.io/gethomepage/homepage", "v1.13.2", "v1.13.2"),
            "cloudflare/cloudflared:latest":
                ("cloudflare/cloudflared", "latest", "latest"),
            "redis:8-alpine":
                ("redis", "8-alpine", "8"),
        }
        for image, expected in cases.items():
            with self.subTest(image=image):
                self.assertEqual(cu.parse_image(image), expected)

    def test_missing_tag_becomes_latest(self):
        self.assertEqual(cu.parse_image("nginx"), ("nginx", "latest", "latest"))

    def test_numeric_suffix_is_not_stripped(self):
        # "2025.01.20" has no build suffix: it must be left whole.
        self.assertEqual(cu.parse_image("app:2025.01.20")[2], "2025.01.20")


# ──────────────────────────────────────────────────────────────────────────
class TestForgeApiReleaseSelection(unittest.TestCase):
    """
    The choice must depend on version numbers, not on the order the forge
    happens to list its releases in.
    """

    def _call(self, releases, current="2.33.6",
              repo_url="https://github.com/n8n-io/n8n"):
        with mock.patch.object(cu.requests, "get",
                               return_value=fake_response(releases)):
            return cu.get_latest_from_forge_api(repo_url, "n8n-io", "n8n", current)

    def test_ignores_api_ordering(self):
        # Real case from 2026-09-21: the GitHub API listed 2.39.9 before
        # 2.39.10, and taking the first element proposed a version that had
        # already been superseded the same day.
        releases = [gh_release("n8n@2.39.9"), gh_release("n8n@2.39.10")]
        self.assertEqual(self._call(releases)["version"], "n8n@2.39.10")

    def test_same_result_with_reversed_order(self):
        releases = [gh_release("n8n@2.39.10"), gh_release("n8n@2.39.9")]
        self.assertEqual(self._call(releases)["version"], "n8n@2.39.10")

    def test_rejects_prereleases_even_when_higher(self):
        # n8n marks its whole 2.40.x line as prerelease (the `next` channel):
        # picking the highest semver must not jump onto it.
        releases = [gh_release("n8n@2.40.5", prerelease=True),
                    gh_release("n8n@2.40.4", prerelease=True),
                    gh_release("n8n@2.39.10"),
                    gh_release("n8n@2.39.9")]
        self.assertEqual(self._call(releases)["version"], "n8n@2.39.10")

    def test_stays_on_the_current_major(self):
        # Forgejo publishes 15.x and 16.x on the same day: someone on 15 must
        # not be pushed onto the next major.
        releases = [gh_release("v16.0.5"), gh_release("v15.0.9"),
                    gh_release("v16.0.4"), gh_release("v15.0.8")]
        got = self._call(releases, current="15.0.6",
                         repo_url="https://codeberg.org/forgejo/forgejo")
        self.assertEqual(got["version"], "v15.0.9")

    def test_ignores_drafts(self):
        releases = [gh_release("n8n@2.99.0", draft=True), gh_release("n8n@2.39.10")]
        self.assertEqual(self._call(releases)["version"], "n8n@2.39.10")

    def test_moving_tags_never_beat_numbers(self):
        # n8n also publishes releases named "stable" and "latest". They
        # extract as (0,0,0) and must never be returned as if they were a
        # version number.
        releases = [gh_release("stable"), gh_release("latest"),
                    gh_release("n8n@2.39.10")]
        self.assertEqual(self._call(releases)["version"], "n8n@2.39.10")

    def test_raises_when_nothing_stable_exists(self):
        releases = [gh_release("v1.0.0-rc.1", prerelease=True)]
        with self.assertRaises(ValueError):
            self._call(releases, current="1.0.0")


# ──────────────────────────────────────────────────────────────────────────
ATOM = """<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry><title>{a}</title></entry>
  <entry><title>{b}</title></entry>
  <entry><title>{c}</title></entry>
</feed>"""


class TestRssReleaseSelection(unittest.TestCase):
    """The RSS fallback must follow the same rule as the API path."""

    def _call(self, a, b, c, current="2.33.6"):
        xml = ATOM.format(a=a, b=b, c=c)
        with mock.patch.object(cu.requests, "get",
                               return_value=fake_response(None, text=xml)):
            return cu.get_latest_from_rss("https://example/releases.atom", current)

    def test_picks_the_highest_not_the_first(self):
        # The order of an Atom feed reflects dates, not versions.
        self.assertEqual(self._call("2.39.9", "2.39.10", "2.38.0"), "2.39.10")

    def test_rejects_prereleases(self):
        self.assertEqual(self._call("2.40.0-rc.1", "2.39.10", "2.39.9"), "2.39.10")

    def test_stays_on_the_current_major(self):
        self.assertEqual(self._call("3.0.0", "2.39.10", "2.39.9"), "2.39.10")

    def test_raises_when_the_feed_has_nothing_usable(self):
        with self.assertRaises(ValueError):
            self._call("nightly", "v1.0-beta", "alpha-2")


# ──────────────────────────────────────────────────────────────────────────
class TestMetadataConsistency(unittest.TestCase):
    """
    services_metadata.json is where the checker learns what to track: if it
    gets corrupted or loses a field, a service silently stops being checked.
    """

    def setUp(self):
        with open(os.path.join(BASE, "services_metadata.json")) as f:
            self.meta = json.load(f)

    def test_every_service_has_criticality_and_stack(self):
        for name, entry in self.meta.items():
            with self.subTest(service=name):
                self.assertIn("criticality", entry)
                self.assertIn("stack", entry)

    def test_criticality_is_one_of_the_known_values(self):
        allowed = {"critical", "medium", "low", "stateless", "dependency"}
        for name, entry in self.meta.items():
            with self.subTest(service=name):
                self.assertIn(entry["criticality"], allowed)

    def test_tracked_services_have_something_to_query(self):
        # Without `repo` or the owner/name pair a service ends up tracked but
        # uncheckable, which is the case that goes unnoticed.
        for name, entry in self.meta.items():
            if entry.get("criticality") in ("stateless", "dependency"):
                continue
            with self.subTest(service=name):
                has_repo = bool(entry.get("repo"))
                has_pair = bool(entry.get("github_owner")) and \
                           bool(entry.get("github_repo_name"))
                self.assertTrue(has_repo or has_pair,
                                f"{name} is tracked but has no repository to query")


if __name__ == "__main__":
    unittest.main(verbosity=2)
