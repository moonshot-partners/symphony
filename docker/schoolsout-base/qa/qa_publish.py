"""Bridge Playwright Test JSON results into Symphony's `qa-evidence/` channel.

Symphony's `QaEvidence.maybe_publish/2` (Elixir) reads
`<workspace>/fe-next-app/qa-evidence/` after the agent finishes — screenshots
go to a Linear comment, `session.webm` is uploaded, the `qa-report.md` table is
inlined. The legacy `qa_helpers.py` harness wrote that dir directly. The
project-owned Playwright Test path writes its artifacts elsewhere
(`test-results/`, `playwright-report/`, `test-results/results.json`), so this
adapter exists to translate.

Run from `fe-next-app/` after `npm run e2e`:

    python /opt/qa/qa_publish.py

It reads `test-results/results.json`, copies one screenshot per test (the most
recent attempt's last screenshot — that's what `screenshot: "only-on-failure"`
yields, and a fresh shot is more probative than the trace's intermediate
frames) and the per-test video into `qa-evidence/`, and writes a
`qa-report.md` table + `verdict.json` in the same shape as the legacy harness
so Symphony's uploader needs no change.

`--blocked "<reason>"` is the BLOCKED escape hatch — when the dev server
itself never came up, the JSON report won't exist; the adapter writes a
`verdict.pass=false` report carrying the reason instead.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from datetime import datetime, timezone


def _slug(text: str) -> str:
    out = "".join(c if c.isalnum() else "-" for c in text.lower())
    return "-".join(filter(None, out.split("-")))[:60]


def _iter_tests(suites: list[dict]):
    for suite in suites or []:
        for inner in suite.get("suites") or []:
            yield from _iter_tests([inner])
        for spec in suite.get("specs") or []:
            for t in spec.get("tests") or []:
                yield spec, t


def _pick_attachments(attachments: list[dict]) -> tuple[str | None, str | None, str | None]:
    shot = None
    video = None
    trace = None
    for a in attachments or []:
        path = a.get("path")
        if not path:
            continue
        name = a.get("name", "").lower()
        ctype = a.get("contentType", "").lower()
        if name == "screenshot" or ctype.startswith("image/"):
            shot = path
        elif name == "video" or ctype.startswith("video/"):
            video = path
        elif name == "trace" or ctype == "application/zip":
            trace = path
    return shot, video, trace


def _collect_checks(results_json: dict, evidence_dir: str) -> list[dict]:
    checks: list[dict] = []
    n = 0
    for spec, test in _iter_tests(results_json.get("suites") or []):
        title = spec.get("title") or test.get("title") or "unnamed"
        results = test.get("results") or []
        if not results:
            checks.append({"name": title, "pass": False, "detail": "no result recorded", "screenshots": []})
            continue
        last = results[-1]
        status = last.get("status") or "unknown"
        ok = status == "passed"
        duration_ms = last.get("duration") or 0
        detail = f"{status} in {duration_ms}ms"
        errors = last.get("errors") or []
        if errors:
            msg = (errors[0].get("message") or "").splitlines()[0][:240]
            detail = f"{status}: {msg}"

        shot_src, video_src, trace_src = _pick_attachments(last.get("attachments") or [])
        n += 1
        stem = f"{n:02d}-{'pass' if ok else 'FAIL'}-{_slug(title) or f'test{n}'}"
        shots: list[str] = []
        if shot_src and os.path.isfile(shot_src):
            dest = os.path.join(evidence_dir, f"{stem}.png")
            shutil.copyfile(shot_src, dest)
            shots.append(os.path.basename(dest))
        if video_src and os.path.isfile(video_src):
            # First video wins as session.webm — same convention as
            # qa_helpers.qa_run (record_video_dir + rename on close).
            session = os.path.join(evidence_dir, "session.webm")
            if not os.path.exists(session):
                shutil.copyfile(video_src, session)
        if trace_src and os.path.isfile(trace_src):
            # First trace wins as session.zip — open in https://trace.playwright.dev
            session_trace = os.path.join(evidence_dir, "session.zip")
            if not os.path.exists(session_trace):
                shutil.copyfile(trace_src, session_trace)
        checks.append({"name": title, "pass": ok, "detail": detail, "screenshots": shots})
    return checks


def _write_report(evidence_dir: str, ticket: str, checks: list[dict], *, blocked_reason: str | None) -> bool:
    blocked = blocked_reason is not None
    all_pass = bool(checks) and all(c["pass"] for c in checks) and not blocked
    if blocked:
        result = "BLOCKED — Playwright run could not produce evidence"
    elif all_pass:
        result = "PASS — all checks green"
    else:
        result = "FAIL — see below"

    pngs = sorted(f for f in os.listdir(evidence_dir) if f.lower().endswith(".png"))
    lines = [
        f"# QA self-review — {ticket}",
        "",
        f"- Run: {datetime.now(timezone.utc).isoformat()}",
        f"- Result: {result}",
        "",
        "| Check | Result | Detail | Evidence |",
        "| --- | --- | --- | --- |",
    ]
    if blocked:
        lines.append(f"| (blocked) | FAIL | {blocked_reason} | — |")
    for c in checks:
        ev = ", ".join(f"`{s}`" for s in c.get("screenshots") or []) or "—"
        lines.append(f"| {c['name']} | {'PASS' if c['pass'] else 'FAIL'} | {c.get('detail', '')} | {ev} |")
    lines += ["", "## Evidence", ""]
    lines += [f"- `{s}`" for s in pngs] or ["- (none captured)"]
    if os.path.exists(os.path.join(evidence_dir, "session.webm")):
        lines.append("- `session.webm` — full session recording")
    if os.path.exists(os.path.join(evidence_dir, "session.zip")):
        lines.append("- `session.zip` — Playwright trace (open at https://trace.playwright.dev)")
    if blocked:
        lines += ["", "## Notes", "", f"BLOCKED: {blocked_reason}"]

    with open(os.path.join(evidence_dir, "qa-report.md"), "w") as fh:
        fh.write("\n".join(lines) + "\n")
    with open(os.path.join(evidence_dir, "verdict.json"), "w") as fh:
        json.dump({"ticket": ticket, "pass": all_pass, "blocked": blocked, "checks": checks}, fh, indent=2)
    return all_pass


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", default="test-results/results.json",
                        help="Playwright JSON report (default: test-results/results.json)")
    parser.add_argument("--evidence-dir", default="qa-evidence",
                        help="Output directory (default: qa-evidence)")
    parser.add_argument("--ticket", default=os.environ.get("QA_TICKET", "qa"),
                        help="Ticket identifier for the report header (default: $QA_TICKET or 'qa')")
    parser.add_argument("--blocked", default=None,
                        help="Mark this run BLOCKED with the given reason — use when the dev server never came up")
    args = parser.parse_args(argv)

    evidence_dir = os.path.abspath(args.evidence_dir)
    os.makedirs(evidence_dir, exist_ok=True)

    checks: list[dict] = []
    if args.blocked is None:
        if not os.path.isfile(args.results):
            print(f"qa_publish: {args.results} missing — pass --blocked '<reason>' if the run never produced one",
                  file=sys.stderr)
            return 2
        with open(args.results) as fh:
            data = json.load(fh)
        checks = _collect_checks(data, evidence_dir)

    ok = _write_report(evidence_dir, args.ticket, checks, blocked_reason=args.blocked)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
