from unittest.mock import AsyncMock, MagicMock

import pytest

from symphony_agent_shim.thread import ThreadRegistry, ThreadSession
from symphony_agent_shim.turn import TurnTracker, handle_turn_start


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

    reply = await handle_turn_start(
        request, writer=writer, registry=registry, tracker=TurnTracker()
    )

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
    reply = await handle_turn_start(
        request,
        writer=lambda m: sent.append(m),
        registry=registry,
        tracker=TurnTracker(),
    )
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

    reply = await handle_turn_start(
        request, writer=writer, registry=registry, tracker=TurnTracker()
    )
    assert reply["id"] == 3  # turn id reply still sent

    # Wait for the background task (_drive_turn) to complete
    await session.active_task

    failed = [m for m in sent if m.get("method") == "turn/failed"]
    assert len(failed) == 1
    assert "auth bad" in failed[0]["params"]["error"]


@pytest.mark.asyncio
async def test_emits_synthetic_approval_for_bash_tool_use():
    from claude_agent_sdk import AssistantMessage, ToolUseBlock

    sent: list[dict] = []

    async def writer(msg: dict) -> None:
        sent.append(msg)

    fake_client = MagicMock()

    async def fake_messages():
        yield AssistantMessage(
            content=[ToolUseBlock(id="tu_1", name="Bash", input={"command": "ls"})],
            model="claude-sonnet-4-6",
        )

    fake_client.query = AsyncMock()
    fake_client.receive_response = lambda: fake_messages()

    registry = ThreadRegistry()
    session = ThreadSession(thread_id="t3", client=fake_client, auto_approve=True)
    registry.register(session)

    await handle_turn_start(
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "turn/start",
            "params": {"threadId": "t3", "input": [], "cwd": "/tmp"},
        },
        writer=writer,
        registry=registry,
        tracker=TurnTracker(),
    )
    await session.active_task

    approvals = [m for m in sent if m.get("method") == "item/commandExecution/requestApproval"]
    assert len(approvals) == 1
    assert approvals[0]["params"]["command"] == "ls"


@pytest.mark.asyncio
async def test_turn_completed_accumulates_usage_from_assistant_messages():
    """When ResultMessage.usage is None, token totals must come from AssistantMessage.usage."""
    sent: list[dict] = []

    async def writer(msg: dict) -> None:
        sent.append(msg)

    fake_client = MagicMock()

    async def fake_messages():
        from claude_agent_sdk import AssistantMessage, ResultMessage, TextBlock

        # Two assistant turns, each with per-API-call usage
        yield AssistantMessage(
            content=[TextBlock(text="thinking")],
            model="claude-sonnet-4-6",
            usage={"input_tokens": 300, "output_tokens": 50, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0},
        )
        yield AssistantMessage(
            content=[TextBlock(text="done")],
            model="claude-sonnet-4-6",
            usage={"input_tokens": 200, "output_tokens": 30, "cache_read_input_tokens": 10, "cache_creation_input_tokens": 0},
        )
        # ResultMessage with no usage (as Claude CLI emits in practice)
        yield ResultMessage(
            subtype="end_turn",
            duration_ms=5000,
            duration_api_ms=4000,
            is_error=False,
            num_turns=2,
            session_id="s2",
            total_cost_usd=0.002,
            usage=None,
            result="done",
        )

    fake_client.query = AsyncMock()
    fake_client.receive_response = lambda: fake_messages()

    registry = ThreadRegistry()
    session = ThreadSession(thread_id="t4", client=fake_client, auto_approve=True)
    registry.register(session)

    await handle_turn_start(
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "turn/start",
            "params": {"threadId": "t4", "input": [{"type": "text", "text": "go"}], "cwd": "/tmp"},
        },
        writer=writer,
        registry=registry,
        tracker=TurnTracker(),
    )
    await session.active_task

    completed = [m for m in sent if m.get("method") == "turn/completed"]
    assert len(completed) == 1
    usage = completed[0]["params"]["usage"]
    assert usage["input_tokens"] == 500   # 300 + 200
    assert usage["output_tokens"] == 80   # 50 + 30
    assert usage["cache_read_input_tokens"] == 10


@pytest.mark.asyncio
async def test_item_agent_message_carries_running_usage_for_realtime_workpad():
    """Each item/agent_message must include accumulated usage so the
    orchestrator can refresh the workpad token counter mid-turn (heartbeat),
    instead of waiting for turn/completed."""
    sent: list[dict] = []

    async def writer(msg: dict) -> None:
        sent.append(msg)

    fake_client = MagicMock()

    async def fake_messages():
        from claude_agent_sdk import AssistantMessage, ResultMessage, TextBlock

        yield AssistantMessage(
            content=[TextBlock(text="first")],
            model="claude-sonnet-4-6",
            usage={
                "input_tokens": 120,
                "output_tokens": 40,
                "cache_read_input_tokens": 0,
                "cache_creation_input_tokens": 0,
            },
        )
        yield AssistantMessage(
            content=[TextBlock(text="second")],
            model="claude-sonnet-4-6",
            usage={
                "input_tokens": 80,
                "output_tokens": 20,
                "cache_read_input_tokens": 5,
                "cache_creation_input_tokens": 0,
            },
        )
        yield ResultMessage(
            subtype="end_turn",
            duration_ms=10,
            duration_api_ms=8,
            is_error=False,
            num_turns=1,
            session_id="s5",
            total_cost_usd=0.001,
            usage=None,
            result="ok",
        )

    fake_client.query = AsyncMock()
    fake_client.receive_response = lambda: fake_messages()

    registry = ThreadRegistry()
    session = ThreadSession(thread_id="t5", client=fake_client, auto_approve=True)
    registry.register(session)

    await handle_turn_start(
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "turn/start",
            "params": {"threadId": "t5", "input": [{"type": "text", "text": "go"}], "cwd": "/tmp"},
        },
        writer=writer,
        registry=registry,
        tracker=TurnTracker(),
    )
    await session.active_task

    messages = [m for m in sent if m.get("method") == "item/agent_message"]
    assert len(messages) == 2

    # First item must carry running totals after the first AssistantMessage
    first_usage = messages[0]["params"].get("usage")
    assert first_usage is not None, "item/agent_message must include usage"
    assert first_usage["input_tokens"] == 120
    assert first_usage["output_tokens"] == 40

    # Second item must carry the accumulated totals (per-call usage summed)
    second_usage = messages[1]["params"].get("usage")
    assert second_usage is not None
    assert second_usage["input_tokens"] == 200  # 120 + 80
    assert second_usage["output_tokens"] == 60  # 40 + 20
    assert second_usage["cache_read_input_tokens"] == 5


@pytest.mark.asyncio
async def test_item_agent_message_omits_usage_when_assistant_message_has_no_usage():
    """If the assistant message has no usage (accumulated still empty), the
    notification must NOT carry a phantom empty usage dict — emit nothing so the
    orchestrator extractor short-circuits cleanly."""
    sent: list[dict] = []

    async def writer(msg: dict) -> None:
        sent.append(msg)

    fake_client = MagicMock()

    async def fake_messages():
        from claude_agent_sdk import AssistantMessage, ResultMessage, TextBlock

        yield AssistantMessage(content=[TextBlock(text="hi")], model="claude-sonnet-4-6")
        yield ResultMessage(
            subtype="end_turn",
            duration_ms=1,
            duration_api_ms=1,
            is_error=False,
            num_turns=1,
            session_id="s6",
            total_cost_usd=0.0,
            usage=None,
            result="ok",
        )

    fake_client.query = AsyncMock()
    fake_client.receive_response = lambda: fake_messages()

    registry = ThreadRegistry()
    session = ThreadSession(thread_id="t6", client=fake_client, auto_approve=True)
    registry.register(session)

    await handle_turn_start(
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "turn/start",
            "params": {"threadId": "t6", "input": [{"type": "text", "text": "go"}], "cwd": "/tmp"},
        },
        writer=writer,
        registry=registry,
        tracker=TurnTracker(),
    )
    await session.active_task

    messages = [m for m in sent if m.get("method") == "item/agent_message"]
    assert len(messages) == 1
    assert "usage" not in messages[0]["params"]


@pytest.mark.asyncio
async def test_cancel_emits_turn_cancelled():
    from symphony_agent_shim.turn import TurnTracker

    sent: list[dict] = []

    async def writer(msg: dict) -> None:
        sent.append(msg)

    tracker = TurnTracker()
    tracker.register("turn-x")
    await tracker.cancel_all(writer)

    cancelled = [m for m in sent if m.get("method") == "turn/cancelled"]
    assert len(cancelled) == 1
    assert cancelled[0]["params"]["turn_id"] == "turn-x"
