"""Stdlib unittest suite for `qa_helpers`. The pure-HTTP helpers are tested by
monkey-patching `qa_helpers._http`; browser-driving code (Playwright) is not
exercised here — it is covered by live runs in the agent harness.

Run from the repo root:

    python3 -m unittest docker/schoolsout-base/qa/test_qa_helpers.py
"""

from __future__ import annotations

import os
import sys
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
                )
        self.assertIn("auth/me", str(ctx.exception).lower())


if __name__ == "__main__":
    unittest.main()
