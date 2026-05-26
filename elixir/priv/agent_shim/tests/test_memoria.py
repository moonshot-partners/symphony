import httpx
import pytest
import respx

from symphony_agent_shim.memoria import MemoriaClient


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
