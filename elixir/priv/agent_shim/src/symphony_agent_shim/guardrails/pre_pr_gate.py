"""PreToolUse hook: block ``gh pr create`` without a QA self-review section
when the staged diff touches rendering code (SYM-1a / SYM-27).

Mirrors the body that the post-merge ``qa-evidence`` GitHub Action checks
for, but enforces it *before* the PR is opened so the agent can fix the
omission in the same run instead of leaving a red check on the PR.

Decision flow:

1. Skip non-Bash tool calls.
2. Skip commands that are not ``gh pr create`` (handles ``--draft``,
   ``--web``, and short-flag variants like ``-F`` / ``-b``).
3. Detect whether the staged diff (``git diff --cached --name-only``)
   touches a configurable view-layer glob set. Default globs cover
   ``*.tsx``, ``*.jsx``, ``*.vue``, ``*.svelte``. Override via the
   ``SYMPHONY_PRE_PR_VIEW_LAYER_GLOBS`` env var (newline-separated globs).
4. If no view-layer file is touched: pass-through allow.
5. Otherwise: extract the PR body from ``--body`` / ``--body-file`` /
   ``-b`` / ``-F``. Stdin bodies (``--body-file -``) are denied since
   the hook can't inspect them.
6. Body must contain a ``## QA self-review`` line and a
   ``- Result: PASS|FAIL|BLOCKED`` line (same regex shape as
   ``qa_evidence.ex``). Missing either → deny with a specific reason.

Substance verification of the Result verdict itself is out of scope —
SYM-1b owns that. This hook only enforces structural presence.
"""

from __future__ import annotations

import fnmatch
import os
import re
import shlex
import subprocess
from pathlib import Path
from typing import Any

_QA_HEADER_RE = re.compile(r"(?m)^## QA self-review\b")
_QA_RESULT_RE = re.compile(r"(?m)^- Result:\s*(PASS|FAIL|BLOCKED)\b")

_DEFAULT_VIEW_LAYER_GLOBS: tuple[str, ...] = (
    "*.tsx",
    "*.jsx",
    "*.vue",
    "*.svelte",
)

_GLOBS_ENV = "SYMPHONY_PRE_PR_VIEW_LAYER_GLOBS"


def _deny(reason: str) -> dict[str, Any]:
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }


def _is_pr_create(tokens: list[str]) -> bool:
    saw_gh = False
    saw_pr = False
    for tok in tokens:
        if tok == "gh":
            saw_gh = True
            continue
        if saw_gh and tok == "pr":
            saw_pr = True
            continue
        if saw_pr and tok == "create":
            return True
    return False


def _view_layer_globs() -> tuple[str, ...]:
    raw = os.environ.get(_GLOBS_ENV, "")
    if not raw.strip():
        return _DEFAULT_VIEW_LAYER_GLOBS
    parsed = tuple(line.strip() for line in raw.splitlines() if line.strip())
    return parsed or _DEFAULT_VIEW_LAYER_GLOBS


def _staged_view_layer_files(cwd: Path) -> list[str] | None:
    try:
        proc = subprocess.run(
            ["git", "diff", "--cached", "--name-only"],
            cwd=str(cwd),
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None

    if proc.returncode != 0:
        return None

    files = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
    globs = _view_layer_globs()
    return [f for f in files if any(fnmatch.fnmatch(f, g) for g in globs)]


def _extract_body(tokens: list[str], cwd: Path) -> tuple[str | None, str | None]:
    """Returns ``(body, error_reason)``.

    Body is the literal PR body text. ``error_reason`` is set when the
    body cannot be resolved (stdin pipe, missing file, etc.).
    """
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok in ("--body", "-b") and i + 1 < len(tokens):
            return tokens[i + 1], None
        if tok.startswith("--body="):
            return tok[len("--body=") :], None
        if tok in ("--body-file", "-F") and i + 1 < len(tokens):
            arg = tokens[i + 1]
            if arg == "-":
                return None, "stdin body (--body-file -) is not inspectable by pre_pr_gate"
            try:
                return Path(_resolve(arg, cwd)).read_text(encoding="utf-8"), None
            except FileNotFoundError:
                return None, f"--body-file points to missing path: {arg}"
            except OSError as exc:
                return None, f"--body-file read failed: {exc}"
        if tok.startswith("--body-file="):
            arg = tok[len("--body-file=") :]
            if arg == "-":
                return None, "stdin body (--body-file -) is not inspectable by pre_pr_gate"
            try:
                return Path(_resolve(arg, cwd)).read_text(encoding="utf-8"), None
            except FileNotFoundError:
                return None, f"--body-file points to missing path: {arg}"
            except OSError as exc:
                return None, f"--body-file read failed: {exc}"
        i += 1
    return None, None


def _resolve(arg: str, cwd: Path) -> str:
    p = Path(arg)
    return str(p if p.is_absolute() else (cwd / p))


async def pre_pr_gate(
    input_data: dict[str, Any],
    _tool_use_id: str | None,
    _context: dict[str, Any],
) -> dict[str, Any]:
    if input_data.get("tool_name") != "Bash":
        return {}

    command = (input_data.get("tool_input") or {}).get("command") or ""
    if not command:
        return {}

    try:
        tokens = shlex.split(command, posix=True)
    except ValueError:
        # Unbalanced quotes etc. — let the shell choke on its own command.
        return {}

    if not _is_pr_create(tokens):
        return {}

    cwd = Path(input_data.get("cwd") or ".")
    matches = _staged_view_layer_files(cwd)
    if matches is None or not matches:
        return {}

    body, err = _extract_body(tokens, cwd)
    if err is not None:
        return _deny(
            f"pre_pr_gate: cannot resolve PR body — {err}. "
            f"Pass the body via --body or --body-file <path>."
        )
    if body is None:
        return _deny(
            "pre_pr_gate: rendering layer changes detected "
            f"({', '.join(matches[:5])}) but gh pr create has no --body / "
            "--body-file. The QA self-review must accompany the PR — "
            "add a body with '## QA self-review' and '- Result: PASS|FAIL|BLOCKED'."
        )

    missing: list[str] = []
    if not _QA_HEADER_RE.search(body):
        missing.append("## QA self-review section header")
    if not _QA_RESULT_RE.search(body):
        missing.append("- Result: PASS|FAIL|BLOCKED line")

    if missing:
        return _deny(
            f"pre_pr_gate: rendering layer changes detected "
            f"({', '.join(matches[:5])}) but PR body is missing "
            f"{' and '.join(missing)}. Add it before opening the PR."
        )

    return {}
