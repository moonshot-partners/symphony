"""Tests for symphony_agent_shim.tracing.

Fully deterministic: no network, no real Langfuse SDK calls. The enabled path
injects fake ``langfuse`` / ``openinference`` modules into ``sys.modules`` so
``setup()`` exercises its success branch without instrumenting the real SDK or
hitting the Langfuse API.
"""

import sys
import types
from contextlib import contextmanager

import pytest

from symphony_agent_shim import tracing


@pytest.fixture(autouse=True)
def reset_tracing_state(monkeypatch):
    """Each test starts with tracing disabled and ends with module globals and
    any injected fake modules restored — no cross-test leakage."""
    monkeypatch.delenv("LANGFUSE_PUBLIC_KEY", raising=False)
    monkeypatch.delenv("LANGFUSE_SECRET_KEY", raising=False)
    tracing._enabled = False
    tracing._client = None
    saved_modules = {
        name: sys.modules.get(name)
        for name in (
            "langfuse",
            "openinference",
            "openinference.instrumentation",
            "openinference.instrumentation.claude_agent_sdk",
        )
    }
    yield
    tracing._enabled = False
    tracing._client = None
    for name, mod in saved_modules.items():
        if mod is None:
            sys.modules.pop(name, None)
        else:
            sys.modules[name] = mod


def _install_fake_langfuse(*, client, recorder=None, raise_on_import=False):
    """Inject fake ``langfuse`` + ``openinference`` modules into sys.modules.

    ``recorder`` (a list) captures the kwargs passed to ``propagate_attributes``.
    """
    if raise_on_import:
        broken = types.ModuleType("langfuse")

        def _boom():
            raise RuntimeError("langfuse import boom")

        broken.get_client = _boom
        sys.modules["langfuse"] = broken
        return

    lf = types.ModuleType("langfuse")
    lf.get_client = lambda: client

    @contextmanager
    def fake_propagate_attributes(**kwargs):
        if recorder is not None:
            recorder.append(kwargs)
        yield

    lf.propagate_attributes = fake_propagate_attributes
    sys.modules["langfuse"] = lf

    oi = types.ModuleType("openinference")
    oi_instr = types.ModuleType("openinference.instrumentation")
    oi_cas = types.ModuleType("openinference.instrumentation.claude_agent_sdk")

    class FakeInstrumentor:
        def instrument(self):
            client.instrumented = True

    oi_cas.ClaudeAgentSDKInstrumentor = FakeInstrumentor
    sys.modules["openinference"] = oi
    sys.modules["openinference.instrumentation"] = oi_instr
    sys.modules["openinference.instrumentation.claude_agent_sdk"] = oi_cas


class _FakeClient:
    def __init__(self):
        self.flushed = 0
        self.instrumented = False

    def flush(self):
        self.flushed += 1


def test_disabled_without_keys():
    assert tracing.enabled() is False
    assert tracing.setup() is False
    assert tracing.enabled() is False


def test_turn_context_passthrough_when_disabled():
    ran = []
    with tracing.turn_context(session_id="shim-abc", turn_id="turn-1"):
        ran.append(True)
    assert ran == [True]


def test_flush_noop_when_disabled():
    # Must not raise even though no client was ever created.
    assert tracing.flush() is None
    assert tracing.enabled() is False


def test_setup_enables_and_instruments(monkeypatch):
    monkeypatch.setenv("LANGFUSE_PUBLIC_KEY", "pk-lf-test")
    monkeypatch.setenv("LANGFUSE_SECRET_KEY", "sk-lf-test")
    client = _FakeClient()
    _install_fake_langfuse(client=client)

    assert tracing.setup() is True
    assert tracing.enabled() is True
    assert client.instrumented is True


def test_setup_is_idempotent(monkeypatch):
    monkeypatch.setenv("LANGFUSE_PUBLIC_KEY", "pk-lf-test")
    monkeypatch.setenv("LANGFUSE_SECRET_KEY", "sk-lf-test")
    client = _FakeClient()
    _install_fake_langfuse(client=client)

    assert tracing.setup() is True
    # Second call returns True without re-instrumenting (would raise if it tried
    # to re-import the now-unchanged fake — we assert it short-circuits).
    client.instrumented = False
    assert tracing.setup() is True
    assert client.instrumented is False


def test_setup_failure_keeps_disabled(monkeypatch):
    monkeypatch.setenv("LANGFUSE_PUBLIC_KEY", "pk-lf-test")
    monkeypatch.setenv("LANGFUSE_SECRET_KEY", "sk-lf-test")
    _install_fake_langfuse(client=None, raise_on_import=True)

    assert tracing.setup() is False
    assert tracing.enabled() is False


def test_turn_context_propagates_session_and_turn(monkeypatch):
    monkeypatch.setenv("LANGFUSE_PUBLIC_KEY", "pk-lf-test")
    monkeypatch.setenv("LANGFUSE_SECRET_KEY", "sk-lf-test")
    recorder: list[dict] = []
    client = _FakeClient()
    _install_fake_langfuse(client=client, recorder=recorder)
    assert tracing.setup() is True

    ran = []
    with tracing.turn_context(session_id="shim-xyz", turn_id="turn-42"):
        ran.append(True)

    assert ran == [True]
    assert len(recorder) == 1
    assert recorder[0]["session_id"] == "shim-xyz"
    assert recorder[0]["metadata"]["turn_id"] == "turn-42"
    assert "symphony-agent" in recorder[0]["tags"]


def test_flush_calls_client_when_enabled(monkeypatch):
    monkeypatch.setenv("LANGFUSE_PUBLIC_KEY", "pk-lf-test")
    monkeypatch.setenv("LANGFUSE_SECRET_KEY", "sk-lf-test")
    client = _FakeClient()
    _install_fake_langfuse(client=client)
    assert tracing.setup() is True

    tracing.flush()
    assert client.flushed == 1
