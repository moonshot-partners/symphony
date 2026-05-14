"""Browser session injection for the QA harness.

Extracted from `qa_helpers.py` so the parent module stays under the project
file-length limit. Re-exported from `qa_helpers` (and `qa_vendor` imports the
sibling directly), so the public surface stays single-stop.
"""

from __future__ import annotations

import contextlib
import json


def inject_session(page, base_url: str, access_token: str, refresh_token: str, user: dict):
    """Write the Zustand persist blob into localStorage and reload so the app
    rehydrates as an authenticated parent. `page` is a Playwright sync Page.

    Returns `(ok, debug)`:
      * `ok` — bool, True iff `localStorage.session-storage.state.isAuthenticated`
        is truthy after the reload.
      * `debug` — dict with `landed_url`, `localstorage_after` (truncated),
        `user_has_vendor`. SODEV-765 lesson: a bare bool gave the operator
        nothing to grep when the agent reported BLOCKED — the debug payload
        makes the next failure diagnosable from log lines alone (no rerun).
    """
    user_has_vendor = bool(isinstance(user, dict) and user.get("vendor"))
    session = json.dumps(
        {
            "state": {
                "user": user,
                "accessToken": access_token,
                "refreshToken": refresh_token,
                "isAuthenticated": True,
                "isPromoDismissed": False,
                "pendingClaimVendorId": None,
                "pendingClaimRequestId": None,
            },
            "version": 0,
        }
    )
    page.goto(f"{base_url}/parents", wait_until="domcontentloaded", timeout=45000)
    page.wait_for_timeout(1500)
    page.evaluate("([k, v]) => localStorage.setItem(k, v)", ["session-storage", session])
    page.reload(wait_until="domcontentloaded")
    page.wait_for_timeout(4000)
    is_auth = bool(
        page.evaluate(
            "() => { try { return JSON.parse(localStorage.getItem('session-storage')||'{}')"
            ".state?.isAuthenticated || false } catch (e) { return false } }"
        )
    )
    ls_after = ""
    with contextlib.suppress(Exception):
        ls_after = page.evaluate("() => localStorage.getItem('session-storage')") or ""
    debug = {
        "landed_url": getattr(page, "url", ""),
        "user_has_vendor": user_has_vendor,
        "localstorage_after": (ls_after[:600] + "...") if len(ls_after) > 600 else ls_after,
    }
    return is_auth, debug
