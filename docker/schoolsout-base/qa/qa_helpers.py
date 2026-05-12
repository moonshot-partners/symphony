"""QA self-review helpers for Symphony agents working on schoolsoutapp/fe-next-app.

Available inside the schoolsout-base Docker image at `/opt/qa/qa_helpers.py`
(on PYTHONPATH). An agent that touches fe-next-app UI code uses this to drive a
headless Chromium against a locally-running `next dev`, talking to the real
staging API, and capture screenshots + a session video as proof.

Usage sketch (the agent writes a `qa_check.py` like this):

    from qa_helpers import provision_account, inject_session, dev_server, evidence_context

    with dev_server("fe-next-app") as base:                 # starts `next dev` on :3001
        email, access, refresh, user = provision_account()  # mail.tm + staging API
        with evidence_context("fe-next-app/qa-evidence") as (page, shot):
            inject_session(page, base, access, refresh, user)
            page.goto(f"{base}/parents/...")
            shot("01-before")
            # ...interact, assert ACs...
            shot("02-after")

Hard-won gotchas this module encodes (do not "simplify" them away):

  * Port 3001. The staging API CORS allowlist accepts `localhost:3001`, not
    arbitrary ports. Any other port → every browser /api/v1 call fails silently
    and the session never authenticates.
  * `NEXT_PUBLIC_API_URL` must be the staging URL. `.env.local` points it at a
    non-existent `localhost:3000/api/v1`; a shell env var overrides it.
  * fe-next-app has no Next rewrite/proxy for the API — the browser hits
    `mvp.schoolsoutapp.com` directly, which is why the CORS port matters.
  * The Zustand persist store key is `"session-storage"`; after writing it you
    must `page.reload()` so `onRehydrateStorage` re-validates the token.
"""

from __future__ import annotations

import contextlib
import json
import os
import re
import secrets
import socket
import subprocess
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

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
    for i in range(tries):
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
# browser session injection
# --------------------------------------------------------------------------- #
def inject_session(page, base_url: str, access_token: str, refresh_token: str, user: dict):
    """Write the Zustand persist blob into localStorage and reload so the app
    rehydrates as an authenticated parent. `page` is a Playwright sync Page."""
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
    return bool(
        page.evaluate(
            "() => { try { return JSON.parse(localStorage.getItem('session-storage')||'{}')"
            ".state?.isAuthenticated || false } catch (e) { return false } }"
        )
    )


# --------------------------------------------------------------------------- #
# `next dev` lifecycle
# --------------------------------------------------------------------------- #
def _port_open(port: int) -> bool:
    with contextlib.closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM)) as s:
        return s.connect_ex(("127.0.0.1", port)) == 0


@contextlib.contextmanager
def dev_server(app_dir: str, *, port: int = DEV_PORT, api_base: str = STAGING_API,
               build_sha: str | None = None, ready_timeout: int = 240):
    """Start `npm run dev` for `app_dir` on `port`, pointed at the staging API,
    yield the base URL, and tear the process down on exit. If something is
    already listening on `port` (an earlier `next dev`), reuse it."""
    if _port_open(port):
        yield f"http://localhost:{port}"
        return

    env = {**os.environ, "PORT": str(port), "NEXT_PUBLIC_API_URL": api_base}
    if build_sha is not None:
        env["NEXT_PUBLIC_BUILD_SHA"] = build_sha
    log_path = os.path.join(app_dir, "qa-evidence", "next-dev.log")
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    log_fh = open(log_path, "w")
    proc = subprocess.Popen(
        ["npm", "run", "dev"], cwd=app_dir, env=env, stdout=log_fh, stderr=subprocess.STDOUT
    )
    try:
        deadline = time.time() + ready_timeout
        while time.time() < deadline:
            if _port_open(port):
                # give the first compile a moment so the first navigation isn't a cold miss
                time.sleep(3)
                break
            if proc.poll() is not None:
                raise RuntimeError(f"`next dev` exited early (code {proc.returncode}); see {log_path}")
            time.sleep(2)
        else:
            raise RuntimeError(f"`next dev` not ready on :{port} after {ready_timeout}s; see {log_path}")
        yield f"http://localhost:{port}"
    finally:
        proc.terminate()
        with contextlib.suppress(Exception):
            proc.wait(timeout=10)
        if proc.poll() is None:
            proc.kill()
        log_fh.close()


# --------------------------------------------------------------------------- #
# evidence capture
# --------------------------------------------------------------------------- #
@contextlib.contextmanager
def evidence_context(evidence_dir: str, *, viewport=(1366, 900), headless: bool = True):
    """Yield (page, shot) where `shot(name)` saves a full-page PNG into
    `evidence_dir` and a session `.webm` is recorded for the whole block.
    Requires `playwright` + a chromium install (both baked into schoolsout-base)."""
    from playwright.sync_api import sync_playwright

    evidence_dir = os.path.abspath(evidence_dir)
    os.makedirs(evidence_dir, exist_ok=True)
    w, h = viewport
    counter = {"n": 0}

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=headless)
        ctx = browser.new_context(
            viewport={"width": w, "height": h},
            record_video_dir=evidence_dir,
            record_video_size={"width": w, "height": h},
        )
        page = ctx.new_page()
        console_log = []
        page.on("console", lambda m: console_log.append(f"{m.type}: {m.text[:300]}"))

        def shot(name: str):
            counter["n"] += 1
            path = os.path.join(evidence_dir, f"{counter['n']:02d}-{name}.png")
            page.screenshot(path=path, full_page=True)
            return path

        try:
            yield page, shot
        finally:
            ctx.close()  # flushes the .webm
            browser.close()
            for f in os.listdir(evidence_dir):
                if f.endswith(".webm"):
                    os.replace(os.path.join(evidence_dir, f), os.path.join(evidence_dir, "session.webm"))
                    break
            with open(os.path.join(evidence_dir, "console.log"), "w") as fh:
                fh.write("\n".join(console_log))


def write_report(evidence_dir: str, ticket: str, checks: list[dict], notes: str = ""):
    """Write `qa-evidence/qa-report.md` — a human/PR-friendly summary. Each
    check is {"name": str, "pass": bool, "detail": str}. Returns True iff all
    checks passed."""
    evidence_dir = os.path.abspath(evidence_dir)
    os.makedirs(evidence_dir, exist_ok=True)
    all_pass = all(c["pass"] for c in checks) if checks else False
    shots = sorted(f for f in os.listdir(evidence_dir) if f.endswith(".png"))
    lines = [
        f"# QA self-review — {ticket}",
        "",
        f"- Run: {datetime.now(timezone.utc).isoformat()}",
        f"- Result: {'PASS — all checks green' if all_pass else 'FAIL — see below'}",
        "",
        "| Check | Result | Detail |",
        "| --- | --- | --- |",
    ]
    for c in checks:
        lines.append(f"| {c['name']} | {'PASS' if c['pass'] else 'FAIL'} | {c.get('detail', '')} |")
    lines += ["", "## Evidence", ""]
    lines += [f"- `{s}`" for s in shots]
    if os.path.exists(os.path.join(evidence_dir, "session.webm")):
        lines.append("- `session.webm` — full session recording")
    if notes:
        lines += ["", "## Notes", "", notes]
    with open(os.path.join(evidence_dir, "qa-report.md"), "w") as fh:
        fh.write("\n".join(lines) + "\n")
    with open(os.path.join(evidence_dir, "verdict.json"), "w") as fh:
        json.dump({"ticket": ticket, "pass": all_pass, "checks": checks}, fh, indent=2)
    return all_pass
