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
    assert options.permission_mode == "acceptEdits"
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
