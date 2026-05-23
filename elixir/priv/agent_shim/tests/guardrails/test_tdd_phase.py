"""Tests for the tdd_phase guardrail.

The hook is opt-in: enabling lives behind ``SYMPHONY_TDD_PHASE_ENFORCEMENT``
so existing projects keep their current behavior. Tests prove RED→GREEN→
REFACTOR transitions, ACs 1-6 from SYM-21, and graceful behavior on missing
or corrupt state.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from symphony_agent_shim.guardrails.tdd_phase import (
    tdd_phase_post_bash,
    tdd_phase_pre_edit,
)


def _pre_input(
    cwd: Path,
    tool_name: str,
    file_path: str,
    session_id: str = "sess123",
) -> dict:
    return {
        "hook_event_name": "PreToolUse",
        "session_id": session_id,
        "transcript_path": "/tmp/t",
        "cwd": str(cwd),
        "tool_name": tool_name,
        "tool_input": {"file_path": file_path, "content": "x"},
        "tool_use_id": "u1",
    }


def _post_bash_input(
    cwd: Path,
    cmd: str,
    response,
    session_id: str = "sess123",
) -> dict:
    return {
        "hook_event_name": "PostToolUse",
        "session_id": session_id,
        "transcript_path": "/tmp/t",
        "cwd": str(cwd),
        "tool_name": "Bash",
        "tool_input": {"command": cmd},
        "tool_response": response,
        "tool_use_id": "u1",
    }


# ---- opt-in / default OFF (AC4) ----------------------------------------------


async def test_disabled_by_default_allows_impl_edit(tmp_path: Path) -> None:
    out = await tdd_phase_pre_edit(
        _pre_input(tmp_path, "Edit", str(tmp_path / "lib" / "foo.py")),
        None,
        {"signal": None},
    )
    assert out["hookSpecificOutput"]["permissionDecision"] == "allow"


async def test_disabled_by_default_skips_post_bash(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_STATE_DIR", str(tmp_path / "state"))
    await tdd_phase_post_bash(
        _post_bash_input(tmp_path, "pytest -q", {"is_error": True}),
        None,
        {"signal": None},
    )
    assert not (tmp_path / "state" / "sess123" / "tdd_phase.json").exists()


# ---- RED phase: only test files allowed (AC1) --------------------------------


async def test_red_phase_denies_impl_edit(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_ENFORCEMENT", "enabled")
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_STATE_DIR", str(tmp_path / "state"))
    out = await tdd_phase_pre_edit(
        _pre_input(tmp_path, "Edit", str(tmp_path / "lib" / "foo.py")),
        None,
        {"signal": None},
    )
    decision = out["hookSpecificOutput"]
    assert decision["permissionDecision"] == "deny"
    assert "RED" in decision["permissionDecisionReason"]


async def test_red_phase_allows_test_edit(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_ENFORCEMENT", "enabled")
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_STATE_DIR", str(tmp_path / "state"))
    out = await tdd_phase_pre_edit(
        _pre_input(tmp_path, "Write", str(tmp_path / "test" / "foo_test.py")),
        None,
        {"signal": None},
    )
    assert out["hookSpecificOutput"]["permissionDecision"] == "allow"


async def test_red_phase_allows_docs_edit(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Non-impl, non-test paths (docs/configs) are always allowed."""
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_ENFORCEMENT", "enabled")
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_STATE_DIR", str(tmp_path / "state"))
    out = await tdd_phase_pre_edit(
        _pre_input(tmp_path, "Edit", str(tmp_path / "AGENTS.md")),
        None,
        {"signal": None},
    )
    assert out["hookSpecificOutput"]["permissionDecision"] == "allow"


# ---- PostToolUse records test exit codes (AC1, AC3) --------------------------


async def test_failing_test_records_nonzero_exit(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_ENFORCEMENT", "enabled")
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_STATE_DIR", str(tmp_path / "state"))
    await tdd_phase_post_bash(
        _post_bash_input(tmp_path, "pytest -q", {"is_error": True}),
        None,
        {"signal": None},
    )
    state = json.loads(
        (tmp_path / "state" / "sess123" / "tdd_phase.json").read_text()
    )
    assert state["last_test_exit_code"] != 0


async def test_passing_test_records_zero_exit(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_ENFORCEMENT", "enabled")
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_STATE_DIR", str(tmp_path / "state"))
    await tdd_phase_post_bash(
        _post_bash_input(tmp_path, "mix test", {"is_error": False}),
        None,
        {"signal": None},
    )
    state = json.loads(
        (tmp_path / "state" / "sess123" / "tdd_phase.json").read_text()
    )
    assert state["last_test_exit_code"] == 0


async def test_non_test_bash_does_not_touch_state(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_ENFORCEMENT", "enabled")
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_STATE_DIR", str(tmp_path / "state"))
    await tdd_phase_post_bash(
        _post_bash_input(tmp_path, "ls -la", {"is_error": False}),
        None,
        {"signal": None},
    )
    assert not (tmp_path / "state" / "sess123" / "tdd_phase.json").exists()


async def test_post_bash_handles_exit_code_field(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_ENFORCEMENT", "enabled")
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_STATE_DIR", str(tmp_path / "state"))
    await tdd_phase_post_bash(
        _post_bash_input(tmp_path, "pytest", {"exit_code": 2}),
        None,
        {"signal": None},
    )
    state = json.loads(
        (tmp_path / "state" / "sess123" / "tdd_phase.json").read_text()
    )
    assert state["last_test_exit_code"] == 2


# ---- GREEN phase: impl allowed, tests denied (AC2) ---------------------------


async def test_green_phase_allows_impl_edit(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_ENFORCEMENT", "enabled")
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_STATE_DIR", str(tmp_path / "state"))
    state_dir = tmp_path / "state" / "sess123"
    state_dir.mkdir(parents=True)
    (state_dir / "tdd_phase.json").write_text(
        json.dumps({"last_test_exit_code": 1})
    )
    out = await tdd_phase_pre_edit(
        _pre_input(tmp_path, "Edit", str(tmp_path / "lib" / "foo.py")),
        None,
        {"signal": None},
    )
    assert out["hookSpecificOutput"]["permissionDecision"] == "allow"


async def test_green_phase_denies_test_edit(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_ENFORCEMENT", "enabled")
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_STATE_DIR", str(tmp_path / "state"))
    state_dir = tmp_path / "state" / "sess123"
    state_dir.mkdir(parents=True)
    (state_dir / "tdd_phase.json").write_text(
        json.dumps({"last_test_exit_code": 1})
    )
    out = await tdd_phase_pre_edit(
        _pre_input(tmp_path, "Edit", str(tmp_path / "test" / "foo_test.py")),
        None,
        {"signal": None},
    )
    decision = out["hookSpecificOutput"]
    assert decision["permissionDecision"] == "deny"
    assert "GREEN" in decision["permissionDecisionReason"]


# ---- REFACTOR phase: anything allowed once test passed -----------------------


async def test_refactor_phase_allows_both(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_ENFORCEMENT", "enabled")
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_STATE_DIR", str(tmp_path / "state"))
    state_dir = tmp_path / "state" / "sess123"
    state_dir.mkdir(parents=True)
    (state_dir / "tdd_phase.json").write_text(
        json.dumps({"last_test_exit_code": 0})
    )
    for path in (
        str(tmp_path / "lib" / "foo.py"),
        str(tmp_path / "test" / "foo_test.py"),
    ):
        out = await tdd_phase_pre_edit(
            _pre_input(tmp_path, "Edit", path),
            None,
            {"signal": None},
        )
        assert out["hookSpecificOutput"]["permissionDecision"] == "allow"


# ---- Resilience: corrupt/missing state defaults to RED -----------------------


async def test_corrupt_state_file_defaults_to_red(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_ENFORCEMENT", "enabled")
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_STATE_DIR", str(tmp_path / "state"))
    state_dir = tmp_path / "state" / "sess123"
    state_dir.mkdir(parents=True)
    (state_dir / "tdd_phase.json").write_text("not valid json {")
    out = await tdd_phase_pre_edit(
        _pre_input(tmp_path, "Edit", str(tmp_path / "lib" / "foo.py")),
        None,
        {"signal": None},
    )
    assert out["hookSpecificOutput"]["permissionDecision"] == "deny"


async def test_missing_state_dir_defaults_to_red(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_ENFORCEMENT", "enabled")
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_STATE_DIR", str(tmp_path / "state"))
    out = await tdd_phase_pre_edit(
        _pre_input(tmp_path, "Edit", str(tmp_path / "src" / "foo.ts")),
        None,
        {"signal": None},
    )
    assert out["hookSpecificOutput"]["permissionDecision"] == "deny"


# ---- Path classification edge cases ------------------------------------------


async def test_non_watched_tool_passes_through(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_ENFORCEMENT", "enabled")
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_STATE_DIR", str(tmp_path / "state"))
    out = await tdd_phase_pre_edit(
        {
            "hook_event_name": "PreToolUse",
            "session_id": "sess123",
            "transcript_path": "/tmp/t",
            "cwd": str(tmp_path),
            "tool_name": "Read",
            "tool_input": {"file_path": str(tmp_path / "lib" / "foo.py")},
            "tool_use_id": "u",
        },
        None,
        {"signal": None},
    )
    assert out["hookSpecificOutput"]["permissionDecision"] == "allow"


async def test_session_id_isolation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Phase state must not leak across sessions."""
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_ENFORCEMENT", "enabled")
    monkeypatch.setenv("SYMPHONY_TDD_PHASE_STATE_DIR", str(tmp_path / "state"))
    state_dir = tmp_path / "state" / "sess_a"
    state_dir.mkdir(parents=True)
    (state_dir / "tdd_phase.json").write_text(
        json.dumps({"last_test_exit_code": 1})
    )
    # sess_b has no state → RED
    out = await tdd_phase_pre_edit(
        _pre_input(
            tmp_path,
            "Edit",
            str(tmp_path / "lib" / "foo.py"),
            session_id="sess_b",
        ),
        None,
        {"signal": None},
    )
    assert out["hookSpecificOutput"]["permissionDecision"] == "deny"
