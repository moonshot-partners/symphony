"""PreToolUse hook: prevent edits to files modified upstream on this branch.

Why: when the agent's branch trails its remote, ``Edit``/``Write`` against a
file the upstream has already touched silently overwrites those changes the
moment the agent pushes. The hook compares ``HEAD..@{upstream}`` and denies
any write whose target appears in that diff.

Implementation notes:

- Calls ``git`` as a subprocess. The hook fires on every pre-write tool call,
  so we keep the subprocess work minimal: one ``rev-parse`` to confirm we are
  inside a repo with an upstream, then one ``diff --name-only`` over the
  divergence range, scoped to the target file.
- Brand-new files (path not yet tracked, no upstream history) are always
  allowed — there is nothing to overwrite.
- If anything in this discovery path fails (no git, no upstream, detached
  HEAD), we fail-open with ``allow``. The agent already has worse problems
  than a stale-edit check in that case.
"""

from __future__ import annotations

import asyncio
import os
from pathlib import Path
from typing import Any

_WATCHED_TOOLS = frozenset({"Write", "Edit", "MultiEdit"})


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


async def _git(cwd: Path, *args: str) -> tuple[int, str]:
    proc = await asyncio.create_subprocess_exec(
        "git",
        *args,
        cwd=str(cwd),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, _stderr = await proc.communicate()
    return proc.returncode or 0, stdout.decode("utf-8", errors="replace")


async def pre_edit_overwrite_guard(
    input_data: dict[str, Any],
    _tool_use_id: str | None,
    _context: dict[str, Any],
) -> dict[str, Any]:
    tool_name = input_data.get("tool_name", "")
    if tool_name not in _WATCHED_TOOLS:
        return _allow()

    tool_input = input_data.get("tool_input", {}) or {}
    file_path_str = tool_input.get("file_path")
    cwd_str = input_data.get("cwd")
    if not file_path_str or not cwd_str:
        return _allow()

    file_path = Path(file_path_str)
    cwd = Path(cwd_str)

    # Brand-new path? Nothing to overwrite.
    if not await asyncio.to_thread(file_path.exists):
        return _allow()

    # Confirm we have an upstream to compare against.
    code, _ = await _git(cwd, "rev-parse", "--abbrev-ref", "@{upstream}")
    if code != 0:
        return _allow()

    # Restrict the diff to the target file. Use the file's path relative to
    # the repo root if possible; otherwise pass the absolute path (git accepts
    # both).
    try:
        rel = await asyncio.to_thread(os.path.relpath, file_path, cwd)
    except ValueError:
        rel = str(file_path)

    code, stdout = await _git(cwd, "diff", "--name-only", "HEAD..@{upstream}", "--", rel)
    if code != 0:
        return _allow()

    if stdout.strip():
        return _deny(
            f"upstream has commits on {rel} that this branch has not pulled; "
            "pull or rebase before editing to avoid silently overwriting them"
        )
    return _allow()
