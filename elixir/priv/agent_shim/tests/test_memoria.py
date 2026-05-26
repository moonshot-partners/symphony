import os
from unittest.mock import patch

import httpx
import pytest
import respx

from symphony_agent_shim.memoria import (
    MemoriaClient,
    build_memoria_tools,
    filter_sources_by_tag,
)
from symphony_agent_shim.tools import ToolBridge, build_mcp_server_from_specs


@respx.mock
@pytest.mark.asyncio
async def test_search_knowledge_returns_sources_for_valid_query():
    route = respx.get("https://memoria.moonshot-apps.com/api/v1/search").mock(
        return_value=httpx.Response(
            200,
            json={
                "answer": "Stripe wires booking automatically",
                "sources": [
                    {"id": 644, "title": "Vendor Booking Pilot", "tags": '["schools-out"]'}
                ],
            },
        )
    )

    client = MemoriaClient(api_key="test-key")
    result = await client.search_knowledge(
        "vendor onboarding",
        project_id="574d7d43-82b9-44ac-b2c2-a8dc93e84c8e",
    )

    assert result["answer"].startswith("Stripe")
    assert len(result["sources"]) == 1
    assert result["sources"][0]["id"] == 644
    assert result.get("error") is None
    # Verify the project_id param was passed server-side
    last_request = route.calls.last.request
    assert "project_id=574d7d43" in str(last_request.url)


@respx.mock
@pytest.mark.asyncio
async def test_search_knowledge_returns_empty_on_503_after_retry():
    route = respx.get("https://memoria.moonshot-apps.com/api/v1/search").mock(
        return_value=httpx.Response(503, json={"error": "Search unavailable"})
    )

    client = MemoriaClient(api_key="test-key")
    result = await client.search_knowledge("anything")

    assert result == {"sources": [], "answer": None, "error": "memoria_http_503"}
    assert route.call_count == 2  # first try + 1 retry


@respx.mock
@pytest.mark.asyncio
async def test_search_knowledge_returns_empty_on_404_no_retry():
    route = respx.get("https://memoria.moonshot-apps.com/api/v1/search").mock(
        return_value=httpx.Response(404, json={"error": "not found"})
    )

    client = MemoriaClient(api_key="test-key")
    result = await client.search_knowledge("anything")

    assert result == {"sources": [], "answer": None, "error": "memoria_http_404"}
    assert route.call_count == 1  # no retry on 4xx


@respx.mock
@pytest.mark.asyncio
async def test_search_knowledge_returns_empty_on_timeout():
    route = respx.get("https://memoria.moonshot-apps.com/api/v1/search").mock(
        side_effect=httpx.ReadTimeout("simulated timeout")
    )

    client = MemoriaClient(api_key="test-key")
    result = await client.search_knowledge("anything")

    assert result["sources"] == []
    assert result["answer"] is None
    assert result["error"].startswith("memoria_network_")
    assert route.call_count == 2  # 1 retry on network error


def test_filter_sources_by_tag_keeps_match():
    sources = [
        {"id": 1, "tags": '["schools-out", "engineering"]'},
        {"id": 2, "tags": '["wizard", "engineering"]'},
        {"id": 3, "tags": '["moonshot", "internal"]'},
        {"id": 4, "tags": '[]'},
    ]
    kept = filter_sources_by_tag(sources, project_tag="schools-out")
    assert [s["id"] for s in kept] == [1, 3]  # tag match OR cross-cutting "moonshot"


def test_filter_sources_by_tag_handles_malformed_tags():
    sources = [
        {"id": 1, "tags": "not-json"},
        {"id": 2, "tags": None},
        {"id": 3},  # missing tags key
    ]
    kept = filter_sources_by_tag(sources, project_tag="schools-out")
    assert kept == []  # malformed → drop


def test_filter_sources_by_tag_no_filter_when_tag_empty():
    sources = [{"id": 1, "tags": '["anything"]'}]
    kept = filter_sources_by_tag(sources, project_tag="")
    assert kept == sources


def test_build_memoria_tools_returns_search_tool_when_api_key_set():
    tools = build_memoria_tools(
        api_key="some-key",
        project_id="574d7d43-82b9-44ac-b2c2-a8dc93e84c8e",
        project_tag="schools-out",
    )
    names = [t.name for t in tools]
    assert names == ["memoria.search_knowledge"]


def test_build_memoria_tools_returns_empty_when_api_key_missing():
    assert build_memoria_tools(api_key=None, project_id="x", project_tag="y") == []
    assert build_memoria_tools(api_key="", project_id="x", project_tag="y") == []


@pytest.mark.asyncio
async def test_build_mcp_server_includes_memoria_when_env_set():
    async def noop_writer(_: dict[str, object]) -> None:
        return None

    bridge = ToolBridge(noop_writer)

    env = {
        "MEMORIA_API_KEY": "test-key",
        "MEMORIA_PROJECT_ID": "574d7d43-82b9-44ac-b2c2-a8dc93e84c8e",
        "MEMORIA_PROJECT_TAG": "schools-out",
    }
    with patch.dict(os.environ, env, clear=False):
        server = build_mcp_server_from_specs([], bridge=bridge)

    # The Claude SDK MCP server stores tools internally; introspect to find them.
    # First try `_tools`, then `tools`, then `_tool_handlers` — adapt to actual shape.
    tool_names = _extract_tool_names(server)
    assert "memoria.search_knowledge" in tool_names


@pytest.mark.asyncio
async def test_build_mcp_server_excludes_memoria_when_env_unset():
    async def noop_writer(_: dict[str, object]) -> None:
        return None

    bridge = ToolBridge(noop_writer)

    # Clear ALL memoria env vars (don't touch unrelated env)
    cleared = {k: None for k in ("MEMORIA_API_KEY", "MEMORIA_PROJECT_ID", "MEMORIA_PROJECT_TAG")}
    with patch.dict(os.environ, {}, clear=False):
        for key in cleared:
            os.environ.pop(key, None)
        server = build_mcp_server_from_specs([], bridge=bridge)

    tool_names = _extract_tool_names(server)
    assert not any(n.startswith("memoria.") for n in tool_names)


def _extract_tool_names(server: object) -> list[str]:
    """Extract registered tool names from a create_sdk_mcp_server dict.

    The SDK returns {'type': 'sdk', 'name': ..., 'instance': mcp.server.Server}.
    Tools are stored in a closure on the `list_tools` async function registered
    via @server.list_tools() — but ONLY when tools is non-empty (the SDK skips
    handler registration entirely for an empty list).

    Strategy: find the ListToolsRequest handler; if absent, return [] (no tools
    registered). Otherwise walk: handler.__closure__[1] (lambda) ->
    .__closure__[0] (list_tools fn) -> .__closure__[0] (cached_tool_list).
    """
    import mcp.types

    inner = server["instance"] if isinstance(server, dict) else server
    lt_handler = inner.request_handlers.get(mcp.types.ListToolsRequest)
    if lt_handler is None:
        # SDK only registers the handler when tools != []; absence means zero tools.
        return []
    try:
        # handler -> closure[1]: create_call_wrapper lambda
        # lambda -> closure[0]: list_tools async fn
        # list_tools -> closure[0]: cached_tool_list (list[mcp.types.Tool])
        tools_list = (
            lt_handler
            .__closure__[1].cell_contents   # lambda wrapping list_tools
            .__closure__[0].cell_contents    # list_tools async fn
            .__closure__[0].cell_contents    # cached_tool_list
        )
    except (AttributeError, IndexError, TypeError, ValueError) as exc:
        raise AssertionError(f"could not navigate closure chain: {exc}") from exc
    if not isinstance(tools_list, list):
        raise AssertionError(f"expected list, got {type(tools_list)}: {tools_list!r}")
    return [t.name for t in tools_list]
