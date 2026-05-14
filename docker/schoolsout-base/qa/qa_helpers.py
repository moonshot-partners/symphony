"""QA self-review helpers for Symphony agents working on schoolsoutapp/fe-next-app.

Available inside the schoolsout-base Docker image at `/opt/qa/qa_helpers.py`
(on PYTHONPATH). An agent that touches fe-next-app UI code uses this to drive a
headless Chromium against a locally-running `next dev`, talking to the real
staging API, and capture proof.

The agent does **not** write Playwright. It declares assertions; the harness
owns every imperative browser step (navigation waits, scroll-into-view, the
screenshots). A screenshot is a *byproduct of an assertion* — never a manual
camera the agent aims by hand — so it always frames the element under test.

Usage sketch (the agent writes a `qa_check.py` like this):

    import sys; sys.path.insert(0, "/opt/qa")
    from qa_helpers import qa_run

    # build_sha=None → footer shows `vdev`; pass a 7-hex to assert `v<sha>`.
    with qa_run("fe-next-app", "SODEV-851", build_sha="abc1234") as qa:
        qa.login()                                  # fresh staging account + session
        qa.goto("/parents")
        qa.expect_visible('[data-testid="build-badge"]', "AC#1 - build SHA badge in footer")
        qa.expect_text('[data-testid="build-badge"]', r"^vabc1234$", "AC#1b - badge text is v<sha>")
        qa.note("AC#2 - unit tests both SHA paths", True, "npx jest site-footer: 12/12")
    sys.exit(0 if qa.passed else 1)

Each `expect_*` call:
  1. waits for the selector to be visible, then `scroll_into_view_if_needed()` —
     Playwright walks the real scroll-parent chain, so it reaches a footer that
     lives inside a nested `overflow-y-auto` div (`window.scrollTo` on the body
     does not — this app's content overflow is in an inner container, not the
     document);
  2. outlines the element and takes a viewport screenshot, plus an element-only
     screenshot, both named `NN-<pass|FAIL>-<assertion-slug>.png`;
  3. records `{name, pass, detail, screenshots}`. A FAILED assertion still
     captures — the screenshot shows *why* it failed.
At the end `qa-report.md` + `verdict.json` are written from the recorded
assertions. Sanity gate: a run with zero assertions, or zero screenshots, is
forced to FAIL — "PASS" with no probative evidence is not allowed.

Hard-won gotchas this module encodes (do not "simplify" them away):

  * Port 3001. The staging API CORS allowlist accepts `localhost:3001`, not
    arbitrary ports. Any other port -> every browser /api/v1 call fails silently
    and the session never authenticates.
  * `NEXT_PUBLIC_API_URL` must be the staging URL. `.env.local` points it at a
    non-existent `localhost:3000/api/v1`; a shell env var overrides it.
  * fe-next-app has no Next rewrite/proxy for the API — the browser hits
    `mvp.schoolsoutapp.com` directly, which is why the CORS port matters.
  * The Zustand persist store key is `"session-storage"`; after writing it you
    must `page.reload()` so `onRehydrateStorage` re-validates the token.
  * Assert on a stable `data-testid`, never a regex over whole-page text — a
    bare `v[a-z]+` happily matches "vorites" inside "favorites".
"""

from __future__ import annotations

import contextlib
import json
import os
import re
import secrets
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from urllib.parse import urlparse

STAGING_API = os.environ.get("QA_API_BASE", "https://mvp.schoolsoutapp.com/api/v1")
DEV_PORT = int(os.environ.get("QA_DEV_PORT", "3001"))  # CORS allowlist — do not change
MAILTM = "https://api.mail.tm"

# A real US zip/city the API will accept for an auto-provisioned QA profile.
_QA_PROFILE = {
    "first_name": "QA",
    "last_name": "Bot",
    "zip_code": "90210",
    "country": "United States",
    "kids_planning_count": 1,
    "terms_accepted": True,
    "time_zone": "America/Los_Angeles",
}


# --------------------------------------------------------------------------- #
# tiny JSON-over-HTTP client (stdlib only — no `requests` dep needed)
# --------------------------------------------------------------------------- #
def _http(method, url, *, body=None, headers=None, timeout=30):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode() or "{}"
            return r.status, json.loads(raw)
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, {"_raw": raw}


# --------------------------------------------------------------------------- #
# mail.tm disposable inbox
# --------------------------------------------------------------------------- #
def _members(resp):
    # mail.tm answers JSON-LD (dict with "hydra:member") or, when Accept is
    # application/json, a bare list. Normalise to a list.
    return resp["hydra:member"] if isinstance(resp, dict) and "hydra:member" in resp else resp


def _new_mailtm_inbox():
    _, domains = _http("GET", f"{MAILTM}/domains")
    domain = _members(domains)[0]["domain"]
    address = f"qa{int(time.time())}{os.getpid()}@{domain}"
    password = "Aa1!" + secrets.token_urlsafe(12)
    status, _ = _http("POST", f"{MAILTM}/accounts", body={"address": address, "password": password})
    if status >= 300:
        raise RuntimeError(f"mail.tm account creation failed: {status}")
    _, tok = _http("POST", f"{MAILTM}/token", body={"address": address, "password": password})
    return address, tok["token"]


def _wait_for_pin(token, *, tries=30, delay=2):
    headers = {"Authorization": f"Bearer {token}"}
    for _ in range(tries):
        _, listing = _http("GET", f"{MAILTM}/messages", headers=headers)
        msgs = _members(listing)
        if msgs:
            _, full = _http("GET", f"{MAILTM}/messages/{msgs[0]['id']}", headers=headers)
            text = (full.get("text") or "") + " " + " ".join(full.get("html") or [])
            m = re.search(r"\b(\d{6})\b", text)
            if m:
                return m.group(1)
        time.sleep(delay)
    raise RuntimeError("verification PIN email never arrived")


# --------------------------------------------------------------------------- #
# staging account provisioning
# --------------------------------------------------------------------------- #
def provision_account(api_base: str = STAGING_API):
    """Create + verify a fresh parents account on staging. Returns
    (email, access_token, refresh_token, user_dict). JWT lifetime ~30 min, so
    provision right before driving the browser."""
    email, mtoken = _new_mailtm_inbox()

    status, _ = _http("POST", f"{api_base}/auth/create-account", body={"email": email})
    if status >= 300:
        raise RuntimeError(f"create-account failed: {status}")

    pin = _wait_for_pin(mtoken)
    status, verify = _http("POST", f"{api_base}/auth/verify-account", body={"email": email, "pin_code": pin})
    if status >= 300:
        raise RuntimeError(f"verify-account failed: {status} {verify}")
    payload = verify.get("data", verify)
    access = payload.get("access_token")
    refresh = payload.get("refresh_token")
    if not access:
        raise RuntimeError(f"no access_token in verify response: {verify}")

    auth_h = {"Authorization": f"Bearer {access}"}
    _http("PATCH", f"{api_base}/profile", body={"profile": _QA_PROFILE}, headers=auth_h)
    status, me = _http("GET", f"{api_base}/auth/me", headers=auth_h)
    user = me.get("data", me) if status < 300 else None
    return email, access, refresh, user


# Vendor + dev-server + session helpers live in sibling modules so this file
# stays under the project length limit; re-export keeps
# `from qa_helpers import ...` single-stop.
from qa_vendor import provision_vendor_account, qarun_login_as_vendor as _qarun_login_as_vendor  # noqa: E402,F401
from qa_devserver import dev_server, _resolve_app_dir  # noqa: E402,F401
from qa_session import inject_session  # noqa: E402,F401


def api_get(path: str, access_token: str, api_base: str = STAGING_API):
    """GET an authenticated staging API endpoint. `path` may be relative
    (`/activities?...`) or absolute. Returns the parsed JSON body."""
    url = path if path.startswith("http") else f"{api_base}{path}"
    _, body = _http("GET", url, headers={"Authorization": f"Bearer {access_token}"})
    return body


def find_activity(predicate, access_token: str, *, api_base: str = STAGING_API, per_page: int = 50):
    """Return the first staging activity dict matching `predicate`, or None.
    Handy for ACs that need e.g. a long-description activity:
        find_activity(lambda a: len(a.get("description") or "") > 200, token)
    """
    body = api_get(
        f"/activities?latitude=45.52&longitude=-122.68&page=1&per_page={per_page}",
        access_token,
        api_base=api_base,
    )
    items = body.get("data") if isinstance(body, dict) else body
    for a in items or []:
        if predicate(a):
            return a
    return None


# --------------------------------------------------------------------------- #
# the QA harness — assertions that capture their own evidence
# --------------------------------------------------------------------------- #
def _slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:60]


class QaRun:
    """Yielded by `qa_run`. Drives the browser and records assertions.

    Use the `expect_*` methods for browser-observable ACs (each captures a
    screenshot bound to the assertion) and `note()` for results that aren't
    browser-observable (unit tests, grep checks). After the `with` block,
    `qa.passed` is the verdict.
    """

    def __init__(self, app_dir: str, evidence_dir: str, ticket: str, *, api_base: str = STAGING_API):
        self.app_dir = app_dir
        self.evidence_dir = os.path.abspath(evidence_dir)
        os.makedirs(self.evidence_dir, exist_ok=True)
        self.ticket = ticket
        self.api_base = api_base
        self.checks: list[dict] = []
        self.passed = False
        self._n = 0
        self.page = None
        self.base: str | None = None
        self._console: list[str] = []
        self.email = self.access = self.refresh = self.user = None
        self._nav_blocked = False

    # -- wired up by qa_run() once the browser context exists --
    def _bind(self, page, base: str, console_log: list[str]):
        self.page, self.base, self._console = page, base, console_log

    # ---- account / navigation -------------------------------------------- #
    def login(self):
        """Provision a fresh staging parents account and rehydrate the app as
        that user. Stores tokens on `self` for `find_activity`."""
        self.email, self.access, self.refresh, self.user = provision_account(self.api_base)
        ok, debug = inject_session(self.page, self.base, self.access, self.refresh, self.user)
        if not ok:
            raise RuntimeError(
                "inject_session failed — staging auth did not stick "
                f"(CORS port? token expiry?) debug={debug}"
            )
        return self

    def login_as_vendor(self, *, business_name: str = "QA Bot Co"):
        """Vendor-side counterpart to `login()` for ACs under `/business/*`.

        `BusinessProtectedLayout` redirects to `/business/signup/about-you`
        unless `user.vendor.onboarding_status` is `"completed"`/`1`. Without
        this, an agent doing `qa.login(); qa.goto("/business/dashboard")`
        records every assertion against the signup wizard. Delegates to
        `qa_vendor.qarun_login_as_vendor` so this module stays under length.
        """
        return _qarun_login_as_vendor(self, business_name=business_name)

    def try_login_as_vendor(self, *, business_name: str = "QA Bot Co"):
        """Non-raising sibling of `login_as_vendor`. Returns `(ok, err)`.

        The SODEV-765 run showed the failure mode without this: when vendor
        promotion failed, the agent wrote a hand-typed BLOCKED note that
        `verdict.json` never saw. `try_*` lets `qa_check.py` do
            ok, err = qa.try_login_as_vendor()
            if not ok: qa.note("setup blocked", False, err); return
        so the BLOCKED state is recorded as a real (failed) check and the
        verdict reflects it. KeyboardInterrupt/SystemExit propagate so an
        operator can still ^C the harness.
        """
        try:
            self.login_as_vendor(business_name=business_name)
            return True, None
        except (KeyboardInterrupt, SystemExit):
            raise
        except Exception as e:
            return False, str(e)

    def goto(self, path: str, *, wait_ms: int = 8000):
        """Navigate to `path` and detect silent middleware redirects.

        `BusinessProtectedLayout` (and other guards) can bounce the browser
        to a wizard while still resolving the navigation, so every downstream
        `expect_*` ends up framing the wrong page. Compare requested vs
        landed paths: if they diverge (with `/foo/` as the sentinel so
        `/parents` doesn't false-match `/parents-promo`), record ONE
        nav-FAIL with ONE screenshot of the redirect destination and flip
        `_nav_blocked` so subsequent asserts short-circuit with
        `[blocked: nav redirected]` instead of N identical wizard shots.
        """
        url = path if path.startswith("http") else f"{self.base}{path}"
        self.page.goto(url, wait_until="domcontentloaded", timeout=45000)
        self.page.wait_for_timeout(wait_ms)
        target = path if path.startswith("/") else urlparse(url).path
        landed = urlparse(self.page.url).path
        if landed != target and not (landed + "/").startswith(target + "/"):
            if self._nav_blocked:
                self.checks.append({
                    "name": f"navigation {path}",
                    "pass": False,
                    "detail": (
                        f"requested {target}, landed on {landed} "
                        f"[blocked: nav already redirected — first nav-FAIL screenshot is the proof]"
                    ),
                    "screenshots": [],
                })
                return self
            self._nav_blocked = True
            stem = f"{self._n + 1:02d}-FAIL-navigation-{_slug(path) or 'goto'}"
            shot = os.path.join(self.evidence_dir, f"{stem}.png")
            with contextlib.suppress(Exception):
                self.page.screenshot(path=shot, full_page=False)
            self._n += 1
            self.checks.append({
                "name": f"navigation {path}",
                "pass": False,
                "detail": f"requested {target}, landed on {landed} — middleware redirected",
                "screenshots": [os.path.basename(shot)] if os.path.exists(shot) else [],
            })
        return self

    def find_activity(self, predicate, **kw):
        return find_activity(predicate, self.access, api_base=self.api_base, **kw)

    # ---- assertions ------------------------------------------------------ #
    def expect_visible(self, selector: str, label: str, *, timeout: int = 8000) -> bool:
        """Pass iff `selector` resolves to a visible element. Scrolls it into
        view (nested scroll containers included) and screenshots it."""
        loc = self.page.locator(selector).first
        ok, detail = self._await_visible(loc, timeout)
        self._record(label, ok, detail or "element visible", loc if ok else None)
        return ok

    def expect_text(self, selector: str, pattern: str, label: str, *, timeout: int = 8000) -> bool:
        """Pass iff `selector` is visible and its inner text matches the regex
        `pattern` (use anchors — `^v[0-9a-f]{7}$`, not `v.+`)."""
        loc = self.page.locator(selector).first
        vis_ok, vis_detail = self._await_visible(loc, timeout)
        if not vis_ok:
            self._record(label, False, f"selector not visible: {vis_detail}", None)
            return False
        txt = (loc.inner_text() or "").strip()
        m = re.search(pattern, txt)
        ok = m is not None
        detail = (
            f"matched {m.group()!r} against {pattern!r}"
            if ok
            else f"text {txt[:120]!r} did not match {pattern!r}"
        )
        self._record(label, ok, detail, loc)
        return ok

    def expect_not_visible(self, selector: str, label: str, *, timeout: int = 4000) -> bool:
        """Pass iff `selector` is absent or hidden."""
        loc = self.page.locator(selector)
        try:
            cnt = loc.count()
        except Exception:
            cnt = 0
        ok = cnt == 0 or not loc.first.is_visible()
        self._record(label, ok, "absent/hidden" if ok else f"{cnt} matching element(s) still visible", None)
        return ok

    def note(self, label: str, ok: bool, detail: str = "") -> bool:
        """Record a non-browser check (unit test result, grep check, ...) into
        the same report. Has no screenshot — at least one `expect_*` must also
        run, or the run is failed by the evidence sanity gate."""
        self._record(label, bool(ok), detail, None, screenshot=False)
        return bool(ok)

    # ---- internals ------------------------------------------------------- #
    def _await_visible(self, loc, timeout: int):
        try:
            loc.wait_for(state="visible", timeout=timeout)
        except Exception as e:
            return False, f"not visible within {timeout}ms ({type(e).__name__})"
        with contextlib.suppress(Exception):
            loc.scroll_into_view_if_needed(timeout=5000)
        return True, ""

    def _record(self, label: str, ok: bool, detail: str, loc, *, screenshot: bool = True):
        if self._nav_blocked:
            self.checks.append({"name": label, "pass": False,
                                "detail": f"{detail} [blocked: nav redirected]", "screenshots": []})
            return
        self._n += 1
        stem = f"{self._n:02d}-{'pass' if ok else 'FAIL'}-{_slug(label) or f'check{self._n}'}"
        shots: list[str] = []
        if screenshot and self.page is not None:
            highlighted = False
            if loc is not None:
                with contextlib.suppress(Exception):
                    loc.evaluate(
                        "el => { el.dataset.__qaHl = el.style.outline || ''; "
                        "el.style.outline = '4px solid #ff00aa'; el.style.outlineOffset = '2px'; }"
                    )
                    highlighted = True
            with contextlib.suppress(Exception):
                vp = os.path.join(self.evidence_dir, f"{stem}.png")
                self.page.screenshot(path=vp, full_page=False)
                shots.append(os.path.basename(vp))
            if loc is not None:
                with contextlib.suppress(Exception):
                    el = os.path.join(self.evidence_dir, f"{stem}-element.png")
                    loc.screenshot(path=el)
                    shots.append(os.path.basename(el))
            if highlighted:
                with contextlib.suppress(Exception):
                    loc.evaluate("el => { el.style.outline = el.dataset.__qaHl || ''; delete el.dataset.__qaHl; }")
        self.checks.append({"name": label, "pass": bool(ok), "detail": detail, "screenshots": shots})

    def report(self, *, notes: str = "") -> bool:
        """Write `qa-report.md` + `verdict.json`. Returns the verdict.

        Evidence sanity gate: a run with no assertions, or one where no
        assertion produced a screenshot, is forced to FAIL — a green table with
        nothing to look at is not proof.
        """
        if not self.checks:
            self.checks.append(
                {"name": "evidence sanity", "pass": False,
                 "detail": "no assertions were recorded — qa_check.py exercised nothing", "screenshots": []}
            )
        elif not any(c.get("screenshots") for c in self.checks):
            self.checks.append(
                {"name": "evidence sanity", "pass": False,
                 "detail": "no screenshots captured — every browser AC must use expect_* on a real selector",
                 "screenshots": []}
            )
        self.passed = all(c["pass"] for c in self.checks)

        png = sorted(f for f in os.listdir(self.evidence_dir) if f.lower().endswith(".png"))
        lines = [
            f"# QA self-review — {self.ticket}",
            "",
            f"- Run: {datetime.now(timezone.utc).isoformat()}",
            f"- Result: {'PASS — all checks green' if self.passed else 'FAIL — see below'}",
            "",
            "| Check | Result | Detail | Evidence |",
            "| --- | --- | --- | --- |",
        ]
        for c in self.checks:
            ev = ", ".join(f"`{s}`" for s in c.get("screenshots") or []) or "—"
            lines.append(f"| {c['name']} | {'PASS' if c['pass'] else 'FAIL'} | {c.get('detail', '')} | {ev} |")
        lines += ["", "## Evidence", ""]
        lines += [f"- `{s}`" for s in png] or ["- (none captured)"]
        if os.path.exists(os.path.join(self.evidence_dir, "session.webm")):
            lines.append("- `session.webm` — full session recording")
        if notes:
            lines += ["", "## Notes", "", notes]
        with open(os.path.join(self.evidence_dir, "qa-report.md"), "w") as fh:
            fh.write("\n".join(lines) + "\n")
        with open(os.path.join(self.evidence_dir, "verdict.json"), "w") as fh:
            json.dump({"ticket": self.ticket, "pass": self.passed, "checks": self.checks}, fh, indent=2)
        return self.passed


@contextlib.contextmanager
def qa_run(app_dir: str, ticket: str, *, build_sha: str | None = None, port: int = DEV_PORT,
           api_base: str = STAGING_API, viewport=(1366, 900), headless: bool = True, notes: str = ""):
    """One-stop QA harness for a fe-next-app UI change.

    Builds `app_dir` (`npm run build`) then serves it (`npm start`) on `port`
    pointed at the staging API, launches headless Chromium recording a session
    `.webm`, and yields a `QaRun`. On exit it always writes
    `app_dir/qa-evidence/qa-report.md` + `verdict.json` (even if an assertion
    raised) and tears everything down. Production-mode boot eliminates the
    on-demand route compile that caused SODEV-879 (45s blank Playwright
    timeout against a cold `/parents`).

    If the build or server won't start, this raises `RuntimeError` before
    yielding — that
    is the WORKFLOW "BLOCKED" case (confirm pre-existing with `git stash`, then
    write a manual `write_report(..., notes=...)` and open the PR).
    """
    app_dir = _resolve_app_dir(app_dir)
    evidence_dir = os.path.join(app_dir, "qa-evidence")
    qa = QaRun(app_dir, evidence_dir, ticket, api_base=api_base)
    w, h = viewport
    with dev_server(app_dir, port=port, api_base=api_base, build_sha=build_sha) as base:
        from playwright.sync_api import sync_playwright

        with sync_playwright() as p:
            browser = p.chromium.launch(headless=headless)
            ctx = browser.new_context(
                viewport={"width": w, "height": h},
                record_video_dir=evidence_dir,
                record_video_size={"width": w, "height": h},
            )
            page = ctx.new_page()
            console_log: list[str] = []
            page.on("console", lambda m: console_log.append(f"{m.type}: {m.text[:300]}"))
            qa._bind(page, base, console_log)
            try:
                yield qa
            finally:
                with contextlib.suppress(Exception):
                    ctx.close()  # flushes the .webm
                with contextlib.suppress(Exception):
                    browser.close()
                for f in os.listdir(evidence_dir):
                    if f.endswith(".webm"):
                        os.replace(os.path.join(evidence_dir, f), os.path.join(evidence_dir, "session.webm"))
                        break
                with open(os.path.join(evidence_dir, "console.log"), "w") as fh:
                    fh.write("\n".join(console_log))
                qa.report(notes=notes)


def write_report(evidence_dir: str, ticket: str, checks: list[dict], notes: str = ""):
    """Standalone report writer for the BLOCKED path (when `qa_run` couldn't
    start the dev server). Each check is {"name": str, "pass": bool,
    "detail": str}. A `notes` string starting with "BLOCKED" marks the run as
    blocked — the verdict is then `pass: false` regardless of the (code-only)
    checks, because a run with no browser evidence has not *proven* anything.
    The PR still opens (the agent documents the blocker); the report just
    doesn't claim a green QA pass it can't back up. Returns the verdict's
    `pass` boolean."""
    evidence_dir = os.path.abspath(evidence_dir)
    os.makedirs(evidence_dir, exist_ok=True)
    blocked = notes.strip().upper().startswith("BLOCKED")
    all_pass = bool(checks) and all(c["pass"] for c in checks) and not blocked
    shots = sorted(f for f in os.listdir(evidence_dir) if f.lower().endswith(".png"))
    if blocked:
        result = "BLOCKED — browser QA could not run; see notes (code checks below are not proof)"
    elif all_pass:
        result = "PASS — all checks green"
    else:
        result = "FAIL — see below"
    lines = [
        f"# QA self-review — {ticket}",
        "",
        f"- Run: {datetime.now(timezone.utc).isoformat()}",
        f"- Result: {result}",
        "",
        "| Check | Result | Detail |",
        "| --- | --- | --- |",
    ]
    for c in checks:
        lines.append(f"| {c['name']} | {'PASS' if c['pass'] else 'FAIL'} | {c.get('detail', '')} |")
    lines += ["", "## Evidence", ""]
    lines += [f"- `{s}`" for s in shots] or ["- (none captured)"]
    if os.path.exists(os.path.join(evidence_dir, "session.webm")):
        lines.append("- `session.webm` — full session recording")
    if notes:
        lines += ["", "## Notes", "", notes]
    with open(os.path.join(evidence_dir, "qa-report.md"), "w") as fh:
        fh.write("\n".join(lines) + "\n")
    with open(os.path.join(evidence_dir, "verdict.json"), "w") as fh:
        json.dump({"ticket": ticket, "pass": all_pass, "blocked": blocked, "checks": checks}, fh, indent=2)
    return all_pass
