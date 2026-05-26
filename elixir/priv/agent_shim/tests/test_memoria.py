import httpx
import pytest
import respx

from symphony_agent_shim.memoria import (
    MemoriaClient,
    build_memoria_tools,
    filter_sources_by_tag,
)


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
