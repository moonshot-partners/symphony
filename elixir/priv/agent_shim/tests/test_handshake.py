import pytest

from symphony_agent_shim.handshake import handle_initialize


@pytest.mark.asyncio
async def test_initialize_returns_capabilities_envelope():
    request = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}
    reply = await handle_initialize(request)
    assert reply["id"] == 1
    assert "result" in reply
    assert reply["result"]["serverInfo"]["name"] == "symphony-agent-shim"
    assert reply["result"]["capabilities"]["experimentalApi"] is True


@pytest.mark.asyncio
async def test_initialize_preserves_request_id_type():
    request = {"jsonrpc": "2.0", "id": "abc", "method": "initialize"}
    reply = await handle_initialize(request)
    assert reply["id"] == "abc"


def test_is_initialized_notification_recognizes_method():
    from symphony_agent_shim.handshake import is_initialized_notification

    assert is_initialized_notification({"method": "initialized", "params": {}}) is True
    assert is_initialized_notification({"method": "thread/start"}) is False
    assert is_initialized_notification({"id": 1}) is False
