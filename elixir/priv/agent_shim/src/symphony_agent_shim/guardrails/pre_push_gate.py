"""PreToolUse hook: run the project's tests before letting ``git push`` go out.

Stack detection is by file presence at ``cwd``. We pick the first marker we
recognise and run the canonical test command for that stack. Multi-stack
projects get their dominant runner; the hook does not chain runners.

Detection table (first match wins):

    Makefile           → make test
    pyproject.toml     → pytest -q
    package.json       → npm test --silent
    mix.exs            → mix test
    Gemfile            → bundle exec rspec
    go.mod             → go test ./...

If none of these markers are present we allow — the hook does not invent a
test command. Tests are taken to be a hard gate; non-zero exit → deny push
with the runner's stderr included in the rejection reason. Overrides for
tests are read from ``SYMPHONY_PRE_PUSH_GATE_OVERRIDE_<MARKER>`` so unit
tests can drive the runner without invoking the real toolchain.
"""

from __future__ import annotations

import asyncio
import os
import shlex
from pathlib import Path
from typing import Any

_RUNNERS: tuple[tuple[str, str], ...] = (
    ("Makefile", "make test"),
    ("pyproject.toml", "pytest -q"),
    ("package.json", "npm test --silent"),
    ("mix.exs", "mix test"),
    ("Gemfile", "bundle exec rspec"),
    ("go.mod", "go test ./..."),
)


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


def _is_push(command: str) -> bool:
    tokens = shlex.split(command, posix=True) if command else []
    # Accept "git push", "git -C path push", "git push origin main",
    # "git -c x=y push", "GIT_FOO=1 git push" — be lenient about prefix tokens
    # and treat the first "git" + later "push" as the trigger.
    saw_git = False
    for tok in tokens:
        if tok == "git":
            saw_git = True
            continue
        if saw_git and tok == "push":
            return True
    return False


def _override_for(marker: str) -> str | None:
    key = f"SYMPHONY_PRE_PUSH_GATE_OVERRIDE_{marker.replace('.', '_').upper()}"
    return os.environ.get(key)


def _detect_runner(cwd: Path) -> tuple[str, str] | None:
    for marker, default_cmd in _RUNNERS:
        if (cwd / marker).exists():
            return marker, _override_for(marker) or default_cmd
    return None


async def _run(cmd: str, cwd: Path) -> tuple[int, str]:
    proc = await asyncio.create_subprocess_shell(
        cmd,
        cwd=str(cwd),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    stdout, _ = await proc.communicate()
    return proc.returncode or 0, stdout.decode("utf-8", errors="replace")


async def pre_push_gate(
    input_data: dict[str, Any],
    _tool_use_id: str | None,
    _context: dict[str, Any],
) -> dict[str, Any]:
    if input_data.get("tool_name") != "Bash":
        return _allow()

    command = (input_data.get("tool_input", {}) or {}).get("command", "")
    if not _is_push(command):
        return _allow()

    cwd = Path(input_data.get("cwd") or ".")
    runner = _detect_runner(cwd)
    if runner is None:
        return _allow()

    marker, cmd = runner
    code, output = await _run(cmd, cwd)
    if code == 0:
        return _allow()

    tail = "\n".join(output.strip().splitlines()[-15:])
    return _deny(
        f"pre_push_gate: project tests failed ({marker} → `{cmd}`, exit {code}). "
        f"Fix tests before pushing.\n\n--- runner output (tail) ---\n{tail}"
    )
