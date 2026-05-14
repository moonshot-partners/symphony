"""Tests for pre_edit_overwrite_guard hook.

Uses real git repos in ``tmp_path`` (no mocks) — the hook's whole point is to
talk to a real working tree, so faking git would prove nothing.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from symphony_agent_shim.guardrails.pre_edit_overwrite_guard import (
    pre_edit_overwrite_guard,
)


def _run(cwd: Path, *args: str) -> None:
    subprocess.run(
        ["git", *args],
        cwd=cwd,
        check=True,
        env={
            "GIT_AUTHOR_NAME": "t",
            "GIT_AUTHOR_EMAIL": "t@t",
            "GIT_COMMITTER_NAME": "t",
            "GIT_COMMITTER_EMAIL": "t@t",
            "PATH": "/usr/bin:/bin",
        },
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


@pytest.fixture
def diverged_repo(tmp_path: Path) -> Path:
    """Local branch is one commit behind a fake upstream that modified file.txt."""
    upstream = tmp_path / "upstream"
    upstream.mkdir()
    _run(upstream, "init", "-q", "-b", "main")
    (upstream / "file.txt").write_text("v1\n")
    _run(upstream, "add", "file.txt")
    _run(upstream, "commit", "-qm", "v1")

    local = tmp_path / "local"
    _run(tmp_path, "clone", "-q", str(upstream), str(local))

    # Upstream gets v2 while local sits at v1
    (upstream / "file.txt").write_text("v2\n")
    _run(upstream, "add", "file.txt")
    _run(upstream, "commit", "-qm", "v2")
    _run(local, "fetch", "-q")
    return local


@pytest.fixture
def synced_repo(tmp_path: Path) -> Path:
    """Local branch is even with its upstream."""
    upstream = tmp_path / "upstream"
    upstream.mkdir()
    _run(upstream, "init", "-q", "-b", "main")
    (upstream / "file.txt").write_text("v1\n")
    _run(upstream, "add", "file.txt")
    _run(upstream, "commit", "-qm", "v1")

    local = tmp_path / "local"
    _run(tmp_path, "clone", "-q", str(upstream), str(local))
    return local


def _hook_input(cwd: Path, tool_name: str, tool_input: dict) -> dict:
    return {
        "hook_event_name": "PreToolUse",
        "session_id": "s",
        "transcript_path": "/tmp/t",
        "cwd": str(cwd),
        "tool_name": tool_name,
        "tool_input": tool_input,
        "tool_use_id": "u1",
    }


async def test_denies_edit_of_upstream_modified_file(diverged_repo: Path) -> None:
    out = await pre_edit_overwrite_guard(
        _hook_input(diverged_repo, "Edit", {"file_path": str(diverged_repo / "file.txt")}),
        None,
        {"signal": None},
    )
    deny = out["hookSpecificOutput"]
    assert deny["permissionDecision"] == "deny"
    assert "upstream" in deny["permissionDecisionReason"].lower()


async def test_allows_edit_when_synced(synced_repo: Path) -> None:
    out = await pre_edit_overwrite_guard(
        _hook_input(synced_repo, "Edit", {"file_path": str(synced_repo / "file.txt")}),
        None,
        {"signal": None},
    )
    assert out["hookSpecificOutput"]["permissionDecision"] == "allow"


async def test_allows_new_file_creation(synced_repo: Path) -> None:
    new_path = str(synced_repo / "brand_new.txt")
    out = await pre_edit_overwrite_guard(
        _hook_input(synced_repo, "Write", {"file_path": new_path, "content": "hi"}),
        None,
        {"signal": None},
    )
    assert out["hookSpecificOutput"]["permissionDecision"] == "allow"


async def test_allows_outside_git_repo(tmp_path: Path) -> None:
    plain = tmp_path / "plain"
    plain.mkdir()
    (plain / "x.txt").write_text("hi")
    out = await pre_edit_overwrite_guard(
        _hook_input(plain, "Edit", {"file_path": str(plain / "x.txt")}),
        None,
        {"signal": None},
    )
    assert out["hookSpecificOutput"]["permissionDecision"] == "allow"


async def test_ignores_non_write_tools(diverged_repo: Path) -> None:
    out = await pre_edit_overwrite_guard(
        _hook_input(diverged_repo, "Bash", {"command": "ls"}),
        None,
        {"signal": None},
    )
    assert out["hookSpecificOutput"]["permissionDecision"] == "allow"
