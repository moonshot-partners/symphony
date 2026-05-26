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

import json
import logging
from typing import Any

import httpx

DEFAULT_BASE_URL = "https://memoria.moonshot-apps.com"
DEFAULT_TIMEOUT_S = 5.0

logger = logging.getLogger(__name__)

CROSS_CUTTING_TAG = "moonshot"


def filter_sources_by_tag(
    sources: list[dict[str, Any]], *, project_tag: str
) -> list[dict[str, Any]]:
    """Drop sources whose tags don't match project_tag or cross-cutting tag.

    Memoria's server-side project_id filter leaks across shared Slack workspaces
    (confirmed empirically: a Schools Out query returned team-wizard-dev sources).
    This function is the only airtight scope.
    """
    if not project_tag:
        return sources
    kept = []
    for source in sources:
        raw_tags = source.get("tags")
        try:
            tags = json.loads(raw_tags) if isinstance(raw_tags, str) else []
        except (TypeError, ValueError):
            logger.debug("dropping source with malformed tags: %r", raw_tags)
            continue
        if project_tag in tags or CROSS_CUTTING_TAG in tags:
            kept.append(source)
    return kept


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
        last_error = "memoria_unavailable"
        max_attempts = 2  # initial + 1 retry on 5xx/network
        for _attempt in range(max_attempts):
            try:
                async with httpx.AsyncClient(timeout=self._timeout_s) as http:
                    response = await http.get(url, params=params, headers=headers)
                if 200 <= response.status_code < 300:
                    return response.json()
                if 400 <= response.status_code < 500:
                    return {**empty_shape, "error": f"memoria_http_{response.status_code}"}
                last_error = f"memoria_http_{response.status_code}"
            except (httpx.TimeoutException, httpx.TransportError) as exc:
                last_error = f"memoria_network_{type(exc).__name__}"
        return {**empty_shape, "error": last_error}
