import asyncio
import io
import json
from unittest.mock import AsyncMock, MagicMock

import pytest


@pytest.mark.asyncio
async def test_server_initialize_thread_smoke(monkeypatch, tmp_path):
    """Pipe initialize -> initialized -> thread/start; assert thread reply comes out."""
    from claude_agent_sdk import ResultMessage

    from symphony_agent_shim.server import run_async

    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")

    fake_client = MagicMock()

    async def fake_msgs():
        yield ResultMessage(
            subtype="success",
            duration_ms=1,
            duration_api_ms=1,
            is_error=False,
            num_turns=1,
            session_id="s",
            total_cost_usd=0.001,
            usage={
                "input_tokens": 1,
                "output_tokens": 1,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0,
            },
            result="ok",
        )

    fake_client.connect = AsyncMock()
    fake_client.query = AsyncMock()
    fake_client.receive_response = lambda: fake_msgs()
    monkeypatch.setattr(
        "symphony_agent_shim.thread.ClaudeSDKClient",
        MagicMock(return_value=fake_client),
    )

    workspace = tmp_path / "ws"
    workspace.mkdir()

    inputs = (
        b"\n".join(
            [
                json.dumps(
                    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}
                ).encode(),
                json.dumps({"jsonrpc": "2.0", "method": "initialized", "params": {}}).encode(),
                json.dumps(
                    {
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
                ).encode(),
            ]
        )
        + b"\n"
    )

    stdin = io.BytesIO(inputs)
    stdout = io.BytesIO()

    await asyncio.wait_for(run_async(stdin=stdin, stdout=stdout), timeout=2.0)

    stdout.seek(0)
    lines = [json.loads(line) for line in stdout.readlines() if line.strip()]
    init_reply = next(m for m in lines if m.get("id") == 1)
    thread_reply = next(m for m in lines if m.get("id") == 2)
    assert "result" in init_reply
    assert thread_reply["result"]["thread"]["id"].startswith("shim-")
