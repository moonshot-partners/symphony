"""Top-level shim loop — read JSON-RPC frames from stdin, dispatch, write to stdout."""

import asyncio
import sys
from typing import Any

from symphony_agent_shim import protocol
from symphony_agent_shim.framing import LineFramer, write_frame
from symphony_agent_shim.handshake import handle_initialize, is_initialized_notification
from symphony_agent_shim.thread import ThreadRegistry, handle_thread_start
from symphony_agent_shim.tools import ToolBridge
from symphony_agent_shim.turn import TurnTracker, handle_turn_start


async def run_async(*, stdin: Any, stdout: Any) -> None:
    framer = LineFramer(stdin)
    out_lock = asyncio.Lock()

    async def writer(msg: dict[str, Any]) -> None:
        async with out_lock:
            await write_frame(stdout, msg)

    registry = ThreadRegistry()
    bridge = ToolBridge(writer=writer)
    tracker = TurnTracker()

    while True:
        message = await framer.read_message()
        if message is None:
            break

        if "id" in message and "method" not in message:
            bridge.route_response(message)
            continue

        method = message.get("method")
        if method == protocol.METHOD_INITIALIZE:
            await writer(await handle_initialize(message))
        elif is_initialized_notification(message):
            continue
        elif method == protocol.METHOD_THREAD_START:
            await writer(await handle_thread_start(message, registry=registry, bridge=bridge))
        elif method == protocol.METHOD_TURN_START:
            await writer(
                await handle_turn_start(message, writer=writer, registry=registry, tracker=tracker)
            )
        elif "id" in message:
            await writer(
                protocol.error(
                    request_id=message["id"],
                    code=-32601,
                    message=f"method not found: {method!r}",
                )
            )

    await tracker.cancel_all(writer)

    pending = [t for t in asyncio.all_tasks() if t is not asyncio.current_task()]
    for task in pending:
        task.cancel()
    if pending:
        # Bounded drain: SDK's client.query may ignore cancel briefly; cap so
        # SIGTERM never hangs the shim past 5s.
        try:
            await asyncio.wait_for(asyncio.gather(*pending, return_exceptions=True), timeout=5.0)
        except asyncio.TimeoutError:
            pass


def run() -> None:
    asyncio.run(run_async(stdin=sys.stdin.buffer, stdout=sys.stdout.buffer))
