"""Tests for tdd_enforcer guardrail hook (warn-only)."""

from __future__ import annotations

from pathlib import Path

from symphony_agent_shim.guardrails.tdd_enforcer import tdd_enforcer


def _hook_input(file_path: Path, tool_name: str = "Write") -> dict:
    cwd = file_path.parent.parent.parent if len(file_path.parents) > 2 else file_path.parent
    return {
        "hook_event_name": "PreToolUse",
        "session_id": "s",
        "transcript_path": "/tmp/t",
        "cwd": str(cwd),
        "tool_name": tool_name,
        "tool_input": {"file_path": str(file_path), "content": "x"},
        "tool_use_id": "u1",
    }


async def test_python_impl_without_test_warns(tmp_path: Path) -> None:
    (tmp_path / "src" / "myapp").mkdir(parents=True)
    impl = tmp_path / "src" / "myapp" / "module.py"
    out = await tdd_enforcer(
        {
            "hook_event_name": "PreToolUse",
            "session_id": "s",
            "transcript_path": "/tmp/t",
            "cwd": str(tmp_path),
            "tool_name": "Write",
            "tool_input": {"file_path": str(impl), "content": "def f(): pass"},
            "tool_use_id": "u1",
        },
        None,
        {"signal": None},
    )
    # Always allow — tdd_enforcer never blocks.
    assert out["hookSpecificOutput"]["permissionDecision"] == "allow"
    assert "test" in out["hookSpecificOutput"]["permissionDecisionReason"].lower()


async def test_python_impl_with_sibling_test_no_warning(tmp_path: Path) -> None:
    (tmp_path / "src" / "myapp").mkdir(parents=True)
    (tmp_path / "tests").mkdir()
    (tmp_path / "tests" / "test_module.py").write_text("def test_x(): ...")
    impl = tmp_path / "src" / "myapp" / "module.py"

    out = await tdd_enforcer(
        {
            "hook_event_name": "PreToolUse",
            "session_id": "s",
            "transcript_path": "/tmp/t",
            "cwd": str(tmp_path),
            "tool_name": "Write",
            "tool_input": {"file_path": str(impl), "content": "x"},
            "tool_use_id": "u1",
        },
        None,
        {"signal": None},
    )
    decision = out["hookSpecificOutput"]
    assert decision["permissionDecision"] == "allow"
    reason = decision.get("permissionDecisionReason", "").lower()
    assert "no test" not in reason


async def test_writing_test_file_never_warns(tmp_path: Path) -> None:
    (tmp_path / "tests").mkdir()
    test_file = tmp_path / "tests" / "test_module.py"
    out = await tdd_enforcer(
        {
            "hook_event_name": "PreToolUse",
            "session_id": "s",
            "transcript_path": "/tmp/t",
            "cwd": str(tmp_path),
            "tool_name": "Write",
            "tool_input": {"file_path": str(test_file), "content": "def test_x(): ..."},
            "tool_use_id": "u1",
        },
        None,
        {"signal": None},
    )
    decision = out["hookSpecificOutput"]
    assert decision["permissionDecision"] == "allow"
    assert "no test" not in decision.get("permissionDecisionReason", "").lower()


async def test_elixir_impl_without_test_warns(tmp_path: Path) -> None:
    (tmp_path / "lib").mkdir()
    impl = tmp_path / "lib" / "thing.ex"
    out = await tdd_enforcer(
        {
            "hook_event_name": "PreToolUse",
            "session_id": "s",
            "transcript_path": "/tmp/t",
            "cwd": str(tmp_path),
            "tool_name": "Write",
            "tool_input": {"file_path": str(impl), "content": "defmodule X do end"},
            "tool_use_id": "u1",
        },
        None,
        {"signal": None},
    )
    decision = out["hookSpecificOutput"]
    assert decision["permissionDecision"] == "allow"
    assert "test" in decision["permissionDecisionReason"].lower()


async def test_config_or_doc_files_ignored(tmp_path: Path) -> None:
    f = tmp_path / "README.md"
    out = await tdd_enforcer(
        {
            "hook_event_name": "PreToolUse",
            "session_id": "s",
            "transcript_path": "/tmp/t",
            "cwd": str(tmp_path),
            "tool_name": "Write",
            "tool_input": {"file_path": str(f), "content": "# hi"},
            "tool_use_id": "u1",
        },
        None,
        {"signal": None},
    )
    decision = out["hookSpecificOutput"]
    assert decision["permissionDecision"] == "allow"
    assert "no test" not in decision.get("permissionDecisionReason", "").lower()
