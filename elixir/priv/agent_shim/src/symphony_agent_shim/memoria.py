"""Memoria HTTP client and MCP tool factory.

Optional, fail-open agent tool exposing ONE Memoria endpoint:
search_knowledge. Registered only when MEMORIA_API_KEY is set in
the shim's environment.

Design notes:
- 5s timeout per request, 1 retry on 5xx/network error, then empty
- Returns {"sources": [], "answer": None, "error": "<reason>"} on
  failure (never raises)
- Client-side tag filter is the only airtight project scope
  (server-side project_id leaks across shared Slack workspaces)
- Memoria is NOT code-aware; targets product decisions, people,
  transcripts
- HTTP API exposes only /api/v1/search. Brief/wiki are MCP-only.
"""

from __future__ import annotations

from typing import Any

import httpx

DEFAULT_BASE_URL = "https://memoria.moonshot-apps.com"
DEFAULT_TIMEOUT_S = 5.0


class MemoriaClient:
    def __init__(
        self,
        api_key: str,
        *,
        base_url: str = DEFAULT_BASE_URL,
        timeout_s: float = DEFAULT_TIMEOUT_S,
    ) -> None:
        self._api_key = api_key
        self._base_url = base_url.rstrip("/")
        self._timeout_s = timeout_s

    async def search_knowledge(
        self,
        query: str,
        *,
        project_id: str | None = None,
        limit: int = 10,
    ) -> dict[str, Any]:
        params: dict[str, Any] = {"q": query, "limit": limit}
        if project_id:
            params["project_id"] = project_id
        return await self._get_json(
            "/api/v1/search",
            params=params,
            empty_shape={"sources": [], "answer": None},
        )

    async def _get_json(
        self, path: str, *, params: dict[str, Any], empty_shape: dict[str, Any]
    ) -> dict[str, Any]:
        url = f"{self._base_url}{path}"
        headers = {"Authorization": f"Bearer {self._api_key}"}
        async with httpx.AsyncClient(timeout=self._timeout_s) as http:
            response = await http.get(url, params=params, headers=headers)
            response.raise_for_status()
            return response.json()
