"""PreToolUse hook: regex-enforce branch naming on ``git push`` (SYM-25).

Each ``AGENTS.md`` requires branches like ``agents/sodev-NNN-short-slug``.
Today only the post-PR ``symphony-agent-gate.yml`` workflow catches off-format
branches — too late to redirect the agent cleanly. This hook fires before
``git push`` is executed and denies it when the current branch name does
not match the configured pattern, so the agent gets the rename instruction
in the same turn instead of after the PR exists.

Default pattern enforces ``{type}/{TEAM}-{N}[-slug]`` where ``type`` is
one of ``feat|fix|chore|docs|refactor|test|ci|agents`` and ``TEAM`` is
``SYM`` or ``SODEV`` (case-insensitive). Override per project via the
``SYMPHONY_BRANCH_NAMING_PATTERN`` env var (emitted by Symphony from
``WORKFLOW.<project>.md`` ``agent_runtime.branch_naming_pattern``).

Fail-open cases — guardrail enforces format, not git-repo presence:

  * ``cwd`` is not a git repo (``git rev-parse`` fails) → allow.
  * Detached HEAD (no symbolic branch) → allow.
  * Malformed override regex → allow (don't block on operator misconfig).
"""

from __future__ import annotations

import asyncio
import os
import re
import shlex
from pathlib import Path
from typing import Any

_PATTERN_ENV = "SYMPHONY_BRANCH_NAMING_PATTERN"
_DEFAULT_PATTERN = (
    r"^(feat|fix|chore|docs|refactor|test|ci|agents)/(SYM|SODEV)-[0-9]+(-[a-z0-9-]+)?$"
)


def _deny(reason: str) -> dict[str, Any]:
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }


def _is_push(command: str) -> bool:
    tokens = shlex.split(command, posix=True) if command else []
    saw_git = False
    for tok in tokens:
        if tok == "git":
            saw_git = True
            continue
        if saw_git and tok == "push":
            return True
    return False


def _compile_pattern() -> re.Pattern[str] | None:
    raw = os.environ.get(_PATTERN_ENV, "").strip() or _DEFAULT_PATTERN
    try:
        return re.compile(raw, re.IGNORECASE)
    except re.error:
        return None


async def _current_branch(cwd: Path) -> str | None:
    # ``symbolic-ref --short HEAD`` works on unborn branches (fresh ``git init``
    # before the first commit) where ``rev-parse --abbrev-ref HEAD`` exits 128.
    # Exits non-zero on detached HEAD and outside a repo — both fail-open here.
    proc = await asyncio.create_subprocess_exec(
        "git",
        "symbolic-ref",
        "--short",
        "HEAD",
        cwd=str(cwd),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )
    stdout, _ = await proc.communicate()
    if proc.returncode != 0:
        return None
    name = stdout.decode("utf-8", errors="replace").strip()
    if not name:
        return None
    return name


async def branch_name_check(
    input_data: dict[str, Any],
    _tool_use_id: str | None,
    _context: dict[str, Any],
) -> dict[str, Any]:
    if input_data.get("tool_name") != "Bash":
        return {}

    command = (input_data.get("tool_input") or {}).get("command") or ""
    if not _is_push(command):
        return {}

    pattern = _compile_pattern()
    if pattern is None:
        return {}

    cwd = Path(input_data.get("cwd") or ".")
    branch = await _current_branch(cwd)
    if branch is None:
        return {}

    if pattern.search(branch):
        return {}

    return _deny(
        f"branch_name_check: branch '{branch}' does not match the required pattern "
        f"`{pattern.pattern}`. Rename the branch before pushing (e.g. "
        f"`git branch -m agents/<ticket-id>-<slug>`), then retry."
    )
