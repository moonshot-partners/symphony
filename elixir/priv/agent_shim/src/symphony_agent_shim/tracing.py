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

_SECRET_MARKERS = (
    "api_key",
    "apikey",
    "authorization",
    "cookie",
    "github_token",
    "gh_token",
    "langfuse_secret_key",
    "linear_api_key",
    "password",
    "private_key",
    "secret",
    "sk-",
    "token",
)


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

        os.environ.setdefault("OTEL_SERVICE_NAME", "symphony-agent-shim")
        os.environ.setdefault("LANGFUSE_TRACING_ENVIRONMENT", "production")

        ClaudeAgentSDKInstrumentor().instrument()
        _client = get_client()
        _enabled = True
        logger.info("Langfuse tracing enabled")
        return True
    except Exception as exc:  # noqa: BLE001 — tracing must never crash the shim
        logger.warning("Langfuse tracing setup failed: %s", exc)
        return False


@contextmanager
def turn_context(
    *,
    session_id: str,
    turn_id: str,
    thread_id: str | None = None,
    metadata: dict[str, Any] | None = None,
    input: Any = None,  # noqa: A002 - Langfuse uses this field name
) -> Iterator[None]:
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
    metadata = _clean_metadata(
        {
            "component": "agent_shim",
            "turnId": turn_id,
            "threadId": thread_id,
            **(metadata or {}),
        }
    )
    operation_name = "symphony.turn"
    span_cm = None
    cm = None
    try:
        from langfuse import propagate_attributes

        if _client is not None and hasattr(_client, "start_as_current_observation"):
            span_cm = _start_observation(
                as_type="agent",
                name=operation_name,
                input=_capture_io(input),
                metadata=metadata,
            )
            span_cm.__enter__()

        cm = propagate_attributes(
            session_id=session_id,
            tags=["symphony-agent", "symphony-turn"],
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
        if span_cm is not None:
            try:
                span_cm.__exit__(None, None, None)
            except Exception as exc:  # noqa: BLE001 — exit must never crash the turn
                logger.debug("Langfuse turn span exit failed: %s", exc)


@contextmanager
def operation(
    name: str,
    *,
    as_type: str = "span",
    metadata: dict[str, Any] | None = None,
    input: Any = None,  # noqa: A002 - Langfuse uses this field name
    output: Any = None,
) -> Iterator[None]:
    """Create a named Langfuse observation around Symphony-specific work.

    The OpenInference integration still captures SDK internals; these explicit
    observations add the operational markers Symphony needs for filtering and
    diagnosis (git push, QA, shell commands, turn stream phases).
    """
    if not _enabled or _client is None or not hasattr(_client, "start_as_current_observation"):
        yield
        return

    cm = None
    obs = None
    try:
        cm = _start_observation(
            as_type=as_type,
            name=name,
            input=_capture_io(input),
            metadata=_clean_metadata(metadata or {}),
        )
        obs = cm.__enter__()
    except Exception as exc:  # noqa: BLE001 — tracing must never crash the shim
        logger.debug("Langfuse operation enter failed name=%s error=%s", name, exc)
        cm = None

    try:
        yield
    finally:
        if obs is not None and output is not None:
            try:
                obs.update(output=_capture_io(output))
            except Exception as exc:  # noqa: BLE001 — tracing must never crash the shim
                logger.debug("Langfuse operation update failed name=%s error=%s", name, exc)
        if cm is not None:
            try:
                cm.__exit__(None, None, None)
            except Exception as exc:  # noqa: BLE001 — tracing must never crash the shim
                logger.debug("Langfuse operation exit failed name=%s error=%s", name, exc)


def flush() -> None:
    """Force-export buffered spans. Safe to call when tracing is disabled."""
    if not _enabled or _client is None:
        return
    try:
        _client.flush()
    except Exception as exc:  # noqa: BLE001 — flush failure must not crash shutdown
        logger.debug("Langfuse flush failed: %s", exc)


def command_metadata(command: str, *, cwd: str | None = None) -> dict[str, str]:
    return _clean_metadata(
        {
            "commandKind": _command_kind(command),
            "cwd": cwd,
            "redacted": "true" if _looks_sensitive(command) else "false",
        }
    )


def _start_observation(**kwargs):
    try:
        return _client.start_as_current_observation(**kwargs)
    except TypeError:
        # SDK argument support has changed across Langfuse v3/v4. Fall back to
        # the stable core fields and attach rich data through update() when the
        # context manager yields an observation.
        compact = {k: v for k, v in kwargs.items() if k in {"as_type", "name"}}
        return _client.start_as_current_observation(**compact)


def _capture_io(value: Any) -> Any:
    mode = os.environ.get("LANGFUSE_CAPTURE_IO", "redacted").strip().lower()
    if mode == "full":
        return value
    if mode == "off" or value is None:
        return None
    if isinstance(value, str):
        return {"redacted": True, "chars": len(value), "preview": _safe_preview(value)}
    if isinstance(value, dict):
        return {"redacted": True, "keys": sorted(map(str, value.keys()))[:20]}
    if isinstance(value, list):
        return {"redacted": True, "items": len(value)}
    return {"redacted": True, "type": type(value).__name__}


def _clean_metadata(metadata: dict[str, Any]) -> dict[str, str]:
    clean: dict[str, str] = {}
    for key, value in metadata.items():
        if value is None:
            continue
        clean_key = "".join(ch for ch in str(key) if ch.isalnum())[:80]
        if not clean_key:
            continue
        text = _safe_preview(str(value), limit=200)
        clean[clean_key] = text
    return clean


def _safe_preview(value: str, *, limit: int = 200) -> str:
    compact = " ".join(value.split())
    if _looks_sensitive(compact):
        return "<redacted>"
    return compact[:limit]


def _looks_sensitive(value: str) -> bool:
    lower = value.lower()
    return any(marker in lower for marker in _SECRET_MARKERS)


def _command_kind(command: str) -> str:
    stripped = command.strip()
    if stripped.startswith("git commit"):
        return "gitCommit"
    if stripped.startswith("git push"):
        return "gitPush"
    if stripped.startswith("gh pr create"):
        return "prCreate"
    if "npm run e2e" in stripped or "playwright" in stripped:
        return "qaE2e"
    if stripped.startswith("git "):
        return "git"
    if stripped.startswith(("npm test", "npx jest", "mix test", "pytest")):
        return "test"
    return "shell"
