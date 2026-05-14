"""PostToolUse hook: warn at 400 LOC, block at 600 LOC.

Aligns with the file-length policy in ``~/.claude/CLAUDE.md``. Runs after the
Write/Edit lands on disk because the goal is to nudge the agent toward
splitting the next time it touches the file, not to gate the current write.
"""

from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Any

_WARN_AT = 400
_BLOCK_AT = 600
_WATCHED_TOOLS = frozenset({"Write", "Edit", "MultiEdit"})


def _count_lines(path: Path) -> int | None:
    if not path.exists() or not path.is_file():
        return None
    try:
        with path.open("rb") as fh:
            return sum(1 for _ in fh)
    except OSError:
        return None


def _noop() -> dict[str, Any]:
    return {}


def _warn(line_count: int, path: str) -> dict[str, Any]:
    return {
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": (
                f"file_size_check warning: {path} is now {line_count} lines "
                f"(soft limit {_WARN_AT}, hard limit {_BLOCK_AT}). "
                "Plan a split before the next edit."
            ),
        }
    }


def _block(line_count: int, path: str) -> dict[str, Any]:
    return {
        "decision": "block",
        "reason": (
            f"file_size_check: {path} is {line_count} lines, over the "
            f"{_BLOCK_AT}-line hard limit. Split the module before continuing."
        ),
    }


async def file_size_check(
    input_data: dict[str, Any],
    _tool_use_id: str | None,
    _context: dict[str, Any],
) -> dict[str, Any]:
    tool_name = input_data.get("tool_name", "")
    if tool_name not in _WATCHED_TOOLS:
        return _noop()

    file_path_str = (input_data.get("tool_input", {}) or {}).get("file_path")
    if not file_path_str:
        return _noop()

    path = Path(file_path_str)
    line_count = await asyncio.to_thread(_count_lines, path)
    if line_count is None:
        return _noop()

    if line_count >= _BLOCK_AT:
        return _block(line_count, str(path))
    if line_count >= _WARN_AT:
        return _warn(line_count, str(path))
    return _noop()
