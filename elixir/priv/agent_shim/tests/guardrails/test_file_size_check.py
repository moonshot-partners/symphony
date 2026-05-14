"""Tests for file_size_check guardrail hook (PostToolUse)."""

from __future__ import annotations

from pathlib import Path

from symphony_agent_shim.guardrails.file_size_check import file_size_check


def _hook_input(file_path: Path, tool_name: str = "Write") -> dict:
    return {
        "hook_event_name": "PostToolUse",
        "session_id": "s",
        "transcript_path": "/tmp/t",
        "cwd": str(file_path.parent),
        "tool_name": tool_name,
        "tool_input": {"file_path": str(file_path)},
        "tool_response": {},
        "tool_use_id": "u1",
    }


async def test_small_file_no_warning(tmp_path: Path) -> None:
    f = tmp_path / "small.py"
    f.write_text("\n".join(f"# line {i}" for i in range(100)))
    out = await file_size_check(_hook_input(f), None, {"signal": None})
    assert "hookSpecificOutput" not in out or not out["hookSpecificOutput"].get("additionalContext")
    assert out.get("decision") != "block"


async def test_warn_between_400_and_600(tmp_path: Path) -> None:
    f = tmp_path / "medium.py"
    f.write_text("\n".join(f"# line {i}" for i in range(450)))
    out = await file_size_check(_hook_input(f), None, {"signal": None})
    ctx = out["hookSpecificOutput"]["additionalContext"]
    assert "450" in ctx
    assert "warning" in ctx.lower()
    assert out.get("decision") != "block"


async def test_block_over_600(tmp_path: Path) -> None:
    f = tmp_path / "huge.py"
    f.write_text("\n".join(f"# line {i}" for i in range(700)))
    out = await file_size_check(_hook_input(f), None, {"signal": None})
    assert out["decision"] == "block"
    assert "700" in out["reason"]


async def test_ignores_non_write_tools(tmp_path: Path) -> None:
    f = tmp_path / "huge.py"
    f.write_text("\n".join(f"# line {i}" for i in range(700)))
    out = await file_size_check(_hook_input(f, tool_name="Bash"), None, {"signal": None})
    assert out.get("decision") != "block"


async def test_missing_file_is_noop(tmp_path: Path) -> None:
    out = await file_size_check(_hook_input(tmp_path / "gone.py"), None, {"signal": None})
    assert out.get("decision") != "block"
