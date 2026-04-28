"""Bridge dynamicTools[] (Codex protocol) ↔ Claude Agent SDK MCP tools.

For each Symphony tool spec, we register a Python ``@tool`` whose body
delegates to ``ToolBridge.invoke_tool`` — which sends ``item/tool/call``
to Symphony's stdin (the shim's stdout) and awaits the reply by id.

This means: SDK invokes Python tool → Python tool sends JSON-RPC to
Symphony → Symphony's ``Codex.AppServer.maybe_handle_approval_request/8``
handler executes the Elixir-side ``DynamicTool.execute/2`` → Symphony
sends JSON-RPC response → Python tool returns to SDK → SDK continues.
"""

import asyncio
import itertools
from collections.abc import Awaitable, Callable
from typing import Any

from claude_agent_sdk import create_sdk_mcp_server, tool

from symphony_agent_shim import protocol

Writer = Callable[[dict[str, Any]], Awaitable[None]]


class ToolBridge:
    def __init__(self, writer: Writer) -> None:
        self._writer = writer
        self._counter = itertools.count(start=10000)
        self._pending: dict[int, asyncio.Future[dict[str, Any]]] = {}

    async def invoke_tool(self, tool_name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        request_id = next(self._counter)
        loop = asyncio.get_running_loop()
        future: asyncio.Future[dict[str, Any]] = loop.create_future()
        self._pending[request_id] = future
        try:
            await self._writer(
                {
                    "jsonrpc": protocol.JSONRPC_VERSION,
                    "id": request_id,
                    "method": protocol.METHOD_ITEM_TOOL_CALL,
                    "params": {"tool": tool_name, "arguments": arguments},
                }
            )
            return await future
        finally:
            self._pending.pop(request_id, None)

    def route_response(self, message: dict[str, Any]) -> None:
        msg_id = message.get("id")
        if msg_id is None:
            return
        future = self._pending.get(msg_id)
        if future is None or future.done():
            return
        if "error" in message:
            err = message["error"]
            future.set_exception(RuntimeError(err.get("message", "tool error")))
        else:
            future.set_result(message.get("result", {}))


def build_mcp_server_from_specs(specs: list[dict[str, Any]], *, bridge: ToolBridge) -> Any:
    sdk_tools = []
    for spec in specs:
        sdk_tools.append(_make_tool(spec, bridge))
    return create_sdk_mcp_server(name="symphony", version="0.1.0", tools=sdk_tools)


def _make_tool(spec: dict[str, Any], bridge: ToolBridge):
    name = spec["name"]
    description = spec.get("description", "")
    schema = spec.get("input_schema", {"type": "object"})

    @tool(name, description, schema)
    async def _impl(args: dict[str, Any]) -> dict[str, Any]:
        result = await bridge.invoke_tool(name, args)
        text = result.get("output") or str(result)
        return {"content": [{"type": "text", "text": text}]}

    return _impl
