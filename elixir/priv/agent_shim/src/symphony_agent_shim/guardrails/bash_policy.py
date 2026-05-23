"""PreToolUse hook: AUTO_DENY destructive Bash commands (SYM-23).

Symphony runs unattended — there is no operator to confirm a destructive
``rm -rf`` or ``DROP TABLE``. This hook intercepts the ``Bash`` tool at
PreToolUse and denies any command matching a known destructive pattern
before it executes.

Patterns are conservative (false negatives over false positives). The
matcher is pure regex — no LLM judgment, no script-content analysis. Only
the literal command string the agent passes to the SDK is inspected.

Per-project bypass: the orchestrator may forward an ALLOW list via the
``SYMPHONY_BASH_POLICY_ALLOW`` env var (newline-separated regex patterns).
A command matching an allow entry skips the destructive check entirely.

Ported from the user's own ``devflow-agent/src/devflow_agent/policy.py``
(``AUTO_DENY`` strategy only — ``LOG_AND_ALLOW`` and ``ESCALATE`` are not
useful for an unattended Symphony deployment).
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class _Pattern:
    label: str
    regex: str


_DESTRUCTIVE: tuple[_Pattern, ...] = (
    _Pattern("rm -rf", r"\brm\s+(-[rRfF]+\s*)+"),
    _Pattern("git reset --hard", r"\bgit\s+reset\s+--hard\b"),
    _Pattern("git push --force", r"\bgit\s+push\s+(--force|-f)\b"),
    _Pattern("git clean -fd", r"\bgit\s+clean\s+(-[fdx]+\s*)+"),
    _Pattern("git branch -D", r"\bgit\s+branch\s+-D\b"),
    _Pattern("DROP TABLE", r"\bDROP\s+TABLE\b"),
    _Pattern("DROP DATABASE", r"\bDROP\s+DATABASE\b"),
    _Pattern("TRUNCATE", r"\bTRUNCATE\s+(TABLE\s+)?\w+"),
    _Pattern("dd to device", r"\bdd\s+.*\bof=/dev/"),
    _Pattern("mkfs", r"\bmkfs\.\w+\s+"),
    _Pattern("chmod 777", r"\bchmod\s+0?777\b"),
    _Pattern("chown -R root", r"\bchown\s+-R\s+root\b"),
)

_COMPILED: tuple[tuple[_Pattern, re.Pattern[str]], ...] = tuple(
    (p, re.compile(p.regex, re.IGNORECASE)) for p in _DESTRUCTIVE
)

_ALLOW_ENV = "SYMPHONY_BASH_POLICY_ALLOW"
_REASON_MAX_BYTES = 512


def _deny(reason: str) -> dict[str, Any]:
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }


def _match(command: str) -> _Pattern | None:
    for pattern, regex in _COMPILED:
        if regex.search(command):
            return pattern
    return None


def _allow_list() -> tuple[re.Pattern[str], ...]:
    raw = os.environ.get(_ALLOW_ENV, "")
    compiled: list[re.Pattern[str]] = []
    for line in raw.splitlines():
        entry = line.strip()
        if not entry:
            continue
        try:
            compiled.append(re.compile(entry, re.IGNORECASE))
        except re.error:
            # Malformed allow entry — silently drop so the policy fails closed.
            continue
    return tuple(compiled)


def _is_allowed(command: str) -> bool:
    for regex in _allow_list():
        if regex.search(command):
            return True
    return False


def _truncate(command: str) -> str:
    return command if len(command) <= 200 else command[:200] + "…"


async def bash_policy_pre(
    input_data: dict[str, Any],
    _tool_use_id: str | None,
    _context: dict[str, Any],
) -> dict[str, Any]:
    if input_data.get("tool_name") != "Bash":
        return {}

    command = (input_data.get("tool_input") or {}).get("command") or ""
    if not command:
        return {}

    if _is_allowed(command):
        return {}

    match = _match(command)
    if match is None:
        return {}

    reason = (
        f"bash_policy: destructive command blocked ({match.label}). "
        f"Command: {_truncate(command)}. "
        f"To allow legitimate uses, add a regex to WORKFLOW agent_runtime.bash_policy_allow."
    )
    if len(reason) > _REASON_MAX_BYTES:
        reason = reason[: _REASON_MAX_BYTES - 1] + "…"
    return _deny(reason)
