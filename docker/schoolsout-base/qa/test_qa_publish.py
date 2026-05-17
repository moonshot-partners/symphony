"""Tests for the Playwright Test → `qa-evidence/` bridge.

These cover the three outcomes the WORKFLOW promises:
  * PASS path — JSON in, screenshot/video promoted, verdict.pass=true
  * FAIL path — JSON in, status='failed' → verdict.pass=false
  * BLOCKED path — no JSON, `--blocked "<reason>"` produces verdict.blocked=true

The other branches that aren't worth covering directly are exercised
implicitly by the PASS test (attachment selection, slug, datetime).
"""

from __future__ import annotations

import json
import os
import tempfile
import unittest

import qa_publish


def _shot_bytes() -> bytes:
    # 1x1 transparent PNG — small enough to inline, valid enough that any
    # downstream image consumer that opens it won't choke.
    return bytes.fromhex(
        "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
        "0000000d49444154789c63000100000005000100190f4dc2000000004945"
        "4e44ae426082"
    )


def _video_bytes() -> bytes:
    # Just non-empty — qa_publish only checks `os.path.isfile`.
    return b"\x1a\x45\xdf\xa3"


def _playwright_results(tmpdir: str, *, status: str = "passed", with_attachments: bool = True) -> str:
    shot = os.path.join(tmpdir, "shot.png")
    video = os.path.join(tmpdir, "video.webm")
    trace = os.path.join(tmpdir, "trace.zip")
    attachments = []
    if with_attachments:
        with open(shot, "wb") as fh:
            fh.write(_shot_bytes())
        with open(video, "wb") as fh:
            fh.write(_video_bytes())
        with open(trace, "wb") as fh:
            fh.write(b"PK\x03\x04fake-trace")
        attachments = [
            {"name": "screenshot", "contentType": "image/png", "path": shot},
            {"name": "video", "contentType": "video/webm", "path": video},
            {"name": "trace", "contentType": "application/zip", "path": trace},
        ]
    return os.path.join(tmpdir, "results.json"), {
        "suites": [
            {
                "specs": [
                    {
                        "title": "homepage renders",
                        "tests": [
                            {
                                "results": [
                                    {
                                        "status": status,
                                        "duration": 1234,
                                        "errors": [] if status == "passed" else [{"message": "boom"}],
                                        "attachments": attachments,
                                    }
                                ]
                            }
                        ],
                    }
                ]
            }
        ]
    }


class QaPublishTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmpdir = self._tmp.name

    def _run(self, results_path: str, evidence_dir: str, *, blocked: str | None = None) -> int:
        argv = ["--evidence-dir", evidence_dir, "--ticket", "SODEV-TEST", "--results", results_path]
        if blocked is not None:
            argv += ["--blocked", blocked]
        return qa_publish.main(argv)

    def test_pass_path_promotes_screenshot_and_video(self):
        results_path, data = _playwright_results(self.tmpdir, status="passed")
        with open(results_path, "w") as fh:
            json.dump(data, fh)
        evidence = os.path.join(self.tmpdir, "qa-evidence")

        rc = self._run(results_path, evidence)

        self.assertEqual(rc, 0, "exit 0 on PASS")
        files = sorted(os.listdir(evidence))
        self.assertIn("session.webm", files, f"video promoted as session.webm: {files}")
        self.assertIn("session.zip", files, f"trace promoted as session.zip: {files}")
        self.assertIn("qa-report.md", files)
        self.assertIn("verdict.json", files)
        pngs = [f for f in files if f.endswith(".png")]
        self.assertEqual(len(pngs), 1, f"exactly one screenshot promoted: {pngs}")
        self.assertTrue(pngs[0].startswith("01-pass-"), f"slug stem present: {pngs[0]}")

        with open(os.path.join(evidence, "qa-report.md")) as fh:
            report = fh.read()
        # Compact shape: no h1 title, no "## Evidence" filename list,
        # no Evidence column (Elixir renders images directly + emits links).
        self.assertNotIn("# QA self-review", report)
        self.assertNotIn("## Evidence", report)
        self.assertNotIn("session.webm", report)
        self.assertNotIn("session.zip", report)
        self.assertNotIn("trace.playwright.dev", report)
        self.assertIn("- Result: PASS", report)
        self.assertIn("| Check | Result | Detail |", report)
        self.assertNotIn("| Evidence |", report)

        with open(os.path.join(evidence, "verdict.json")) as fh:
            verdict = json.load(fh)
        self.assertTrue(verdict["pass"])
        self.assertFalse(verdict["blocked"])
        self.assertEqual(verdict["checks"][0]["name"], "homepage renders")

    def test_fail_path_records_error_and_exit_1(self):
        results_path, data = _playwright_results(self.tmpdir, status="failed", with_attachments=False)
        with open(results_path, "w") as fh:
            json.dump(data, fh)
        evidence = os.path.join(self.tmpdir, "qa-evidence")

        rc = self._run(results_path, evidence)

        self.assertEqual(rc, 1, "exit 1 on FAIL")
        with open(os.path.join(evidence, "verdict.json")) as fh:
            verdict = json.load(fh)
        self.assertFalse(verdict["pass"])
        self.assertFalse(verdict["blocked"])
        self.assertEqual(verdict["checks"][0]["pass"], False)
        self.assertIn("boom", verdict["checks"][0]["detail"])

    def test_blocked_path_writes_verdict_without_results(self):
        evidence = os.path.join(self.tmpdir, "qa-evidence")
        rc = self._run(os.path.join(self.tmpdir, "absent.json"), evidence, blocked="dev server failed")

        self.assertEqual(rc, 1, "BLOCKED is failure")
        with open(os.path.join(evidence, "verdict.json")) as fh:
            verdict = json.load(fh)
        self.assertFalse(verdict["pass"])
        self.assertTrue(verdict["blocked"])
        with open(os.path.join(evidence, "qa-report.md")) as fh:
            report = fh.read()
        self.assertIn("- Result: BLOCKED", report)
        self.assertIn("dev server failed", report)
        self.assertNotIn("# QA self-review", report)
        self.assertNotIn("## Evidence", report)

    def test_missing_results_without_blocked_returns_2(self):
        evidence = os.path.join(self.tmpdir, "qa-evidence")
        rc = self._run(os.path.join(self.tmpdir, "absent.json"), evidence)
        self.assertEqual(rc, 2, "exit 2 = configuration error (missing JSON, no --blocked)")


def _results_with_setup_and_feature(tmpdir: str) -> tuple[str, dict]:
    """Simulates `--project=parents` output: setup-parents runs first, then the feature spec."""
    setup_video = os.path.join(tmpdir, "setup_video.webm")
    feature_video = os.path.join(tmpdir, "feature_video.webm")
    with open(setup_video, "wb") as fh:
        fh.write(b"SETUP-VIDEO")
    with open(feature_video, "wb") as fh:
        fh.write(b"FEATURE-VIDEO")

    data = {
        "suites": [
            {
                "title": "auth-parents.setup.ts",
                "file": "e2e/auth-parents.setup.ts",
                "suites": [],
                "specs": [
                    {
                        "title": "provision parents account",
                        "tests": [
                            {
                                "results": [
                                    {
                                        "status": "passed",
                                        "duration": 5000,
                                        "errors": [],
                                        "attachments": [
                                            {"name": "video", "contentType": "video/webm", "path": setup_video}
                                        ],
                                    }
                                ]
                            }
                        ],
                    }
                ],
            },
            {
                "title": "parents/search.spec.ts",
                "file": "e2e/parents/search.spec.ts",
                "suites": [],
                "specs": [
                    {
                        "title": "search results render",
                        "tests": [
                            {
                                "results": [
                                    {
                                        "status": "passed",
                                        "duration": 2000,
                                        "errors": [],
                                        "attachments": [
                                            {"name": "video", "contentType": "video/webm", "path": feature_video}
                                        ],
                                    }
                                ]
                            }
                        ],
                    }
                ],
            },
        ]
    }
    results_path = os.path.join(tmpdir, "results.json")
    with open(results_path, "w") as fh:
        json.dump(data, fh)
    return results_path, data


class SetupSuiteFilterTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmpdir = self._tmp.name

    def _run(self, results_path: str, evidence_dir: str) -> int:
        return qa_publish.main(["--evidence-dir", evidence_dir, "--ticket", "SODEV-TEST", "--results", results_path])

    def test_setup_suite_video_does_not_win(self):
        """session.webm must come from the feature spec, not setup-parents."""
        results_path, _ = _results_with_setup_and_feature(self.tmpdir)
        evidence = os.path.join(self.tmpdir, "qa-evidence")

        self._run(results_path, evidence)

        with open(os.path.join(evidence, "session.webm"), "rb") as fh:
            content = fh.read()
        self.assertEqual(content, b"FEATURE-VIDEO", "session.webm must contain feature video, not setup video")

    def test_setup_suite_excluded_from_checks(self):
        """Setup spec must not appear in verdict checks — only feature specs count."""
        results_path, _ = _results_with_setup_and_feature(self.tmpdir)
        evidence = os.path.join(self.tmpdir, "qa-evidence")

        self._run(results_path, evidence)

        with open(os.path.join(evidence, "verdict.json")) as fh:
            verdict = json.load(fh)
        names = [c["name"] for c in verdict["checks"]]
        self.assertNotIn("provision parents account", names, f"setup check must be excluded: {names}")
        self.assertIn("search results render", names, f"feature check must be present: {names}")


if __name__ == "__main__":
    unittest.main()
