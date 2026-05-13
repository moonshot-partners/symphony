"""Vendor-account provisioning for the QA harness.

Kept in its own module (rather than appended to `qa_helpers.py`) so the QA
helper stack stays under the project file-length limit, and so the parents-only
test path in `qa_helpers` can be exercised in isolation.

Public surface: `provision_vendor_account` is re-exported from `qa_helpers`,
so an agent's `qa_check.py` keeps importing from one place.
"""

from __future__ import annotations

from qa_helpers import STAGING_API, _http  # noqa: E402 — sibling-module helpers


def provision_vendor_account(
    *,
    access_token: str,
    business_name: str,
    email: str,
    api_base: str = STAGING_API,
    legal_first_name: str = "QA",
    legal_last_name: str = "Bot",
):
    """Promote a JWT-authenticated parents account to a vendor account that the
    business UI will let in. Returns the refreshed user dict (now carrying
    `vendor`) so the caller can re-inject the Zustand session.

    Why it has to do both calls: `business-protected-layout.tsx` reads
    `user.vendor.onboarding_status` from the Zustand session — if it's not
    `"completed"`/`1`, the user is redirected back to the signup wizard. So we
    POST a vendor with `onboarding_status: "completed"`, then GET `/auth/me`
    so the harness can reload the session with the new `user.vendor` baked in.

    `email` is required: the `Vendor` model validates
    `uniqueness: true, email_format: true`, and the user-facing endpoint
    doesn't auto-derive it from the account — pass the freshly-minted parents
    email from `provision_account` so it's both unique and valid.

    `access_token` must be a fresh JWT from `provision_account`. Each account
    can hold only one vendor — call this once per fresh account.
    """
    auth = {"Authorization": f"Bearer {access_token}"}
    body = {
        "vendor": {
            "business_name": business_name,
            "email": email,
            "legal_first_name": legal_first_name,
            "legal_last_name": legal_last_name,
            "onboarding_status": "completed",
        }
    }
    status, resp = _http("POST", f"{api_base}/vendor", body=body, headers=auth)
    if status >= 300:
        raise RuntimeError(f"create-vendor failed: {status} {resp}")

    status, me = _http("GET", f"{api_base}/auth/me", headers=auth)
    if status >= 300:
        raise RuntimeError(f"auth/me refresh after vendor create failed: {status} {me}")
    return me.get("data", me)


def qarun_login_as_vendor(qa, *, business_name: str = "QA Bot Co"):
    """`QaRun.login_as_vendor` delegates here so the parent module stays under
    its length limit.

    Same flow as `QaRun.login` for parents, plus the vendor promotion in
    between: provision a fresh parents account, POST `/vendor` with
    `onboarding_status="completed"`, re-inject the Zustand session with the
    new `user.vendor` so `BusinessProtectedLayout` lets the browser into
    `/business/*` without bouncing to the signup wizard.
    """
    from qa_helpers import inject_session, provision_account

    qa.email, qa.access, qa.refresh, _parents = provision_account(qa.api_base)
    qa.user = provision_vendor_account(
        access_token=qa.access,
        business_name=business_name,
        email=qa.email,
        api_base=qa.api_base,
    )
    if not inject_session(qa.page, qa.base, qa.access, qa.refresh, qa.user):
        raise RuntimeError(
            "inject_session failed after vendor promotion — staging auth did not stick"
        )
    return qa
