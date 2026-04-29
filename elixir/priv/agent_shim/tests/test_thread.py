from unittest.mock import AsyncMock, MagicMock

import pytest

from symphony_agent_shim.thread import ThreadRegistry, handle_thread_start
from symphony_agent_shim.tools import ToolBridge


@pytest.mark.asyncio
async def test_thread_start_creates_session_and_returns_id(monkeypatch, tmp_path):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")

    fake_client = MagicMock()
    fake_client.connect = AsyncMock()
    sdk_client_factory = MagicMock(return_value=fake_client)
    monkeypatch.setattr("symphony_agent_shim.thread.ClaudeSDKClient", sdk_client_factory)

    workspace = tmp_path / "ws"
    workspace.mkdir()

    registry = ThreadRegistry()
    bridge = ToolBridge(writer=lambda _: None)
    request = {
        "jsonrpc": "2.0",
        "id": 2,
        "method": "thread/start",
        "params": {
            "approvalPolicy": "never",
            "sandbox": "workspace-write",
            "cwd": str(workspace),
            "dynamicTools": [],
        },
    }

    reply = await handle_thread_start(request, registry=registry, bridge=bridge)

    assert reply["id"] == 2
    thread_id = reply["result"]["thread"]["id"]
    assert thread_id in registry
    sdk_client_factory.assert_called_once()
    fake_client.connect.assert_awaited_once()
    options = sdk_client_factory.call_args.kwargs["options"]
    assert options.permission_mode == "bypassPermissions"
    assert str(options.cwd) == str(workspace)
    mcp_servers = options.mcp_servers
    assert "symphony" in mcp_servers
    assert isinstance(mcp_servers["symphony"], dict)
    assert mcp_servers["symphony"]["type"] == "sdk"
    assert mcp_servers["symphony"]["name"] == "symphony"
    assert mcp_servers["symphony"]["instance"] is not None


@pytest.mark.asyncio
async def test_thread_start_rejects_unknown_sandbox(monkeypatch, tmp_path):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    registry = ThreadRegistry()
    bridge = ToolBridge(writer=lambda _: None)
    request = {
        "jsonrpc": "2.0",
        "id": 2,
        "method": "thread/start",
        "params": {
            "approvalPolicy": "never",
            "sandbox": "hyperdrive",
            "cwd": str(tmp_path),
            "dynamicTools": [],
        },
    }
    reply = await handle_thread_start(request, registry=registry, bridge=bridge)
    assert "error" in reply
    assert "unknown sandbox tier" in reply["error"]["message"]


@pytest.mark.asyncio
async def test_thread_start_injects_git_env_into_options(monkeypatch, tmp_path):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    monkeypatch.setenv("GH_TOKEN", "ghp_user_pat")
    # Ensure App vars are absent so resolve_git_env falls back to PAT.
    monkeypatch.delenv("SYMPHONY_GITHUB_APP_ID", raising=False)
    monkeypatch.delenv("SYMPHONY_GITHUB_APP_INSTALLATION_ID", raising=False)
    monkeypatch.delenv("SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH", raising=False)

    fake_client = MagicMock()
    fake_client.connect = AsyncMock()
    sdk_client_factory = MagicMock(return_value=fake_client)
    monkeypatch.setattr("symphony_agent_shim.thread.ClaudeSDKClient", sdk_client_factory)

    workspace = tmp_path / "ws"
    workspace.mkdir()
    registry = ThreadRegistry()
    bridge = ToolBridge(writer=lambda _: None)
    request = {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "thread/start",
        "params": {
            "approvalPolicy": "never",
            "sandbox": "workspace-write",
            "cwd": str(workspace),
            "dynamicTools": [],
        },
    }

    await handle_thread_start(request, registry=registry, bridge=bridge)

    options = sdk_client_factory.call_args.kwargs["options"]
    assert options.env.get("GH_TOKEN") == "ghp_user_pat"
    assert options.env.get("GITHUB_TOKEN") == "ghp_user_pat"
    # Anthropic creds still propagated alongside.
    assert options.env.get("ANTHROPIC_API_KEY") == "sk-test"


@pytest.mark.asyncio
async def test_thread_start_works_without_any_git_credentials(monkeypatch, tmp_path):
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

    workspace = tmp_path / "ws"
    workspace.mkdir()
    registry = ThreadRegistry()
    bridge = ToolBridge(writer=lambda _: None)
    request = {
        "jsonrpc": "2.0",
        "id": 4,
        "method": "thread/start",
        "params": {
            "approvalPolicy": "never",
            "sandbox": "workspace-write",
            "cwd": str(workspace),
            "dynamicTools": [],
        },
    }

    reply = await handle_thread_start(request, registry=registry, bridge=bridge)

    assert "result" in reply  # no error: missing git creds is not fatal
    options = sdk_client_factory.call_args.kwargs["options"]
    assert "GH_TOKEN" not in options.env
    assert "GITHUB_TOKEN" not in options.env


@pytest.mark.asyncio
async def test_thread_start_fails_without_credentials(monkeypatch, tmp_path):
    monkeypatch.delenv("ANTHROPIC_OAUTH_TOKEN", raising=False)
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    registry = ThreadRegistry()
    bridge = ToolBridge(writer=lambda _: None)
    request = {
        "jsonrpc": "2.0",
        "id": 2,
        "method": "thread/start",
        "params": {
            "approvalPolicy": "never",
            "sandbox": "workspace-write",
            "cwd": str(tmp_path),
            "dynamicTools": [],
        },
    }
    reply = await handle_thread_start(request, registry=registry, bridge=bridge)
    assert "error" in reply
    assert "credentials" in reply["error"]["message"]
