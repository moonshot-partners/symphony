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
def turn_context(*, session_id: str, turn_id: str, thread_id: str | None = None) -> Iterator[None]:
    """Attach session/turn attributes to all spans created within the block.

    ``session_id`` is the Linear ticket (e.g. ``SODEV-430``) so every turn and
    every re-dispatch of one ticket groups into a single Langfuse Session —
    the whole journey of a ticket in one view. ``thread_id`` (the per-process
    shim id) is recorded as metadata to cross-reference a single attempt.
    No-op passthrough when tracing is disabled.
    """
    if not _enabled:
        yield
        return

    # Drive propagate_attributes by hand instead of `with ...: yield`. As a
    # generator-based context manager, turn_context MUST yield exactly once: a
    # `with propagate_attributes(): yield` wrapped in try/except would yield a
    # second time if `__exit__` raised, crashing the caller with "generator
    # didn't stop". And `__exit__` *does* raise here — propagate_attributes sets
    # an OTel contextvars Baggage token, and the Claude Agent SDK drives the
    # response stream across anyio task groups, so the detach token can be
    # reset in a different context ("Token was created in a different Context").
    # Entering/exiting manually with isolated error handling keeps the single
    # yield invariant and turns any propagation failure into an untraced-but-
    # working turn rather than a failed one.
    cm = None
    try:
        from langfuse import propagate_attributes

        metadata = {"turn_id": turn_id}
        if thread_id:
            metadata["thread_id"] = thread_id
        cm = propagate_attributes(
            session_id=session_id,
            tags=["symphony-agent"],
            metadata=metadata,
        )
        cm.__enter__()
    except Exception as exc:  # noqa: BLE001 — tracing must never crash the shim
        logger.debug("Langfuse turn_context enter failed: %s", exc)
        cm = None

    try:
        yield
    finally:
        if cm is not None:
            try:
                cm.__exit__(None, None, None)
            except Exception as exc:  # noqa: BLE001 — exit must never crash the turn
                logger.debug("Langfuse turn_context exit failed: %s", exc)


def flush() -> None:
    """Force-export buffered spans. Safe to call when tracing is disabled."""
    if not _enabled or _client is None:
        return
    try:
        _client.flush()
    except Exception as exc:  # noqa: BLE001 — flush failure must not crash shutdown
        logger.debug("Langfuse flush failed: %s", exc)
