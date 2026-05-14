"""Tests for pre_push_gate guardrail hook.

Uses real subprocess execution against synthetic project layouts (Makefile,
pyproject, package.json, mix.exs). No mocks — the hook's value is its real
ability to detect a stack and run its tests, so faking the detection would
not exercise the code that matters.
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from symphony_agent_shim.guardrails.pre_push_gate import pre_push_gate


def _hook_input(cwd: Path, command: str) -> dict:
    return {
        "hook_event_name": "PreToolUse",
        "session_id": "s",
        "transcript_path": "/tmp/t",
        "cwd": str(cwd),
        "tool_name": "Bash",
        "tool_input": {"command": command},
        "tool_use_id": "u1",
    }


async def test_non_push_bash_passes_through(tmp_path: Path) -> None:
    out = await pre_push_gate(
        _hook_input(tmp_path, "ls -la"),
        None,
        {"signal": None},
    )
    assert out["hookSpecificOutput"]["permissionDecision"] == "allow"


async def test_ignores_non_bash_tools(tmp_path: Path) -> None:
    out = await pre_push_gate(
        {
            "hook_event_name": "PreToolUse",
            "session_id": "s",
            "transcript_path": "/tmp/t",
            "cwd": str(tmp_path),
            "tool_name": "Write",
            "tool_input": {"file_path": str(tmp_path / "x"), "content": "git push"},
            "tool_use_id": "u",
        },
        None,
        {"signal": None},
    )
    assert out["hookSpecificOutput"]["permissionDecision"] == "allow"


async def test_no_recognized_stack_passes(tmp_path: Path) -> None:
    out = await pre_push_gate(
        _hook_input(tmp_path, "git push origin main"),
        None,
        {"signal": None},
    )
    # Nothing to run = pass-through allow.
    assert out["hookSpecificOutput"]["permissionDecision"] == "allow"


@pytest.mark.parametrize(
    "marker,content",
    [
        ("Makefile", "test:\n\ttrue\n"),
        ("pyproject.toml", "[project]\nname='x'\n"),
        ("package.json", '{"name":"x","scripts":{"test":"true"}}'),
        ("mix.exs", "defmodule X.MixProject do; end\n"),
        ("Gemfile", "source 'https://rubygems.org'\n"),
        ("go.mod", "module x\ngo 1.22\n"),
    ],
)
async def test_passing_stack_tests_allow(tmp_path: Path, marker: str, content: str) -> None:
    (tmp_path / marker).write_text(content)
    # Override the runner via env so we don't actually call make/pytest/etc.
    env_key = f"SYMPHONY_PRE_PUSH_GATE_OVERRIDE_{marker.replace('.', '_').upper()}"
    os.environ[env_key] = "true"
    try:
        out = await pre_push_gate(
            _hook_input(tmp_path, "git push origin main"),
            None,
            {"signal": None},
        )
        assert out["hookSpecificOutput"]["permissionDecision"] == "allow"
    finally:
        os.environ.pop(env_key, None)


async def test_failing_tests_deny(tmp_path: Path) -> None:
    (tmp_path / "Makefile").write_text("test:\n\tfalse\n")
    os.environ["SYMPHONY_PRE_PUSH_GATE_OVERRIDE_MAKEFILE"] = "false"
    try:
        out = await pre_push_gate(
            _hook_input(tmp_path, "git push origin main"),
            None,
            {"signal": None},
        )
        decision = out["hookSpecificOutput"]
        assert decision["permissionDecision"] == "deny"
        assert "test" in decision["permissionDecisionReason"].lower()
    finally:
        os.environ.pop("SYMPHONY_PRE_PUSH_GATE_OVERRIDE_MAKEFILE", None)


async def test_real_makefile_target_runs(tmp_path: Path) -> None:
    """Smoke: no override, hook actually shells out to `make test`."""
    (tmp_path / "Makefile").write_text("test:\n\t@true\n")
    out = await pre_push_gate(
        _hook_input(tmp_path, "git push"),
        None,
        {"signal": None},
    )
    # `make test` against a Makefile whose `test:` recipe is `true` must allow.
    assert out["hookSpecificOutput"]["permissionDecision"] == "allow"
