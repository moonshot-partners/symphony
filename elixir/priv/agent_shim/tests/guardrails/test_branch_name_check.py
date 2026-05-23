"""Tests for the branch_name_check guardrail (SYM-25).

PreToolUse hook fires on ``git push``, reads the current branch name via
``git rev-parse --abbrev-ref HEAD`` in ``cwd``, and denies push when the
branch name does not match the configured regex. Default pattern enforces
``{type}/{TEAM}-{N}[-slug]``; override via ``SYMPHONY_BRANCH_NAMING_PATTERN``.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

from symphony_agent_shim.guardrails.branch_name_check import branch_name_check


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


def _init_repo_on_branch(cwd: Path, branch: str) -> None:
    subprocess.run(["git", "init", "-q", "-b", branch, str(cwd)], check=True)
    # Need user.email/name for any future commit; not required for symbolic-ref but harmless.
    subprocess.run(["git", "-C", str(cwd), "config", "user.email", "t@e.x"], check=True)
    subprocess.run(["git", "-C", str(cwd), "config", "user.name", "t"], check=True)


async def test_non_bash_tool_skips(tmp_path: Path) -> None:
    out = await branch_name_check(
        {"tool_name": "Write", "tool_input": {"file_path": str(tmp_path / "x"), "content": ""}},
        None,
        {"signal": None},
    )
    assert out == {}


async def test_non_push_bash_skips(tmp_path: Path) -> None:
    out = await branch_name_check(
        _hook_input(tmp_path, "git status"),
        None,
        {"signal": None},
    )
    assert out == {}


async def test_matching_branch_allows(tmp_path: Path) -> None:
    _init_repo_on_branch(tmp_path, "agents/sodev-123-fix-it")
    out = await branch_name_check(
        _hook_input(tmp_path, "git push origin agents/sodev-123-fix-it"),
        None,
        {"signal": None},
    )
    assert out == {}


async def test_off_format_branch_denies(tmp_path: Path) -> None:
    _init_repo_on_branch(tmp_path, "random-branch-name")
    out = await branch_name_check(
        _hook_input(tmp_path, "git push origin random-branch-name"),
        None,
        {"signal": None},
    )
    decision = out["hookSpecificOutput"]
    assert decision["permissionDecision"] == "deny"
    reason = decision["permissionDecisionReason"]
    assert "random-branch-name" in reason
    assert "branch_name_check" in reason


async def test_feat_prefix_with_sym_team_allows(tmp_path: Path) -> None:
    _init_repo_on_branch(tmp_path, "feat/sym-25-branch-naming")
    out = await branch_name_check(
        _hook_input(tmp_path, "git push"),
        None,
        {"signal": None},
    )
    assert out == {}


async def test_case_insensitive_team_prefix(tmp_path: Path) -> None:
    _init_repo_on_branch(tmp_path, "feat/SODEV-840-fix")
    out = await branch_name_check(
        _hook_input(tmp_path, "git push"),
        None,
        {"signal": None},
    )
    assert out == {}


async def test_ticket_only_no_slug_allows(tmp_path: Path) -> None:
    _init_repo_on_branch(tmp_path, "fix/sodev-99")
    out = await branch_name_check(
        _hook_input(tmp_path, "git push"),
        None,
        {"signal": None},
    )
    assert out == {}


async def test_unknown_type_prefix_denies(tmp_path: Path) -> None:
    _init_repo_on_branch(tmp_path, "wip/sodev-99-foo")
    out = await branch_name_check(
        _hook_input(tmp_path, "git push"),
        None,
        {"signal": None},
    )
    decision = out["hookSpecificOutput"]
    assert decision["permissionDecision"] == "deny"


async def test_env_override_pattern(tmp_path: Path) -> None:
    _init_repo_on_branch(tmp_path, "bug/PROJ-7")
    os.environ["SYMPHONY_BRANCH_NAMING_PATTERN"] = r"^(bug|feature)/PROJ-[0-9]+$"
    try:
        out = await branch_name_check(
            _hook_input(tmp_path, "git push"),
            None,
            {"signal": None},
        )
        assert out == {}
    finally:
        os.environ.pop("SYMPHONY_BRANCH_NAMING_PATTERN", None)


async def test_env_override_pattern_denies_mismatch(tmp_path: Path) -> None:
    _init_repo_on_branch(tmp_path, "agents/sodev-1-fine-by-default")
    os.environ["SYMPHONY_BRANCH_NAMING_PATTERN"] = r"^(bug|feature)/PROJ-[0-9]+$"
    try:
        out = await branch_name_check(
            _hook_input(tmp_path, "git push"),
            None,
            {"signal": None},
        )
        decision = out["hookSpecificOutput"]
        assert decision["permissionDecision"] == "deny"
        assert "PROJ-" in decision["permissionDecisionReason"]
    finally:
        os.environ.pop("SYMPHONY_BRANCH_NAMING_PATTERN", None)


async def test_non_git_dir_allows(tmp_path: Path) -> None:
    # cwd has no .git — branch lookup fails → fail-open (let git itself
    # produce the user-facing error). This guardrail enforces format,
    # not git-repo presence.
    out = await branch_name_check(
        _hook_input(tmp_path, "git push origin main"),
        None,
        {"signal": None},
    )
    assert out == {}


async def test_detached_head_allows(tmp_path: Path) -> None:
    _init_repo_on_branch(tmp_path, "agents/sodev-1-init")
    # Create one commit so we can check out the SHA in detached state.
    (tmp_path / "f").write_text("x")
    subprocess.run(["git", "-C", str(tmp_path), "add", "f"], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "commit", "-q", "-m", "init"], check=True)
    sha = subprocess.run(
        ["git", "-C", str(tmp_path), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    subprocess.run(["git", "-C", str(tmp_path), "checkout", "-q", "--detach", sha], check=True)

    out = await branch_name_check(
        _hook_input(tmp_path, "git push origin HEAD:refs/heads/foo"),
        None,
        {"signal": None},
    )
    # Detached HEAD → no branch name to evaluate → allow.
    assert out == {}


async def test_malformed_override_pattern_allows(tmp_path: Path) -> None:
    _init_repo_on_branch(tmp_path, "random")
    os.environ["SYMPHONY_BRANCH_NAMING_PATTERN"] = "[unclosed"
    try:
        out = await branch_name_check(
            _hook_input(tmp_path, "git push"),
            None,
            {"signal": None},
        )
        # Malformed regex → fail open (don't block on operator misconfig).
        assert out == {}
    finally:
        os.environ.pop("SYMPHONY_BRANCH_NAMING_PATTERN", None)


async def test_empty_command_allows(tmp_path: Path) -> None:
    out = await branch_name_check(_hook_input(tmp_path, ""), None, {"signal": None})
    assert out == {}


async def test_git_dash_c_push_still_checked(tmp_path: Path) -> None:
    _init_repo_on_branch(tmp_path, "random-bad")
    out = await branch_name_check(
        _hook_input(tmp_path, "git -c user.email=x push"),
        None,
        {"signal": None},
    )
    decision = out["hookSpecificOutput"]
    assert decision["permissionDecision"] == "deny"
