"""PreToolUse hook: deny writes whose content contains known credentials.

Patterns are deliberately narrow — we only block prefixes/sentinels that have
a high signal-to-noise ratio in our agent's failure history. Catching every
possible secret is the job of a server-side scanner; this hook exists to stop
the obvious foot-guns before the file lands on disk.
"""

from __future__ import annotations

import re
from typing import Any

_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(r"sk-ant-(?:api|oat)\d{2,}-[A-Za-z0-9_\-]{20,}"),
    re.compile(r"sk-proj-[A-Za-z0-9_\-]{20,}"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"ghp_[A-Za-z0-9]{30,}"),
    re.compile(r"github_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"-----BEGIN (?:RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----"),
)

_WATCHED_TOOLS = frozenset({"Write", "Edit", "MultiEdit"})


def _extract_payload(tool_name: str, tool_input: dict[str, Any]) -> str:
    if tool_name == "Write":
        return str(tool_input.get("content", ""))
    if tool_name == "Edit":
        return str(tool_input.get("new_string", ""))
    if tool_name == "MultiEdit":
        edits = tool_input.get("edits") or []
        return "\n".join(str(edit.get("new_string", "")) for edit in edits)
    return ""


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


async def secrets_gate(
    input_data: dict[str, Any],
    _tool_use_id: str | None,
    _context: dict[str, Any],
) -> dict[str, Any]:
    tool_name = input_data.get("tool_name", "")
    if tool_name not in _WATCHED_TOOLS:
        return _allow()

    payload = _extract_payload(tool_name, input_data.get("tool_input", {}) or {})
    for pattern in _PATTERNS:
        match = pattern.search(payload)
        if match:
            return _deny(
                f"secret pattern detected ({pattern.pattern}); refusing to write "
                "credential-shaped content to disk"
            )
    return _allow()
