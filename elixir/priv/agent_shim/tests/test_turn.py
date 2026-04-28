from unittest.mock import AsyncMock, MagicMock

import pytest

from symphony_agent_shim.thread import ThreadRegistry, ThreadSession
from symphony_agent_shim.turn import handle_turn_start


@pytest.mark.asyncio
async def test_turn_start_returns_turn_id_then_emits_completed():
    sent: list[dict] = []

    async def writer(msg: dict) -> None:
        sent.append(msg)

    fake_client = MagicMock()

    async def fake_messages():
        # Simulate one assistant text message + a result message
        from claude_agent_sdk import AssistantMessage, ResultMessage, TextBlock

        yield AssistantMessage(content=[TextBlock(text="ok")], model="claude-sonnet-4-6")
        yield ResultMessage(
            subtype="success",
            duration_ms=10,
            duration_api_ms=8,
            is_error=False,
            num_turns=1,
            session_id="s",
            total_cost_usd=0.0001,
            usage={
                "input_tokens": 100,
                "output_tokens": 5,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0,
            },
            result="ok",
        )

    fake_client.query = AsyncMock()
    fake_client.receive_response = lambda: fake_messages()

    registry = ThreadRegistry()
    session = ThreadSession(thread_id="t1", client=fake_client, auto_approve=True)
    registry.register(session)

    request = {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "turn/start",
        "params": {
            "threadId": "t1",
            "input": [{"type": "text", "text": "do thing"}],
            "cwd": "/tmp",
            "title": "MT-1: do thing",
        },
    }

    reply = await handle_turn_start(request, writer=writer, registry=registry)

    assert reply["id"] == 3
    turn_id = reply["result"]["turn"]["id"]

    # Wait for the background task (_drive_turn) to complete
    await session.active_task

    # turn/completed must have been sent via writer
    completed = [m for m in sent if m.get("method") == "turn/completed"]
    assert len(completed) == 1
    assert completed[0]["params"]["turn_id"] == turn_id
    assert completed[0]["params"]["usage"]["input_tokens"] == 100


@pytest.mark.asyncio
async def test_turn_start_unknown_thread_returns_error():
    sent: list[dict] = []
    registry = ThreadRegistry()
    request = {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "turn/start",
        "params": {"threadId": "nonexistent", "input": [], "cwd": "/tmp"},
    }
    reply = await handle_turn_start(request, writer=lambda m: sent.append(m), registry=registry)
    assert "error" in reply
    assert "unknown thread" in reply["error"]["message"]


@pytest.mark.asyncio
async def test_turn_failed_emitted_on_sdk_exception():
    sent: list[dict] = []

    async def writer(msg: dict) -> None:
        sent.append(msg)

    fake_client = MagicMock()
    fake_client.query = AsyncMock(side_effect=RuntimeError("auth bad"))
    fake_client.receive_response = lambda: iter(())

    registry = ThreadRegistry()
    session = ThreadSession(thread_id="t2", client=fake_client, auto_approve=True)
    registry.register(session)

    request = {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "turn/start",
        "params": {"threadId": "t2", "input": [{"type": "text", "text": "x"}], "cwd": "/tmp"},
    }

    reply = await handle_turn_start(request, writer=writer, registry=registry)
    assert reply["id"] == 3  # turn id reply still sent

    # Wait for the background task (_drive_turn) to complete
    await session.active_task

    failed = [m for m in sent if m.get("method") == "turn/failed"]
    assert len(failed) == 1
    assert "auth bad" in failed[0]["params"]["error"]
