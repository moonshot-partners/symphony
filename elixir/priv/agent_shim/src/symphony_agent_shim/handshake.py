"""initialize / initialized JSON-RPC handlers (Codex compat).

Symphony's ``Codex.AppServer.send_initialize/1`` sends ``initialize`` with
id=1 expecting a response, then a notification ``initialized``. Reply shape
must include ``capabilities`` and ``serverInfo``.
"""

from typing import Any

from symphony_agent_shim import protocol


async def handle_initialize(request: dict[str, Any]) -> dict[str, Any]:
    return protocol.response(
        request_id=request["id"],
        result={
            "capabilities": {"experimentalApi": True},
            "serverInfo": {
                "name": "symphony-agent-shim",
                "version": "0.1.0",
            },
        },
    )


def is_initialized_notification(message: dict[str, Any]) -> bool:
    return message.get("method") == protocol.METHOD_INITIALIZED and "id" not in message
