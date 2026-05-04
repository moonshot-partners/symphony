"""Codex JSON-RPC method names + envelope helpers.

Method names mirror those parsed in
``lib/symphony_elixir/codex/app_server.ex``. Do NOT rename without updating
both sides simultaneously.
"""

from typing import Any

METHOD_INITIALIZE = "initialize"
METHOD_INITIALIZED = "initialized"
METHOD_THREAD_START = "thread/start"
METHOD_TURN_START = "turn/start"
METHOD_TURN_COMPLETED = "turn/completed"
METHOD_TURN_FAILED = "turn/failed"
METHOD_TURN_CANCELLED = "turn/cancelled"
METHOD_ITEM_TOOL_CALL = "item/tool/call"
METHOD_ITEM_COMMAND_APPROVAL = "item/commandExecution/requestApproval"
METHOD_EXEC_COMMAND_APPROVAL = "execCommandApproval"
METHOD_APPLY_PATCH_APPROVAL = "applyPatchApproval"
METHOD_FILE_CHANGE_APPROVAL = "item/fileChange/requestApproval"
METHOD_TOOL_USER_INPUT = "item/tool/requestUserInput"

JSONRPC_VERSION = "2.0"


def response(request_id: int | str, result: Any) -> dict[str, Any]:
    return {"jsonrpc": JSONRPC_VERSION, "id": request_id, "result": result}


def notification(method: str, params: dict[str, Any]) -> dict[str, Any]:
    return {"jsonrpc": JSONRPC_VERSION, "method": method, "params": params}


def error(request_id: int | str, code: int, message: str) -> dict[str, Any]:
    return {
        "jsonrpc": JSONRPC_VERSION,
        "id": request_id,
        "error": {"code": code, "message": message},
    }
