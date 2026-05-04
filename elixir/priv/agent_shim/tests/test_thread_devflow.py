"""thread/start activates devflow-agent guardrails when devflowContext provided."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import AsyncMock, MagicMock

import pytest

from symphony_agent_shim.thread import ThreadRegistry, handle_thread_start
from symphony_agent_shim.tools import ToolBridge


def _seed_lite_hooks(devflow_root: Path) -> None:
    hooks = devflow_root / "hooks"
    hooks.mkdir(parents=True, exist_ok=True)
    for name in (
        "secrets_gate",
        "pre_push_gate",
        "commit_validator",
        "tdd_enforcer",
        "file_checker",
        "context_monitor",
        "pre_compact",
        "stop_dispatcher",
        "pre_edit_overwrite_guard",
        "concurrent_edit_lock",
        "discovery_scan",
        "freshness_check",
        "repo_conventions",
        "state_cleanup",
        "codeowners_check",
    ):
        (hooks / f"{name}.py").write_text("import sys; sys.exit(0)\n")


@pytest.mark.asyncio
async def test_thread_start_without_devflow_context_keeps_current_behavior(monkeypatch, tmp_path):
    """Backwards-compat: no devflowContext -> Options built without devflow hooks."""
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")

    fake_client = MagicMock()
    fake_client.connect = AsyncMock()
    sdk_client_factory = MagicMock(return_value=fake_client)
    monkeypatch.setattr("symphony_agent_shim.thread.ClaudeSDKClient", sdk_client_factory)

    registry = ThreadRegistry()
    bridge = ToolBridge(writer=lambda _: None)
    cwd = tmp_path / "repo"
    cwd.mkdir()
    request = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "thread/start",
        "params": {
            "cwd": str(cwd),
            "sandbox": "workspace-write",
            "approvalPolicy": "never",
            "dynamicTools": [],
        },
    }

    result = await handle_thread_start(request, registry=registry, bridge=bridge)

    assert "result" in result
    assert "thread" in result["result"]
    assert "devflowSessionId" not in result["result"]
    options = sdk_client_factory.call_args.kwargs["options"]
    assert not hasattr(options, "hooks") or options.hooks is None or options.hooks == {}


@pytest.mark.asyncio
async def test_thread_start_with_devflow_context_attaches_guardrails(monkeypatch, tmp_path):
    """devflowContext present -> compose_devflow_bundle wired + session_id surfaced."""
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    monkeypatch.delenv("GH_TOKEN", raising=False)
    monkeypatch.delenv("GITHUB_TOKEN", raising=False)
    monkeypatch.delenv("SYMPHONY_GITHUB_APP_ID", raising=False)
    monkeypatch.delenv("SYMPHONY_GITHUB_APP_INSTALLATION_ID", raising=False)
    monkeypatch.delenv("SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH", raising=False)

    fake_client = MagicMock()
    fake_client.connect = AsyncMock()
    sdk_client_factory = MagicMock(return_value=fake_client)
    monkeypatch.setattr("symphony_agent_shim.thread.ClaudeSDKClient", sdk_client_factory)

    registry = ThreadRegistry()
    bridge = ToolBridge(writer=lambda _: None)
    devflow_root = tmp_path / "lite"
    _seed_lite_hooks(devflow_root)
    cwd = tmp_path / "repo"
    cwd.mkdir()
    request = {
        "jsonrpc": "2.0",
        "id": 2,
        "method": "thread/start",
        "params": {
            "cwd": str(cwd),
            "sandbox": "workspace-write",
            "approvalPolicy": "never",
            "dynamicTools": [],
            "devflowContext": {
                "issueIdentifier": "T-1",
                "issueTitle": "wired",
                "issueUrl": "",
                "devflowRoot": str(devflow_root),
                "policy": "auto_deny",
                "basePrompt": "You are an unattended agent.",
            },
        },
    }

    result = await handle_thread_start(request, registry=registry, bridge=bridge)

    assert "result" in result
    assert "thread" in result["result"]
    sid = result["result"].get("devflowSessionId")
    assert isinstance(sid, str) and sid
    # Marker must have been written under devflow_root/state/<sid>/active-spec.json
    marker = devflow_root / "state" / sid / "active-spec.json"
    assert marker.exists()
    # ClaudeAgentOptions passed to ClaudeSDKClient must have hooks dict.
    options = sdk_client_factory.call_args.kwargs["options"]
    assert "PreToolUse" in options.hooks
    assert "Stop" in options.hooks
    assert options.system_prompt is not None
    assert "You are an unattended agent." in options.system_prompt


@pytest.mark.asyncio
async def test_thread_start_unknown_policy_returns_error(monkeypatch, tmp_path):
    """Bad policy string -> JSON-RPC error -32602, no SDK connect."""
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    monkeypatch.delenv("GH_TOKEN", raising=False)
    monkeypatch.delenv("GITHUB_TOKEN", raising=False)
    monkeypatch.delenv("SYMPHONY_GITHUB_APP_ID", raising=False)
    monkeypatch.delenv("SYMPHONY_GITHUB_APP_INSTALLATION_ID", raising=False)
    monkeypatch.delenv("SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH", raising=False)

    fake_client = MagicMock()
    fake_client.connect = AsyncMock()
    sdk_client_factory = MagicMock(return_value=fake_client)
    monkeypatch.setattr("symphony_agent_shim.thread.ClaudeSDKClient", sdk_client_factory)

    registry = ThreadRegistry()
    bridge = ToolBridge(writer=lambda _: None)
    devflow_root = tmp_path / "lite"
    _seed_lite_hooks(devflow_root)
    cwd = tmp_path / "repo"
    cwd.mkdir()
    request = {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "thread/start",
        "params": {
            "cwd": str(cwd),
            "sandbox": "workspace-write",
            "approvalPolicy": "never",
            "dynamicTools": [],
            "devflowContext": {
                "issueIdentifier": "T-2",
                "issueTitle": "bad policy",
                "issueUrl": "",
                "devflowRoot": str(devflow_root),
                "policy": "nonsense",
                "basePrompt": "",
            },
        },
    }

    result = await handle_thread_start(request, registry=registry, bridge=bridge)

    assert "error" in result
    assert result["error"]["code"] == -32602
    fake_client.connect.assert_not_awaited()
