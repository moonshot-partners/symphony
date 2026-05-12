"""turn/start handler — drives ClaudeSDKClient.query and translates events.

Reply for turn/start id=3 returns ``{turn: {id}}`` immediately; the rest of
the SDK output is streamed as JSON-RPC notifications (turn/completed,
turn/failed, item/agent_message). Symphony's ``receive_loop`` consumes these.
"""

import asyncio
import uuid
from collections.abc import Awaitable, Callable
from typing import Any

from claude_agent_sdk import AssistantMessage, ResultMessage, TextBlock, ToolUseBlock

from symphony_agent_shim import protocol
from symphony_agent_shim.thread import ThreadRegistry

Writer = Callable[[dict[str, Any]], Awaitable[None]]

_BASH_TOOLS = {"Bash", "mcp__bash__bash"}
_FILE_WRITE_TOOLS = {"Edit", "Write", "NotebookEdit"}


class TurnTracker:
    def __init__(self) -> None:
        self._active: set[str] = set()

    def register(self, turn_id: str) -> None:
        self._active.add(turn_id)

    def unregister(self, turn_id: str) -> None:
        self._active.discard(turn_id)

    async def cancel_all(self, writer: Writer) -> None:
        for turn_id in list(self._active):
            if turn_id not in self._active:
                continue
            await writer(
                protocol.notification(
                    protocol.METHOD_TURN_CANCELLED,
                    {"turn_id": turn_id, "reason": "shim shutdown"},
                )
            )
            self._active.discard(turn_id)


async def handle_turn_start(
    request: dict[str, Any],
    *,
    writer: Writer,
    registry: ThreadRegistry,
    tracker: TurnTracker,
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
        _drive_turn(session.client, prompt, turn_id, writer, tracker),
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


async def _drive_turn(
    client: Any, prompt: str, turn_id: str, writer: Writer, tracker: TurnTracker
) -> None:
    tracker.register(turn_id)
    accumulated: dict[str, int] = {}
    try:
        try:
            await client.query(prompt)
            async for message in client.receive_response():
                if isinstance(message, AssistantMessage) and isinstance(message.usage, dict):
                    for key, val in message.usage.items():
                        if isinstance(val, int):
                            accumulated[key] = accumulated.get(key, 0) + val
                await _emit_message(message, turn_id, writer, accumulated)
        except Exception as exc:  # noqa: BLE001 — surface SDK error as JSON-RPC failure
            await writer(
                protocol.notification(
                    protocol.METHOD_TURN_FAILED,
                    {"turn_id": turn_id, "error": str(exc)},
                )
            )
    finally:
        tracker.unregister(turn_id)


async def _emit_message(
    message: Any, turn_id: str, writer: Writer, accumulated: dict[str, int]
) -> None:
    if isinstance(message, AssistantMessage):
        for block in message.content:
            if isinstance(block, ToolUseBlock):
                await _emit_synthetic_approval(block, turn_id, writer)
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
        # ResultMessage.usage is None in practice (Claude CLI doesn't emit cumulative
        # usage in the result JSON). Fall back to tokens accumulated from each
        # AssistantMessage.usage (per-API-call Anthropic usage dict).
        usage = dict(message.usage) if message.usage else accumulated
        await writer(
            protocol.notification(
                protocol.METHOD_TURN_COMPLETED,
                {
                    "turn_id": turn_id,
                    "usage": usage,
                    "total_cost_usd": message.total_cost_usd,
                    "stop_reason": message.subtype,
                },
            )
        )


async def _emit_synthetic_approval(block: ToolUseBlock, turn_id: str, writer: Writer) -> None:
    inp = block.input or {}
    if block.name in _BASH_TOOLS:
        await writer(
            protocol.notification(
                protocol.METHOD_ITEM_COMMAND_APPROVAL,
                {
                    "turn_id": turn_id,
                    "tool_use_id": block.id,
                    "command": inp.get("command", ""),
                },
            )
        )
    elif block.name in _FILE_WRITE_TOOLS:
        await writer(
            protocol.notification(
                protocol.METHOD_FILE_CHANGE_APPROVAL,
                {
                    "turn_id": turn_id,
                    "tool_use_id": block.id,
                    "path": inp.get("file_path", ""),
                },
            )
        )
