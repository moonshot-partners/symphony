"""Stdlib unittest suite for `qa_helpers`. The pure-HTTP helpers are tested by
monkey-patching `qa_helpers._http`; browser-driving code (Playwright) is not
exercised here — it is covered by live runs in the agent harness.

Run from the repo root:

    python3 -m unittest docker/schoolsout-base/qa/test_qa_helpers.py
"""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(__file__))

import qa_helpers  # noqa: E402
import qa_vendor  # noqa: E402


class ProvisionVendorAccountTest(unittest.TestCase):
    """`provision_vendor_account` is the bridge from a JWT-authenticated parents
    account to a vendor account the business UI will let in. The middleware in
    `business-protected-layout.tsx` redirects to the signup wizard while
    `user.vendor.onboarding_status` is not `"completed"`/`1`, so the helper must
    (a) POST `/api/v1/vendor` with those fields populated and (b) refetch the
    user from `/auth/me` so the caller can re-inject the session with the new
    vendor attached.
    """

    def test_posts_vendor_with_completed_onboarding_and_refetches_me(self):
        calls: list[dict] = []

        def fake_http(method, url, *, body=None, headers=None, timeout=30):
            calls.append({"method": method, "url": url, "body": body, "headers": headers})
            if method == "POST" and url.endswith("/vendor"):
                return 201, {"data": {"id": 42, "business_name": body["vendor"]["business_name"]}}
            if method == "GET" and url.endswith("/auth/me"):
                return 200, {
                    "data": {
                        "email": "qa@example.com",
                        "vendor": {
                            "id": 42,
                            "business_name": "QA Test Co",
                            "onboarding_status": "completed",
                        },
                    }
                }
            raise AssertionError(f"unexpected HTTP call: {method} {url}")

        with patch.object(qa_vendor, "_http", side_effect=fake_http):
            user = qa_vendor.provision_vendor_account(
                access_token="fake-jwt",
                business_name="QA Test Co",
                email="qa-fixture@example.com",
                api_base="https://staging.example.com/api/v1",
            )

        self.assertEqual(len(calls), 2, f"expected POST+GET, got {calls}")

        post = calls[0]
        self.assertEqual(post["method"], "POST")
        self.assertTrue(post["url"].endswith("/vendor"), post["url"])
        self.assertEqual(post["headers"].get("Authorization"), "Bearer fake-jwt")
        vendor_body = post["body"]["vendor"]
        self.assertEqual(vendor_body["business_name"], "QA Test Co")
        self.assertEqual(
            vendor_body["onboarding_status"],
            "completed",
            "must skip /business/onboarding/step-1 redirect",
        )
        self.assertEqual(
            vendor_body["email"],
            "qa-fixture@example.com",
            "Vendor model validates email_format — must be sent",
        )
        self.assertTrue(vendor_body.get("legal_first_name"))
        self.assertTrue(vendor_body.get("legal_last_name"))

        get = calls[1]
        self.assertEqual(get["method"], "GET")
        self.assertTrue(get["url"].endswith("/auth/me"))
        self.assertEqual(get["headers"].get("Authorization"), "Bearer fake-jwt")

        self.assertIn("vendor", user)
        self.assertEqual(user["vendor"]["onboarding_status"], "completed")

    def test_raises_runtime_error_when_create_vendor_returns_non_2xx(self):
        def fake_http(method, url, *, body=None, headers=None, timeout=30):
            return 422, {"error": {"code": "invalid_parameters"}}

        with patch.object(qa_vendor, "_http", side_effect=fake_http):
            with self.assertRaises(RuntimeError) as ctx:
                qa_vendor.provision_vendor_account(
                    access_token="fake-jwt",
                    business_name="x",
                    email="qa@example.com",
                )
        self.assertIn("create-vendor", str(ctx.exception).lower())

    def test_raises_runtime_error_when_me_refetch_fails(self):
        def fake_http(method, url, *, body=None, headers=None, timeout=30):
            if method == "POST":
                return 201, {"data": {"id": 1}}
            return 401, {"error": "unauthorized"}

        with patch.object(qa_vendor, "_http", side_effect=fake_http):
            with self.assertRaises(RuntimeError) as ctx:
                qa_vendor.provision_vendor_account(
                    access_token="fake-jwt",
                    business_name="QA Co",
                    email="qa@example.com",
                )
        self.assertIn("auth/me", str(ctx.exception).lower())


class InjectSessionDiagnosticsTest(unittest.TestCase):
    """`inject_session` must return `(ok, debug)` — the boolean alone hides WHY
    auth didn't stick. When the SODEV-765 agent run reported BLOCKED, the
    operator had nothing to grep — no localStorage dump, no landed URL, no
    user-shape summary. Returning a debug dict makes the next failure
    diagnosable from log lines alone (no rerun needed).
    """

    def _fake_page(self, *, url_after_reload, ls_after_reload, ls_eval_value):
        evals = {"ls_after_reload": ls_after_reload, "is_auth": ls_eval_value}

        class _P:
            url = url_after_reload

            def goto(self, *_a, **_kw):
                pass

            def wait_for_timeout(self, _ms):
                pass

            def reload(self, **_):
                pass

            def evaluate(self, expr, *_a, **_kw):
                # setItem call — no return
                if "setItem" in expr:
                    return None
                if "JSON.parse" in expr and "isAuthenticated" in expr:
                    return evals["is_auth"]
                if "getItem" in expr:
                    return evals["ls_after_reload"]
                return None

        return _P()

    def test_returns_tuple_with_debug_on_success(self):
        page = self._fake_page(
            url_after_reload="http://localhost:3001/parents",
            ls_after_reload='{"state":{"isAuthenticated":true,"user":{"id":1,"vendor":{"id":42}}}}',
            ls_eval_value=True,
        )

        result = qa_helpers.inject_session(
            page, "http://localhost:3001", "acc", "ref", {"id": 1, "vendor": {"id": 42}}
        )

        self.assertIsInstance(result, tuple, "must return (ok, debug) tuple, not bool")
        self.assertEqual(len(result), 2)
        ok, debug = result
        self.assertTrue(ok)
        self.assertIsInstance(debug, dict)
        self.assertIn("landed_url", debug, "debug must record where reload landed")
        self.assertEqual(debug["landed_url"], "http://localhost:3001/parents")
        self.assertIn("user_has_vendor", debug, "debug must declare whether injected user carried vendor — drives vendor-flow root-cause analysis")
        self.assertTrue(debug["user_has_vendor"])

    def test_returns_tuple_with_debug_on_failure(self):
        page = self._fake_page(
            url_after_reload="http://localhost:3001/business/signin",
            ls_after_reload='{"state":{"isAuthenticated":false,"user":null}}',
            ls_eval_value=False,
        )

        ok, debug = qa_helpers.inject_session(
            page, "http://localhost:3001", "acc", "ref", {"id": 1, "vendor": None}
        )

        self.assertFalse(ok)
        self.assertEqual(debug["landed_url"], "http://localhost:3001/business/signin")
        self.assertFalse(debug["user_has_vendor"])
        self.assertIn(
            "localstorage_after",
            debug,
            "debug must include localStorage snapshot so the operator can see what Zustand kept",
        )


class _FakePage:
    """Minimal Playwright Page double for tests that need to drive `QaRun.goto`
    and `_record` without a real browser. `final_url` is what `page.url` returns
    after `goto()` runs — the "where the middleware actually landed us" value.
    """

    def __init__(self, final_url: str):
        self.url = final_url
        self.goto_calls: list[str] = []
        self.screenshot_paths: list[str] = []

    def goto(self, url, **_):
        self.goto_calls.append(url)

    def wait_for_timeout(self, _ms):
        pass

    def screenshot(self, *, path, **_):
        self.screenshot_paths.append(path)
        with open(path, "wb") as fh:
            fh.write(b"\x89PNG\r\n\x1a\n")

    def reload(self, **_):
        pass

    def evaluate(self, *_args, **_kw):
        return None


class _FakeLoc:
    """Locator double that simulates "not visible" — `wait_for` raises, just
    like Playwright's TimeoutError when an element never appears."""

    @property
    def first(self):
        return self

    def wait_for(self, **_):
        raise RuntimeError("not visible")

    def count(self):
        return 0

    def is_visible(self):
        return False

    def scroll_into_view_if_needed(self, **_):
        pass

    def evaluate(self, *_args, **_kw):
        return None

    def screenshot(self, *, path, **_):
        with open(path, "wb") as fh:
            fh.write(b"\x89PNG\r\n\x1a\n")


class QaRunLoginAsVendorTest(unittest.TestCase):
    """`QaRun.login_as_vendor` is the one-stop vendor entry point. Without it
    an agent working on `/business/*` has to discover three loosely-related
    helpers (`provision_account`, `provision_vendor_account`, `inject_session`)
    and chain them in the right order — and forgetting any of the three lets
    `BusinessProtectedLayout` bounce the browser to `/business/signup/about-you`,
    where every downstream `expect_*` captures a misleading screenshot of the
    wizard. So one method that does all three, in order, is mandatory.
    """

    def test_provisions_parents_promotes_to_vendor_and_reinjects(self):
        provision_calls: list[str] = []
        vendor_calls: list[dict] = []
        inject_calls: list[dict] = []

        def fake_provision(api_base):
            provision_calls.append(api_base)
            return (
                "qa@example.com",
                "access-tok",
                "refresh-tok",
                {"id": 1, "email": "qa@example.com"},
            )

        def fake_vendor(*, access_token, business_name, email, api_base, **_kw):
            vendor_calls.append(
                {"access_token": access_token, "business_name": business_name, "email": email}
            )
            return {
                "id": 1,
                "email": email,
                "vendor": {
                    "id": 42,
                    "business_name": business_name,
                    "onboarding_status": "completed",
                },
            }

        def fake_inject(page, base, access, refresh, user):
            inject_calls.append({"access": access, "refresh": refresh, "user": user})
            return True, {"landed_url": f"{base}/parents", "user_has_vendor": True}

        with patch.object(qa_helpers, "provision_account", fake_provision), patch.object(
            qa_vendor, "provision_vendor_account", fake_vendor
        ), patch.object(qa_helpers, "inject_session", fake_inject):
            qa = qa_helpers.QaRun(
                app_dir="/tmp", evidence_dir="/tmp", ticket="SODEV-TEST"
            )
            qa.page = _FakePage("http://localhost:3001/business/dashboard")
            qa.base = "http://localhost:3001"
            qa.login_as_vendor(business_name="QA Co")

        self.assertEqual(len(provision_calls), 1, "must provision exactly one parents account")
        self.assertEqual(len(vendor_calls), 1, "must promote to vendor exactly once")
        self.assertEqual(vendor_calls[0]["business_name"], "QA Co")
        self.assertEqual(
            vendor_calls[0]["email"],
            "qa@example.com",
            "vendor must reuse the parents email so it stays unique + valid",
        )
        self.assertEqual(vendor_calls[0]["access_token"], "access-tok")
        self.assertEqual(len(inject_calls), 1, "must re-inject the session once after promotion")
        self.assertEqual(
            inject_calls[0]["user"]["vendor"]["onboarding_status"],
            "completed",
            "session must carry the completed vendor — middleware reads this",
        )
        self.assertEqual(qa.email, "qa@example.com")
        self.assertEqual(qa.access, "access-tok")
        self.assertEqual(qa.user["vendor"]["business_name"], "QA Co")


class QaRunTryLoginAsVendorTest(unittest.TestCase):
    """`try_login_as_vendor` is the non-raising sibling of `login_as_vendor`.
    Without it, an agent script that hits a vendor-promotion failure must
    catch the RuntimeError manually — and the SODEV-765 agent run shows what
    happens when that catch is missing: the agent invents a BLOCKED note
    in qa-report.md by hand instead of letting the harness record it. The
    `try_*` form returns `(ok, err)` so the agent's script can do
    `ok, err = qa.try_login_as_vendor(); if not ok: qa.note(...)` and the
    harness owns the BLOCKED record + verdict.json.
    """

    def test_returns_true_none_on_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            qa = qa_helpers.QaRun(app_dir=tmp, evidence_dir=tmp, ticket="SODEV-TEST")
            qa.page = _FakePage("http://localhost:3001/business/dashboard")
            qa.base = "http://localhost:3001"

            def fake_login_as_vendor(*, business_name):
                return qa

            with patch.object(qa, "login_as_vendor", fake_login_as_vendor):
                ok, err = qa.try_login_as_vendor(business_name="QA Co")

            self.assertTrue(ok)
            self.assertIsNone(err)

    def test_returns_false_with_error_when_login_raises(self):
        with tempfile.TemporaryDirectory() as tmp:
            qa = qa_helpers.QaRun(app_dir=tmp, evidence_dir=tmp, ticket="SODEV-TEST")
            qa.page = _FakePage("http://localhost:3001/")
            qa.base = "http://localhost:3001"

            def fake_login_as_vendor(*, business_name):
                raise RuntimeError("inject_session failed — staging auth did not stick debug={'landed_url': '/business/signin'}")

            with patch.object(qa, "login_as_vendor", fake_login_as_vendor):
                ok, err = qa.try_login_as_vendor(business_name="QA Co")

            self.assertFalse(ok)
            self.assertIsNotNone(err)
            self.assertIn(
                "inject_session failed",
                err,
                "err must surface the original exception text so the harness BLOCKED note is self-explanatory",
            )

    def test_does_not_swallow_keyboardinterrupt_or_systemexit(self):
        """The catch must be narrow — KeyboardInterrupt and SystemExit must
        propagate, or Ctrl-C against a stuck Playwright session gets eaten.
        """
        with tempfile.TemporaryDirectory() as tmp:
            qa = qa_helpers.QaRun(app_dir=tmp, evidence_dir=tmp, ticket="SODEV-TEST")
            qa.page = _FakePage("http://localhost:3001/")
            qa.base = "http://localhost:3001"

            def fake_login_as_vendor(*, business_name):
                raise KeyboardInterrupt()

            with patch.object(qa, "login_as_vendor", fake_login_as_vendor):
                with self.assertRaises(KeyboardInterrupt):
                    qa.try_login_as_vendor(business_name="QA Co")


class QaRunGotoRedirectTest(unittest.TestCase):
    """`QaRun.goto` is the only place that knows where the browser actually
    landed. If middleware silently redirects (e.g. BusinessProtectedLayout
    bouncing to the signup wizard when no vendor is attached), every downstream
    `expect_*` ends up framing the wrong page — and `_record()`'s fallback
    viewport screenshot mislabels the wizard as evidence for whatever AC was
    being asserted. So `goto` must compare requested vs landed paths, record
    ONE navigation FAIL with ONE screenshot of the redirect destination, and
    flip a flag so subsequent `expect_*` calls add `[blocked: nav redirected]`
    to their detail without taking more identical screenshots.
    """

    def _qa(self, tmp, final_url):
        qa = qa_helpers.QaRun(app_dir=tmp, evidence_dir=tmp, ticket="SODEV-TEST")
        qa.page = _FakePage(final_url)
        qa.base = "http://localhost:3001"
        return qa

    def test_redirect_records_one_nav_fail_with_one_screenshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            qa = self._qa(tmp, "http://localhost:3001/business/signup/about-you")
            qa.goto("/business/dashboard", wait_ms=0)

            self.assertEqual(len(qa.checks), 1, f"expected exactly one nav-FAIL, got {qa.checks}")
            check = qa.checks[0]
            self.assertFalse(check["pass"])
            self.assertIn("navigation", check["name"])
            self.assertIn("/business/dashboard", check["name"])
            self.assertIn(
                "signup/about-you",
                check["detail"],
                "detail must name the redirect destination so the report is actionable",
            )
            self.assertEqual(
                len(check["screenshots"]),
                1,
                "nav-FAIL gets exactly one viewport screenshot of the wrong landing page",
            )
            self.assertTrue(qa._nav_blocked, "must flip the block flag for downstream asserts")

    def test_on_target_records_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            qa = self._qa(tmp, "http://localhost:3001/business/dashboard?ref=foo")
            qa.goto("/business/dashboard", wait_ms=0)

            self.assertEqual(qa.checks, [], "no nav-FAIL when landed URL matches target path")
            self.assertFalse(qa._nav_blocked)

    def test_deeper_path_counts_as_on_target(self):
        """Going to `/business` and landing on `/business/dashboard` is a
        legitimate landing — the middleware promoted us to a more specific
        route. Only treat as a redirect when the landed path leaves the
        requested subtree."""
        with tempfile.TemporaryDirectory() as tmp:
            qa = self._qa(tmp, "http://localhost:3001/business/dashboard")
            qa.goto("/business", wait_ms=0)
            self.assertEqual(qa.checks, [])
            self.assertFalse(qa._nav_blocked)

    def test_sibling_path_does_not_match(self):
        """`/parents` and `/parents-promo` are different pages — the bare
        prefix check would have false-negatived this one. The trailing-slash
        sentinel must keep them apart."""
        with tempfile.TemporaryDirectory() as tmp:
            qa = self._qa(tmp, "http://localhost:3001/parents-promo-modal")
            qa.goto("/parents", wait_ms=0)
            self.assertEqual(len(qa.checks), 1)
            self.assertTrue(qa._nav_blocked)

    def test_subsequent_goto_skipped_no_redundant_screenshot(self):
        """After the first goto detected a redirect and flipped `_nav_blocked`,
        a second `goto()` call must NOT take another viewport screenshot of the
        same (still-redirected) landing page. The first nav-FAIL screenshot is
        already the proof; a second one only inflates evidence_dir with
        byte-identical PNGs (seen in SODEV-765 agent run: two `01-FAIL-*.png`
        files with EXACT same 82660-byte size — both shots of the same
        redirect destination). Record the second nav-FAIL with empty
        `screenshots` so the report still names it, without duplicating proof.
        """
        with tempfile.TemporaryDirectory() as tmp:
            qa = self._qa(tmp, "http://localhost:3001/business/signup/about-you")
            qa.goto("/business/dashboard", wait_ms=0)
            self.assertTrue(qa._nav_blocked)
            self.assertEqual(len(qa.checks), 1)
            first_screenshots = qa.checks[0]["screenshots"]
            self.assertEqual(len(first_screenshots), 1)

            qa.goto("/business/settings/account", wait_ms=0)

            self.assertEqual(len(qa.checks), 2, "second goto still recorded")
            second = qa.checks[1]
            self.assertEqual(second["name"], "navigation /business/settings/account")
            self.assertFalse(second["pass"])
            self.assertIn(
                "blocked: nav already redirected",
                second["detail"].lower(),
                "second nav-FAIL must declare WHY no new screenshot — to make the report self-explanatory",
            )
            self.assertEqual(
                second["screenshots"],
                [],
                "second redirect during blocked state must NOT take a screenshot — first nav-FAIL is the proof",
            )

    def test_subsequent_expect_visible_skipped_with_no_screenshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            qa = self._qa(tmp, "http://localhost:3001/business/signup/about-you")
            qa.goto("/business/dashboard", wait_ms=0)
            qa.page.locator = lambda _sel: _FakeLoc()

            ok = qa.expect_visible('[data-testid="thing"]', "AC#1 - thing", timeout=10)

            self.assertFalse(ok)
            ac = qa.checks[-1]
            self.assertEqual(ac["name"], "AC#1 - thing")
            self.assertFalse(ac["pass"])
            self.assertIn(
                "blocked: nav redirected",
                ac["detail"].lower(),
                "downstream FAILs must declare WHY — nav block, not 'not visible'",
            )
            self.assertEqual(
                ac["screenshots"],
                [],
                "no more viewport screenshots — the nav-FAIL screenshot is the proof",
            )


if __name__ == "__main__":
    unittest.main()
