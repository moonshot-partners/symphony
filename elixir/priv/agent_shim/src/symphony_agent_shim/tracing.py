"""Optional Langfuse tracing for the agent shim.

When ``LANGFUSE_PUBLIC_KEY`` and ``LANGFUSE_SECRET_KEY`` are present in the
shim process environment, every Claude Agent SDK turn is traced to Langfuse via
the OpenInference OpenTelemetry instrumentor: per-API-call generations, tool
calls, token usage, model, and latency form one span tree per turn. Absent the
keys, every function here is a no-op, so local runs and tests need zero
Langfuse setup.

A tracing failure must NEVER propagate into the agent loop. ``setup`` and
``flush`` swallow errors and leave tracing disabled on fault; ``turn_context``
degrades to a plain passthrough.

Credentials are read from the environment (inherited from the Symphony
orchestrator process), never hardcoded. ``LANGFUSE_BASE_URL`` selects the
region/instance and defaults to EU cloud inside the Langfuse SDK.
"""

from __future__ import annotations

import logging
import os
from collections.abc import Iterator
from contextlib import contextmanager
from typing import Any

logger = logging.getLogger(__name__)

_enabled = False
_client: Any = None


def enabled() -> bool:
    return _enabled


def _has_keys() -> bool:
    return bool(os.environ.get("LANGFUSE_PUBLIC_KEY")) and bool(
        os.environ.get("LANGFUSE_SECRET_KEY")
    )


def setup() -> bool:
    """Initialize Langfuse + OpenInference instrumentation once. Idempotent.

    Returns ``True`` when tracing is active. Returns ``False`` (no-op) when the
    keys are absent or initialization fails — the shim keeps running untraced.

    No network call is made here: ``instrument()`` only monkeypatches the SDK
    in-process, so shim boot never blocks on Langfuse availability. Trace export
    happens asynchronously in the background and any auth/transport failure is
    surfaced by the Langfuse SDK's own logging, not here.
    """
    global _enabled, _client
    if _enabled:
        return True
    if not _has_keys():
        logger.debug("Langfuse keys absent; tracing disabled")
        return False
    try:
        from langfuse import get_client
        from openinference.instrumentation.claude_agent_sdk import (
            ClaudeAgentSDKInstrumentor,
        )

        ClaudeAgentSDKInstrumentor().instrument()
        _client = get_client()
        _enabled = True
        logger.info("Langfuse tracing enabled")
        return True
    except Exception as exc:  # noqa: BLE001 — tracing must never crash the shim
        logger.warning("Langfuse tracing setup failed: %s", exc)
        return False


@contextmanager
def turn_context(*, session_id: str, turn_id: str) -> Iterator[None]:
    """Attach session/turn attributes to all spans created within the block.

    ``session_id`` groups every turn of one agent thread into a Langfuse
    Session. No-op passthrough when tracing is disabled.
    """
    if not _enabled:
        yield
        return
    try:
        from langfuse import propagate_attributes

        with propagate_attributes(
            session_id=session_id,
            tags=["symphony-agent"],
            metadata={"turn_id": turn_id},
        ):
            yield
    except Exception as exc:  # noqa: BLE001 — tracing must never crash the shim
        logger.warning("Langfuse turn_context failed: %s", exc)
        yield


def flush() -> None:
    """Force-export buffered spans. Safe to call when tracing is disabled."""
    if not _enabled or _client is None:
        return
    try:
        _client.flush()
    except Exception as exc:  # noqa: BLE001 — flush failure must not crash shutdown
        logger.debug("Langfuse flush failed: %s", exc)
