"""Tests for the pre_pr_gate guardrail hook (SYM-1a / SYM-27).

Blocks ``gh pr create`` at PreToolUse when the staged diff touches the
rendering layer and the PR body is missing the ``## QA self-review`` +
``- Result: PASS|FAIL|BLOCKED`` line. Mirrors the body that the
``qa-evidence`` GitHub Action checks post-merge, but fires during the
agent's run so failures don't reach the open PR.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

from symphony_agent_shim.guardrails.pre_pr_gate import pre_pr_gate


def _hook(cwd: Path, command: str) -> dict:
    return {
        "hook_event_name": "PreToolUse",
        "session_id": "s",
        "transcript_path": "/tmp/t",
        "cwd": str(cwd),
        "tool_name": "Bash",
        "tool_input": {"command": command},
        "tool_use_id": "u1",
    }


def _init_git(repo: Path) -> None:
    subprocess.run(
        ["git", "init", "-q", "-b", "main", str(repo)],
        check=True,
    )
    subprocess.run(["git", "-C", str(repo), "config", "user.email", "t@t"], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.name", "t"], check=True)
    (repo / "README.md").write_text("# repo\n")
    subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
    subprocess.run(
        ["git", "-C", str(repo), "commit", "-q", "-m", "init"],
        check=True,
    )


def _stage(repo: Path, rel: str, content: str = "x\n") -> None:
    path = repo / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    subprocess.run(["git", "-C", str(repo), "add", rel], check=True)


_QA_GOOD = """## QA self-review

Steps tested.

- Result: PASS
"""

_QA_FAIL_OK = """## QA self-review

- Result: FAIL
"""


async def test_non_bash_tool_skips(tmp_path: Path) -> None:
    out = await pre_pr_gate(
        {
            "tool_name": "Write",
            "tool_input": {"file_path": str(tmp_path / "x"), "content": "gh pr create"},
        },
        None,
        {"signal": None},
    )
    assert out == {}


async def test_non_pr_create_command_skips(tmp_path: Path) -> None:
    out = await pre_pr_gate(_hook(tmp_path, "gh pr view 123"), None, {"signal": None})
    assert out == {}
    out = await pre_pr_gate(_hook(tmp_path, "echo hello"), None, {"signal": None})
    assert out == {}


async def test_empty_command_skips(tmp_path: Path) -> None:
    out = await pre_pr_gate(_hook(tmp_path, ""), None, {"signal": None})
    assert out == {}


async def test_no_view_layer_diff_bypasses(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _init_git(repo)
    _stage(repo, "lib/foo.ex", "defmodule X do end\n")
    body_file = repo / "body.md"
    body_file.write_text("nothing here")
    out = await pre_pr_gate(
        _hook(repo, f"gh pr create --body-file {body_file}"),
        None,
        {"signal": None},
    )
    assert out == {}


async def test_view_layer_diff_with_good_body_allows(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _init_git(repo)
    _stage(repo, "src/Button.tsx", "export const Button = () => null;\n")
    body_file = repo / "body.md"
    body_file.write_text(_QA_GOOD)
    out = await pre_pr_gate(
        _hook(repo, f"gh pr create --body-file {body_file} --title T"),
        None,
        {"signal": None},
    )
    assert out == {}


async def test_view_layer_diff_with_fail_result_still_allows(tmp_path: Path) -> None:
    # The gate enforces *presence* of the section + Result line, not the
    # verdict itself (SYM-1b owns substance verification).
    repo = tmp_path / "repo"
    _init_git(repo)
    _stage(repo, "src/Card.jsx", "export const Card = () => null;\n")
    body_file = repo / "body.md"
    body_file.write_text(_QA_FAIL_OK)
    out = await pre_pr_gate(
        _hook(repo, f"gh pr create --body-file {body_file}"),
        None,
        {"signal": None},
    )
    assert out == {}


async def test_view_layer_diff_missing_section_denies(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _init_git(repo)
    _stage(repo, "src/Foo.tsx", "export const Foo = () => null;\n")
    body_file = repo / "body.md"
    body_file.write_text("Some PR body without the QA section.\n")
    out = await pre_pr_gate(
        _hook(repo, f"gh pr create --body-file {body_file}"),
        None,
        {"signal": None},
    )
    decision = out["hookSpecificOutput"]
    assert decision["permissionDecision"] == "deny"
    reason = decision["permissionDecisionReason"]
    assert "## QA self-review" in reason
    assert "pre_pr_gate" in reason


async def test_view_layer_diff_missing_result_line_denies(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _init_git(repo)
    _stage(repo, "src/Foo.vue", "<template></template>\n")
    body_file = repo / "body.md"
    body_file.write_text("## QA self-review\n\nSome notes without a result.\n")
    out = await pre_pr_gate(
        _hook(repo, f"gh pr create --body-file {body_file}"),
        None,
        {"signal": None},
    )
    decision = out["hookSpecificOutput"]
    assert decision["permissionDecision"] == "deny"
    assert "Result:" in decision["permissionDecisionReason"]


async def test_inline_body_works(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _init_git(repo)
    _stage(repo, "src/Btn.tsx", "x\n")
    out = await pre_pr_gate(
        _hook(repo, f'gh pr create --body "{_QA_GOOD}"'),
        None,
        {"signal": None},
    )
    assert out == {}


async def test_missing_body_denies(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _init_git(repo)
    _stage(repo, "src/Btn.tsx", "x\n")
    out = await pre_pr_gate(_hook(repo, "gh pr create --title T"), None, {"signal": None})
    assert out["hookSpecificOutput"]["permissionDecision"] == "deny"


async def test_body_file_pointing_to_missing_path_denies(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _init_git(repo)
    _stage(repo, "src/Btn.tsx", "x\n")
    out = await pre_pr_gate(
        _hook(repo, f"gh pr create --body-file {repo}/nope.md"),
        None,
        {"signal": None},
    )
    decision = out["hookSpecificOutput"]
    assert decision["permissionDecision"] == "deny"
    assert "body-file" in decision["permissionDecisionReason"]


async def test_body_file_stdin_dash_denies(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _init_git(repo)
    _stage(repo, "src/Btn.tsx", "x\n")
    out = await pre_pr_gate(
        _hook(repo, "gh pr create --body-file -"),
        None,
        {"signal": None},
    )
    decision = out["hookSpecificOutput"]
    assert decision["permissionDecision"] == "deny"
    assert "stdin" in decision["permissionDecisionReason"].lower()


async def test_short_flag_F_treated_as_body_file(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _init_git(repo)
    _stage(repo, "src/Btn.tsx", "x\n")
    body_file = repo / "body.md"
    body_file.write_text(_QA_GOOD)
    out = await pre_pr_gate(
        _hook(repo, f"gh pr create -F {body_file}"),
        None,
        {"signal": None},
    )
    assert out == {}


async def test_short_flag_b_treated_as_inline_body(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _init_git(repo)
    _stage(repo, "src/Btn.tsx", "x\n")
    out = await pre_pr_gate(
        _hook(repo, f"gh pr create -b '{_QA_GOOD}'"),
        None,
        {"signal": None},
    )
    assert out == {}


async def test_custom_globs_via_env(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _init_git(repo)
    _stage(repo, "templates/page.erb", "<% %>\n")
    os.environ["SYMPHONY_PRE_PR_VIEW_LAYER_GLOBS"] = "*.erb\n*.haml"
    try:
        body_file = repo / "body.md"
        body_file.write_text("no qa section")
        out = await pre_pr_gate(
            _hook(repo, f"gh pr create --body-file {body_file}"),
            None,
            {"signal": None},
        )
        assert out["hookSpecificOutput"]["permissionDecision"] == "deny"
    finally:
        os.environ.pop("SYMPHONY_PRE_PR_VIEW_LAYER_GLOBS", None)


async def test_handles_non_git_cwd_gracefully(tmp_path: Path) -> None:
    # No git repo at cwd → can't compute diff → fail open (don't break the
    # agent for a non-git workspace). Mirrors pre_push_gate "no stack = allow".
    out = await pre_pr_gate(
        _hook(tmp_path, "gh pr create --body 'nothing'"),
        None,
        {"signal": None},
    )
    assert out == {}


async def test_malformed_command_does_not_crash(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _init_git(repo)
    _stage(repo, "src/Btn.tsx", "x\n")
    # Unbalanced quote — shlex should raise, hook must fall back gracefully.
    out = await pre_pr_gate(
        _hook(repo, 'gh pr create --body "unterminated'),
        None,
        {"signal": None},
    )
    # We don't care about allow/deny here, only that it returns a dict.
    assert isinstance(out, dict)
