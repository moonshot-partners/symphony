"""Tests for the bash_policy guardrail (SYM-23).

Default AUTO_DENY for destructive Bash commands. ALLOW list bypass via the
``SYMPHONY_BASH_POLICY_ALLOW`` env var (newline-separated regex patterns).
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from symphony_agent_shim.guardrails.bash_policy import bash_policy_pre


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


async def test_non_bash_tool_skips(tmp_path: Path) -> None:
    out = await bash_policy_pre(
        {
            "hook_event_name": "PreToolUse",
            "tool_name": "Write",
            "tool_input": {"file_path": str(tmp_path / "x"), "content": "rm -rf /"},
        },
        None,
        {"signal": None},
    )
    assert out == {}


async def test_benign_command_allows(tmp_path: Path) -> None:
    out = await bash_policy_pre(_hook_input(tmp_path, "ls -la"), None, {"signal": None})
    assert out == {}


async def test_empty_command_allows(tmp_path: Path) -> None:
    out = await bash_policy_pre(_hook_input(tmp_path, ""), None, {"signal": None})
    assert out == {}


async def test_tool_input_missing_command_key_allows(tmp_path: Path) -> None:
    out = await bash_policy_pre(
        {"tool_name": "Bash", "tool_input": {}},
        None,
        {"signal": None},
    )
    assert out == {}


async def test_tool_input_none_allows(tmp_path: Path) -> None:
    out = await bash_policy_pre(
        {"tool_name": "Bash", "tool_input": None},
        None,
        {"signal": None},
    )
    assert out == {}


@pytest.mark.parametrize(
    "command,label",
    [
        ("rm -rf /", "rm -rf"),
        ("rm -fr ./build", "rm -rf"),
        ("rm -Rf node_modules", "rm -rf"),
        ("git reset --hard HEAD~10", "git reset --hard"),
        ("git push --force origin main", "git push --force"),
        ("git push -f origin feature", "git push --force"),
        ("git clean -fd", "git clean -fd"),
        ("git clean -fdx", "git clean -fd"),
        ("git branch -D feature/old", "git branch -D"),
        ("psql -c 'DROP TABLE users'", "DROP TABLE"),
        ("psql -c 'DROP DATABASE prod'", "DROP DATABASE"),
        ("psql -c 'TRUNCATE TABLE sessions'", "TRUNCATE"),
        ("psql -c 'TRUNCATE sessions'", "TRUNCATE"),
        ("dd if=/dev/zero of=/dev/sda bs=1M", "dd to device"),
        ("mkfs.ext4 /dev/sdb1", "mkfs"),
        ("chmod 777 /etc/passwd", "chmod 777"),
        ("chown -R root /home", "chown -R root"),
    ],
)
async def test_destructive_patterns_deny(tmp_path: Path, command: str, label: str) -> None:
    out = await bash_policy_pre(_hook_input(tmp_path, command), None, {"signal": None})
    decision = out["hookSpecificOutput"]
    assert decision["hookEventName"] == "PreToolUse"
    assert decision["permissionDecision"] == "deny"
    reason = decision["permissionDecisionReason"]
    assert label in reason
    assert "bash_policy" in reason


async def test_case_insensitive_match(tmp_path: Path) -> None:
    out = await bash_policy_pre(
        _hook_input(tmp_path, "psql -c 'drop table users'"),
        None,
        {"signal": None},
    )
    assert out["hookSpecificOutput"]["permissionDecision"] == "deny"


async def test_allow_list_bypass(tmp_path: Path) -> None:
    os.environ["SYMPHONY_BASH_POLICY_ALLOW"] = r"git reset --hard origin/dev"
    try:
        out = await bash_policy_pre(
            _hook_input(tmp_path, "git reset --hard origin/dev"),
            None,
            {"signal": None},
        )
        assert out == {}
    finally:
        os.environ.pop("SYMPHONY_BASH_POLICY_ALLOW", None)


async def test_allow_list_multiline(tmp_path: Path) -> None:
    os.environ["SYMPHONY_BASH_POLICY_ALLOW"] = "rm -rf node_modules\nrm -rf \\.next"
    try:
        # First allowed pattern bypasses.
        out = await bash_policy_pre(
            _hook_input(tmp_path, "rm -rf node_modules"),
            None,
            {"signal": None},
        )
        assert out == {}

        # Second allowed pattern bypasses.
        out = await bash_policy_pre(
            _hook_input(tmp_path, "rm -rf .next"),
            None,
            {"signal": None},
        )
        assert out == {}

        # Non-matching destructive still denied.
        out = await bash_policy_pre(
            _hook_input(tmp_path, "rm -rf /etc"),
            None,
            {"signal": None},
        )
        assert out["hookSpecificOutput"]["permissionDecision"] == "deny"
    finally:
        os.environ.pop("SYMPHONY_BASH_POLICY_ALLOW", None)


async def test_allow_list_empty_lines_ignored(tmp_path: Path) -> None:
    os.environ["SYMPHONY_BASH_POLICY_ALLOW"] = "\n\nrm -rf node_modules\n\n"
    try:
        out = await bash_policy_pre(
            _hook_input(tmp_path, "rm -rf node_modules"),
            None,
            {"signal": None},
        )
        assert out == {}
    finally:
        os.environ.pop("SYMPHONY_BASH_POLICY_ALLOW", None)


async def test_allow_list_invalid_regex_falls_back_to_deny(tmp_path: Path) -> None:
    # An unparseable regex must not crash the hook — the destructive command
    # should still be denied because the malformed allow entry is ignored.
    os.environ["SYMPHONY_BASH_POLICY_ALLOW"] = "[unclosed"
    try:
        out = await bash_policy_pre(
            _hook_input(tmp_path, "rm -rf /"),
            None,
            {"signal": None},
        )
        assert out["hookSpecificOutput"]["permissionDecision"] == "deny"
    finally:
        os.environ.pop("SYMPHONY_BASH_POLICY_ALLOW", None)


async def test_deny_reason_truncates_long_command(tmp_path: Path) -> None:
    long_tail = "x" * 5000
    cmd = f"rm -rf /var/log; echo {long_tail}"
    out = await bash_policy_pre(_hook_input(tmp_path, cmd), None, {"signal": None})
    reason = out["hookSpecificOutput"]["permissionDecisionReason"]
    # Reason is bounded — must not include the full 5KB tail verbatim.
    assert len(reason) < 1024
