"""Tests for `qa_devserver.dev_server` — the QA harness's Next.js boot helper.

These tests pin the production-mode contract: the harness MUST run a full
`next build` before serving, and serve via `npm start` (not `npm run dev`).
Reason: `next dev` compiles routes on demand, so the first hit of any route
pays a 30-90s compile cost. SODEV-879 reproduced this — a fresh middleware.ts
forced a whole-tree recompile, the QA harness's `page.goto("/parents", ...)`
hit a cold route, and Playwright's 45s timeout fired against a 45s blank
screen recording. Running `next build` once upfront pays that cost ONCE,
surfaces build errors before Playwright launches, and lets the server respond
in milliseconds.

Run from the repo root:

    python3 -m unittest docker/schoolsout-base/qa/test_qa_devserver.py
"""

from __future__ import annotations

import os
import sys
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.dirname(__file__))

import qa_devserver  # noqa: E402


def _build_ok():
    return MagicMock(returncode=0)


def _build_failed():
    return MagicMock(returncode=1)


def _start_proc_alive():
    proc = MagicMock()
    proc.poll.return_value = None
    proc.returncode = 0
    return proc


class DevServerProductionModeTest(unittest.TestCase):
    """The harness must use `next build && next start`, not `next dev`."""

    def setUp(self):
        self._patches = [
            patch.object(qa_devserver, "_resolve_app_dir", return_value="/tmp/app"),
            patch.object(qa_devserver, "_http_ready", return_value=True),
            patch.object(qa_devserver.os, "makedirs"),
            patch("builtins.open", new_callable=MagicMock),
        ]
        for p in self._patches:
            p.start()
        self.addCleanup(self._stop)

    def _stop(self):
        for p in self._patches:
            p.stop()

    def test_runs_npm_run_build_before_starting_server(self):
        """`next build` must run BEFORE `npm start` so all routes are
        pre-compiled. Without this, the first Playwright hit on any route
        pays an on-demand compile cost that blows past Playwright's timeout
        budget — exactly the SODEV-879 BLOCKED root cause."""
        with patch.object(qa_devserver, "_port_open", side_effect=[False, True]), \
             patch.object(qa_devserver.subprocess, "run", return_value=_build_ok()) as build, \
             patch.object(qa_devserver.subprocess, "Popen", return_value=_start_proc_alive()) as popen:
            with qa_devserver.dev_server("/tmp/app", port=3001, api_base="https://x") as url:
                self.assertEqual(url, "http://localhost:3001")

            self.assertEqual(build.call_count, 1, "must run `npm run build` exactly once")
            build_args = build.call_args[0][0]
            self.assertEqual(
                build_args[:3],
                ["npm", "run", "build"],
                f"first subprocess.run must be `npm run build`, got {build_args}",
            )

            popen_args = popen.call_args[0][0]
            self.assertNotIn(
                "dev",
                popen_args,
                f"server must NOT use `npm run dev` — that triggers on-demand "
                f"route compile and reproduces SODEV-879 BLOCKED. Got {popen_args}",
            )

    def test_serves_with_npm_start_not_npm_run_dev(self):
        """The long-running server process must be `npm start` (production
        mode) — `next dev` compiles per route on demand, which is the SODEV-879
        root cause."""
        with patch.object(qa_devserver, "_port_open", side_effect=[False, True]), \
             patch.object(qa_devserver.subprocess, "run", return_value=_build_ok()), \
             patch.object(qa_devserver.subprocess, "Popen", return_value=_start_proc_alive()) as popen:
            with qa_devserver.dev_server("/tmp/app", port=3001, api_base="https://x"):
                pass

            popen_args = popen.call_args[0][0]
            self.assertEqual(
                popen_args[:2],
                ["npm", "start"],
                f"long-running server must be `npm start`, got {popen_args}",
            )

    def test_raises_when_build_fails_with_log_tail(self):
        """A failed `next build` must abort BEFORE `npm start` — otherwise
        Playwright runs against a stale build (or no build at all) and
        BLOCKED for unrelated reasons. Operator must see the build log tail
        in the exception so the fix is obvious without rerun."""
        with patch.object(qa_devserver, "_port_open", side_effect=[False, True]), \
             patch.object(qa_devserver.subprocess, "run", return_value=_build_failed()), \
             patch.object(qa_devserver, "_tail", return_value="error: type X is not assignable"), \
             patch.object(qa_devserver.subprocess, "Popen") as popen:
            with self.assertRaises(RuntimeError) as ctx:
                with qa_devserver.dev_server("/tmp/app", port=3001, api_base="https://x"):
                    pass

            self.assertIn("npm run build", str(ctx.exception).lower())
            self.assertIn(
                "error: type x is not assignable",
                str(ctx.exception).lower(),
                "exception must surface build log tail so failure is diagnosable",
            )
            popen.assert_not_called()

    def test_reuses_existing_server_without_rebuilding(self):
        """If the operator already ran `npm start` on the port, reuse it —
        skip both build and start. Avoids redundant ~60s build for repeat runs
        and matches existing behaviour for an already-listening port."""
        with patch.object(qa_devserver, "_port_open", return_value=True), \
             patch.object(qa_devserver.subprocess, "run") as build, \
             patch.object(qa_devserver.subprocess, "Popen") as popen:
            with qa_devserver.dev_server("/tmp/app", port=3001, api_base="https://x") as url:
                self.assertEqual(url, "http://localhost:3001")

            build.assert_not_called()
            popen.assert_not_called()


if __name__ == "__main__":
    unittest.main()
