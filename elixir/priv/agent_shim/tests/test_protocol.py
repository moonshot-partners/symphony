from symphony_agent_shim import protocol


def test_codex_method_constants_match_app_server_ex():
    # Mirrors method names parsed in app_server.ex
    assert protocol.METHOD_INITIALIZE == "initialize"
    assert protocol.METHOD_INITIALIZED == "initialized"
    assert protocol.METHOD_THREAD_START == "thread/start"
    assert protocol.METHOD_TURN_START == "turn/start"
    assert protocol.METHOD_TURN_COMPLETED == "turn/completed"
    assert protocol.METHOD_TURN_FAILED == "turn/failed"
    assert protocol.METHOD_TURN_CANCELLED == "turn/cancelled"
    assert protocol.METHOD_ITEM_TOOL_CALL == "item/tool/call"
    assert protocol.METHOD_ITEM_COMMAND_APPROVAL == "item/commandExecution/requestApproval"
    assert protocol.METHOD_EXEC_COMMAND_APPROVAL == "execCommandApproval"
    assert protocol.METHOD_APPLY_PATCH_APPROVAL == "applyPatchApproval"
    assert protocol.METHOD_FILE_CHANGE_APPROVAL == "item/fileChange/requestApproval"
    assert protocol.METHOD_TOOL_USER_INPUT == "item/tool/requestUserInput"


def test_response_envelope_helper():
    env = protocol.response(request_id=42, result={"ok": True})
    assert env == {"jsonrpc": "2.0", "id": 42, "result": {"ok": True}}


def test_notification_envelope_helper():
    env = protocol.notification("turn/completed", {"usage": {}})
    assert env == {"jsonrpc": "2.0", "method": "turn/completed", "params": {"usage": {}}}


def test_error_envelope_helper():
    env = protocol.error(request_id=7, code=-32600, message="bad")
    assert env == {
        "jsonrpc": "2.0",
        "id": 7,
        "error": {"code": -32600, "message": "bad"},
    }
