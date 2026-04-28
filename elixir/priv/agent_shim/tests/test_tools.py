import asyncio

import pytest

from symphony_agent_shim.tools import ToolBridge, build_mcp_server_from_specs


@pytest.mark.asyncio
async def test_bridge_sends_request_and_awaits_response():
    sent: list[dict] = []

    async def writer(msg: dict) -> None:
        sent.append(msg)

    bridge = ToolBridge(writer=writer)

    async def fake_responder():
        # Simulate Symphony replying after request is sent
        await asyncio.sleep(0.01)
        msg_id = sent[-1]["id"]
        bridge.route_response(
            {"id": msg_id, "result": {"success": True, "output": "done"}}
        )

    asyncio.create_task(fake_responder())

    result = await bridge.invoke_tool("greet", {"name": "world"})
    assert result == {"success": True, "output": "done"}

    assert sent[0]["method"] == "item/tool/call"
    assert sent[0]["params"]["tool"] == "greet"
    assert sent[0]["params"]["arguments"] == {"name": "world"}


@pytest.mark.asyncio
async def test_bridge_propagates_error_response():
    sent: list[dict] = []

    async def writer(msg: dict) -> None:
        sent.append(msg)

    bridge = ToolBridge(writer=writer)

    async def fake_responder():
        await asyncio.sleep(0.01)
        msg_id = sent[-1]["id"]
        bridge.route_response(
            {"id": msg_id, "error": {"code": -32000, "message": "boom"}}
        )

    asyncio.create_task(fake_responder())

    with pytest.raises(RuntimeError, match="boom"):
        await bridge.invoke_tool("greet", {})


@pytest.mark.asyncio
async def test_unknown_response_id_is_ignored():
    bridge = ToolBridge(writer=lambda _: None)
    # No raise expected
    bridge.route_response({"id": 9999, "result": {}})


def test_build_mcp_server_from_specs_creates_callable_tools(monkeypatch):
    captured = {}

    def fake_create(*, name, version, tools):
        captured["name"] = name
        captured["tools"] = tools
        return f"server:{name}"

    monkeypatch.setattr(
        "symphony_agent_shim.tools.create_sdk_mcp_server", fake_create
    )

    specs = [
        {
            "name": "linear_graphql",
            "description": "run GraphQL against Linear",
            "input_schema": {
                "type": "object",
                "properties": {"query": {"type": "string"}},
                "required": ["query"],
            },
        }
    ]
    bridge = ToolBridge(writer=lambda _: None)
    server = build_mcp_server_from_specs(specs, bridge=bridge)
    assert server == "server:symphony"
    assert captured["name"] == "symphony"
    assert len(captured["tools"]) == 1


@pytest.mark.asyncio
async def test_invoke_tool_cancellation_cleans_up_pending():
    async def slow_writer(_: dict) -> None:
        await asyncio.sleep(0)

    bridge = ToolBridge(writer=slow_writer)
    task = asyncio.create_task(bridge.invoke_tool("x", {}))
    await asyncio.sleep(0.01)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert len(bridge._pending) == 0
    # Late response is silently dropped; no crash
    bridge.route_response({"id": 10000, "result": {}})


@pytest.mark.asyncio
async def test_bridge_preserves_empty_string_output():
    sent: list[dict] = []

    async def writer(msg: dict) -> None:
        sent.append(msg)

    bridge = ToolBridge(writer=writer)

    async def fake_responder():
        await asyncio.sleep(0.01)
        msg_id = sent[-1]["id"]
        bridge.route_response({"id": msg_id, "result": {"output": ""}})

    asyncio.create_task(fake_responder())

    result = await bridge.invoke_tool("noop", {})
    assert result == {"output": ""}
