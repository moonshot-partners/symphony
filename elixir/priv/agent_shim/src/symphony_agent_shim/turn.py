"""turn/start handler — drives ClaudeSDKClient.query and translates events.

Reply for turn/start id=3 returns ``{turn: {id}}`` immediately; the rest of
the SDK output is streamed as JSON-RPC notifications (turn/completed,
turn/failed, item/agent_message). Symphony's ``receive_loop`` consumes these.
"""

import asyncio
import uuid
from collections.abc import Awaitable, Callable
from typing import Any

from claude_agent_sdk import AssistantMessage, ResultMessage, TextBlock

from symphony_agent_shim import protocol
from symphony_agent_shim.thread import ThreadRegistry

Writer = Callable[[dict[str, Any]], Awaitable[None]]


async def handle_turn_start(
    request: dict[str, Any],
    *,
    writer: Writer,
    registry: ThreadRegistry,
) -> dict[str, Any]:
    request_id = request["id"]
    params = request.get("params", {}) or {}
    thread_id = params.get("threadId")
    session = registry.get(thread_id) if thread_id else None
    if session is None:
        return protocol.error(
            request_id=request_id,
            code=-32602,
            message=f"unknown thread: {thread_id!r}",
        )

    prompt = _flatten_input(params.get("input", []))
    turn_id = f"turn-{uuid.uuid4().hex[:12]}"

    session.active_task = asyncio.create_task(
        _drive_turn(session.client, prompt, turn_id, writer),
        name=f"drive-turn-{turn_id}",
    )

    return protocol.response(
        request_id=request_id,
        result={"turn": {"id": turn_id}},
    )


def _flatten_input(blocks: list[dict[str, Any]]) -> str:
    parts: list[str] = []
    for block in blocks:
        if block.get("type") == "text" and isinstance(block.get("text"), str):
            parts.append(block["text"])
    return "\n\n".join(parts)


async def _drive_turn(client: Any, prompt: str, turn_id: str, writer: Writer) -> None:
    try:
        await client.query(prompt)
        async for message in client.receive_response():
            await _emit_message(message, turn_id, writer)
    except Exception as exc:  # noqa: BLE001 — surface SDK error as JSON-RPC failure
        await writer(
            protocol.notification(
                protocol.METHOD_TURN_FAILED,
                {"turn_id": turn_id, "error": str(exc)},
            )
        )


async def _emit_message(message: Any, turn_id: str, writer: Writer) -> None:
    if isinstance(message, AssistantMessage):
        text_parts = [block.text for block in message.content if isinstance(block, TextBlock)]
        if text_parts:
            await writer(
                protocol.notification(
                    "item/agent_message",
                    {"turn_id": turn_id, "text": "\n".join(text_parts)},
                )
            )
        return
    if isinstance(message, ResultMessage):
        await writer(
            protocol.notification(
                protocol.METHOD_TURN_COMPLETED,
                {
                    "turn_id": turn_id,
                    "usage": dict(message.usage or {}),
                    "total_cost_usd": message.total_cost_usd,
                    "stop_reason": message.subtype,
                },
            )
        )
