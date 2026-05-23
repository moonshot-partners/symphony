"""PreToolUse / PostToolUse hooks: TDD phase-restriction (SYM-21).

Opt-in machine gate that enforces RED → GREEN → REFACTOR ordering. Pattern
follows TDFlow (arXiv:2510.23761): the agent cannot edit implementation
files until a test has been run and observed to fail in the same session.

Phase derivation (no separate state field — derived from
``last_test_exit_code``):

* ``None``  → **RED**: no test has been observed yet. Only test files may be
  edited. Impl edits are denied.
* non-zero → **GREEN**: a test failed. Impl edits are now allowed; test
  edits are denied to prevent mutating the gate.
* ``0``    → **REFACTOR**: a test is passing. Any edit is allowed.

Paths that look like neither impl nor test (docs, config, AGENTS.md) are
always allowed regardless of phase — the gate targets the TDD loop only.

State lives at ``$SYMPHONY_TDD_PHASE_STATE_DIR/<session_id>/tdd_phase.json``.
Default state dir is ``/tmp/symphony-tdd-phase``. Missing/corrupt state
defaults to RED so a wiped filesystem cannot accidentally promote the agent
to GREEN.

Default OFF: the hook is inert until ``SYMPHONY_TDD_PHASE_ENFORCEMENT`` is
set to ``enabled``. The Elixir orchestrator owns toggling that variable per
project, based on ``WORKFLOW.<project>.md`` ``tdd_phase_enforcement: enabled``.

Complementary to ``tdd_enforcer`` (pairing heuristic) — not a replacement.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

_ENABLE_ENV = "SYMPHONY_TDD_PHASE_ENFORCEMENT"
_STATE_DIR_ENV = "SYMPHONY_TDD_PHASE_STATE_DIR"
_DEFAULT_STATE_DIR = "/tmp/symphony-tdd-phase"

_WATCHED_EDIT_TOOLS = frozenset({"Write", "Edit", "MultiEdit"})

_IMPL_DIRS = ("lib", "src", "app")
_CODE_EXTS = frozenset(
    {
        ".py",
        ".ex",
        ".exs",
        ".ts",
        ".tsx",
        ".js",
        ".jsx",
        ".rb",
        ".go",
        ".rs",
        ".java",
        ".kt",
        ".swift",
        ".dart",
    }
)

_TEST_RUNNERS = (
    "mix test",
    "pytest",
    "npm test",
    "npm run test",
    "yarn test",
    "jest",
    "vitest",
    "rspec",
    "bundle exec rspec",
    "go test",
    "make test",
    "cargo test",
)


def _enabled() -> bool:
    return os.environ.get(_ENABLE_ENV, "").strip().lower() == "enabled"


def _state_path(session_id: str) -> Path:
    base = Path(os.environ.get(_STATE_DIR_ENV) or _DEFAULT_STATE_DIR)
    return base / session_id / "tdd_phase.json"


def _allow() -> dict[str, Any]:
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
        }
    }


def _deny(reason: str) -> dict[str, Any]:
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }


def _looks_like_test(path: Path) -> bool:
    name = path.name.lower()
    parts = {p.lower() for p in path.parts}
    return (
        name.startswith("test_")
        or name.endswith("_test.py")
        or "_test." in name
        or ".test." in name
        or ".spec." in name
        or "test" in parts
        or "tests" in parts
        or "spec" in parts
    )


def _looks_like_impl(path: Path) -> bool:
    if path.suffix.lower() not in _CODE_EXTS:
        return False
    parts = {p.lower() for p in path.parts}
    return any(d in parts for d in _IMPL_DIRS) and not _looks_like_test(path)


def _read_phase(session_id: str) -> int | None:
    """Returns ``last_test_exit_code`` or ``None`` (RED) on any error."""
    try:
        raw = _state_path(session_id).read_text()
    except OSError:
        return None
    try:
        data = json.loads(raw)
    except (ValueError, TypeError):
        return None
    code = data.get("last_test_exit_code") if isinstance(data, dict) else None
    return code if isinstance(code, int) else None


def _write_phase(session_id: str, exit_code: int) -> None:
    path = _state_path(session_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"last_test_exit_code": exit_code}))


def _is_test_command(command: str) -> bool:
    if not command:
        return False
    low = command.lower()
    return any(runner in low for runner in _TEST_RUNNERS)


def _exit_code_from_response(response: Any) -> int:
    """Coerces a Bash tool_response into an exit code.

    Falls back to ``0`` (success) when the response shape is unknown — the
    gate stays optimistic so an unparsable response does not strand the
    agent in GREEN forever.
    """
    if isinstance(response, dict):
        if "exit_code" in response:
            code = response["exit_code"]
            if isinstance(code, int):
                return code
        if response.get("is_error"):
            return 1
    return 0


async def tdd_phase_pre_edit(
    input_data: dict[str, Any],
    _tool_use_id: str | None,
    _context: dict[str, Any],
) -> dict[str, Any]:
    if not _enabled():
        return _allow()
    if input_data.get("tool_name") not in _WATCHED_EDIT_TOOLS:
        return _allow()

    file_path_str = (input_data.get("tool_input", {}) or {}).get("file_path")
    if not file_path_str:
        return _allow()

    path = Path(file_path_str)
    is_test = _looks_like_test(path)
    is_impl = _looks_like_impl(path)
    if not is_test and not is_impl:
        return _allow()

    session_id = input_data.get("session_id") or "unknown"
    last_code = _read_phase(session_id)

    if last_code is None:
        # RED: no test run observed.
        if is_impl:
            return _deny(
                "tdd_phase: RED phase — no failing test observed yet in this "
                "session. Write the test first, run it, then edit "
                f"{path.name}."
            )
        return _allow()

    if last_code != 0:
        # GREEN: failing test → impl only.
        if is_test:
            return _deny(
                "tdd_phase: GREEN phase — a test is currently failing. "
                "Implement the fix before mutating tests (exit_code="
                f"{last_code})."
            )
        return _allow()

    # REFACTOR: passing test → anything goes.
    return _allow()


async def tdd_phase_post_bash(
    input_data: dict[str, Any],
    _tool_use_id: str | None,
    _context: dict[str, Any],
) -> dict[str, Any]:
    if not _enabled():
        return {}
    if input_data.get("tool_name") != "Bash":
        return {}

    command = (input_data.get("tool_input", {}) or {}).get("command", "")
    if not _is_test_command(command):
        return {}

    session_id = input_data.get("session_id") or "unknown"
    exit_code = _exit_code_from_response(input_data.get("tool_response"))
    try:
        _write_phase(session_id, exit_code)
    except OSError:
        # State persistence is best-effort; failure leaves the prior
        # phase intact (or RED if none).
        pass
    return {}
