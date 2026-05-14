"""Tests for secrets_gate guardrail hook.

Blocks Write/Edit/MultiEdit when tool input contains credential-like strings.
Pattern catalog targets the high-value, low-false-positive credential families
we routinely see in agent screw-ups: Anthropic OAuth/API keys, GitHub PATs,
AWS access key IDs, OpenAI keys, generic PEM private key blocks.
"""

from __future__ import annotations

import pytest

from symphony_agent_shim.guardrails.secrets_gate import secrets_gate


def _hook_input(tool_name: str, tool_input: dict) -> dict:
    return {
        "hook_event_name": "PreToolUse",
        "session_id": "s",
        "transcript_path": "/tmp/t",
        "cwd": "/tmp",
        "tool_name": tool_name,
        "tool_input": tool_input,
        "tool_use_id": "u1",
    }


def _ctx() -> dict:
    return {"signal": None}


@pytest.mark.parametrize(
    "secret",
    [
        "sk-ant-api03-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "sk-ant-oat01-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "AKIAIOSFODNN7EXAMPLE",
        "ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "github_pat_11ABCDEFG_aaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "sk-proj-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "-----BEGIN RSA PRIVATE KEY-----",
        "-----BEGIN OPENSSH PRIVATE KEY-----",
    ],
)
async def test_blocks_known_credential_patterns(secret: str) -> None:
    out = await secrets_gate(
        _hook_input("Write", {"file_path": "/tmp/x.txt", "content": f"foo {secret} bar"}),
        None,
        _ctx(),
    )
    deny = out["hookSpecificOutput"]
    assert deny["permissionDecision"] == "deny"
    assert "secret" in deny["permissionDecisionReason"].lower()


async def test_allows_clean_content() -> None:
    out = await secrets_gate(
        _hook_input("Write", {"file_path": "/tmp/x.txt", "content": "print('hello')"}),
        None,
        _ctx(),
    )
    assert out["hookSpecificOutput"]["permissionDecision"] == "allow"


async def test_inspects_edit_new_string() -> None:
    out = await secrets_gate(
        _hook_input(
            "Edit",
            {
                "file_path": "/tmp/x.py",
                "old_string": "TOKEN = ''",
                "new_string": "TOKEN = 'sk-ant-api03-aaaaaaaaaaaaaaaaaaaaaaaaaaaa'",
            },
        ),
        None,
        _ctx(),
    )
    assert out["hookSpecificOutput"]["permissionDecision"] == "deny"


async def test_inspects_multiedit_edits() -> None:
    out = await secrets_gate(
        _hook_input(
            "MultiEdit",
            {
                "file_path": "/tmp/x.py",
                "edits": [
                    {"old_string": "a", "new_string": "b"},
                    {"old_string": "c", "new_string": "AKIAIOSFODNN7EXAMPLE"},
                ],
            },
        ),
        None,
        _ctx(),
    )
    assert out["hookSpecificOutput"]["permissionDecision"] == "deny"


async def test_ignores_non_write_tools() -> None:
    out = await secrets_gate(
        _hook_input("Bash", {"command": "echo sk-ant-api03-deadbeef"}),
        None,
        _ctx(),
    )
    assert out["hookSpecificOutput"]["permissionDecision"] == "allow"
