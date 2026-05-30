"""Tests for symphony_agent_shim.tracing.

Fully deterministic: no network, no real Langfuse SDK calls. The enabled path
injects fake ``langfuse`` / ``openinference`` modules into ``sys.modules`` so
``setup()`` exercises its success branch without instrumenting the real SDK or
hitting the Langfuse API.
"""

import os
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
    monkeypatch.delenv("LANGFUSE_CAPTURE_IO", raising=False)
    monkeypatch.delenv("LANGFUSE_TRACING_ENVIRONMENT", raising=False)
    monkeypatch.delenv("OTEL_SERVICE_NAME", raising=False)
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


def _install_fake_langfuse(*, client, recorder=None, raise_on_import=False, propagate_factory=None):
    """Inject fake ``langfuse`` + ``openinference`` modules into sys.modules.

    ``recorder`` (a list) captures the kwargs passed to ``propagate_attributes``.
    ``propagate_factory`` overrides the default ``propagate_attributes`` so a
    test can inject one that raises on enter/exit.
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

    lf.propagate_attributes = propagate_factory or fake_propagate_attributes
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
        self.observations: list[dict] = []

    def flush(self):
        self.flushed += 1

    @contextmanager
    def start_as_current_observation(self, **kwargs):
        obs = _FakeObservation(kwargs)
        self.observations.append({"start": kwargs, "updates": obs.updates})
        yield obs


class _FakeObservation:
    def __init__(self, kwargs):
        self.kwargs = kwargs
        self.updates: list[dict] = []

    def update(self, **kwargs):
        self.updates.append(kwargs)


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


class _FakeSpanContext:
    def __init__(self, trace_id):
        self.trace_id = trace_id


def _install_fake_otel(monkeypatch, *, span_context=None, raise_on_call=False):
    """Inject a fake ``opentelemetry`` module so current_trace_id() runs without
    a real tracer. ``span_context`` is returned by get_span_context();
    ``raise_on_call`` makes get_current_span() raise."""
    otel = types.ModuleType("opentelemetry")
    trace_mod = types.ModuleType("opentelemetry.trace")

    if raise_on_call:

        def _boom():
            raise RuntimeError("otel boom")

        trace_mod.get_current_span = _boom
    else:

        class _Span:
            def get_span_context(self):
                return span_context

        trace_mod.get_current_span = _Span
    otel.trace = trace_mod
    monkeypatch.setitem(sys.modules, "opentelemetry", otel)
    monkeypatch.setitem(sys.modules, "opentelemetry.trace", trace_mod)


def test_current_trace_id_none_when_disabled():
    assert tracing.enabled() is False
    assert tracing.current_trace_id() is None


def test_current_trace_id_formats_active_span_as_hex(monkeypatch):
    tracing._enabled = True
    _install_fake_otel(
        monkeypatch,
        span_context=_FakeSpanContext(0xC3E398DCAC560FF9301CCECFF37D3E58),
    )
    assert tracing.current_trace_id() == "c3e398dcac560ff9301ccecff37d3e58"


def test_current_trace_id_none_for_zero_trace(monkeypatch):
    tracing._enabled = True
    _install_fake_otel(monkeypatch, span_context=_FakeSpanContext(0))
    assert tracing.current_trace_id() is None


def test_current_trace_id_swallows_errors(monkeypatch):
    tracing._enabled = True
    _install_fake_otel(monkeypatch, raise_on_call=True)
    assert tracing.current_trace_id() is None


def test_setup_enables_and_instruments(monkeypatch):
    monkeypatch.setenv("LANGFUSE_PUBLIC_KEY", "test-public-key")
    monkeypatch.setenv("LANGFUSE_SECRET_KEY", "test-secret-key")
    client = _FakeClient()
    _install_fake_langfuse(client=client)

    assert tracing.setup() is True
    assert tracing.enabled() is True
    assert client.instrumented is True
    assert os.environ["OTEL_SERVICE_NAME"] == "symphony-agent-shim"
    assert os.environ["LANGFUSE_TRACING_ENVIRONMENT"] == "production"


def test_setup_is_idempotent(monkeypatch):
    monkeypatch.setenv("LANGFUSE_PUBLIC_KEY", "test-public-key")
    monkeypatch.setenv("LANGFUSE_SECRET_KEY", "test-secret-key")
    client = _FakeClient()
    _install_fake_langfuse(client=client)

    assert tracing.setup() is True
    # Second call returns True without re-instrumenting (would raise if it tried
    # to re-import the now-unchanged fake — we assert it short-circuits).
    client.instrumented = False
    assert tracing.setup() is True
    assert client.instrumented is False


def test_setup_failure_keeps_disabled(monkeypatch):
    monkeypatch.setenv("LANGFUSE_PUBLIC_KEY", "test-public-key")
    monkeypatch.setenv("LANGFUSE_SECRET_KEY", "test-secret-key")
    _install_fake_langfuse(client=None, raise_on_import=True)

    assert tracing.setup() is False
    assert tracing.enabled() is False


def test_turn_context_propagates_session_and_turn(monkeypatch):
    monkeypatch.setenv("LANGFUSE_PUBLIC_KEY", "test-public-key")
    monkeypatch.setenv("LANGFUSE_SECRET_KEY", "test-secret-key")
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
    assert recorder[0]["metadata"]["turnId"] == "turn-42"
    assert "symphony-agent" in recorder[0]["tags"]
    assert client.observations[0]["start"]["name"] == "symphony.turn"
    assert client.observations[0]["start"]["as_type"] == "agent"


def test_turn_context_records_thread_id_metadata(monkeypatch):
    """The ticket is the session id; the per-process thread id rides as metadata
    so a single attempt within a ticket's journey stays cross-referenceable."""
    monkeypatch.setenv("LANGFUSE_PUBLIC_KEY", "test-public-key")
    monkeypatch.setenv("LANGFUSE_SECRET_KEY", "test-secret-key")
    recorder: list[dict] = []
    client = _FakeClient()
    _install_fake_langfuse(client=client, recorder=recorder)
    assert tracing.setup() is True

    with tracing.turn_context(session_id="SODEV-430", turn_id="turn-1", thread_id="shim-abc"):
        pass

    assert recorder[0]["session_id"] == "SODEV-430"
    assert recorder[0]["metadata"]["threadId"] == "shim-abc"
    assert recorder[0]["metadata"]["turnId"] == "turn-1"


def test_operation_creates_named_observation_and_redacts_io(monkeypatch):
    monkeypatch.setenv("LANGFUSE_PUBLIC_KEY", "test-public-key")
    monkeypatch.setenv("LANGFUSE_SECRET_KEY", "test-secret-key")
    client = _FakeClient()
    _install_fake_langfuse(client=client)
    assert tracing.setup() is True

    with tracing.operation(
        "symphony.tool.bash",
        as_type="tool",
        metadata={"toolUseId": "tool-1", "bad_key!": "x"},
        input="echo $SECRET_TOKEN",
        output="done",
    ):
        pass

    assert client.observations[0]["start"]["name"] == "symphony.tool.bash"
    assert client.observations[0]["start"]["as_type"] == "tool"
    assert client.observations[0]["start"]["metadata"] == {"toolUseId": "tool-1", "badkey": "x"}
    assert client.observations[0]["start"]["input"] == {
        "redacted": True,
        "chars": 18,
        "preview": "<redacted>",
    }
    assert client.observations[0]["updates"] == [
        {"output": {"redacted": True, "chars": 4, "preview": "done"}}
    ]


def test_command_metadata_classifies_and_redacts_sensitive_commands():
    assert tracing.command_metadata("git push -u origin HEAD")["commandKind"] == "gitPush"
    assert tracing.command_metadata("CI=1 npm run e2e -- --project=anon")["commandKind"] == "qaE2e"
    meta = tracing.command_metadata("curl -H 'Authorization: Bearer abc' https://example")
    assert meta["commandKind"] == "shell"
    assert meta["redacted"] == "true"


def test_flush_calls_client_when_enabled(monkeypatch):
    monkeypatch.setenv("LANGFUSE_PUBLIC_KEY", "test-public-key")
    monkeypatch.setenv("LANGFUSE_SECRET_KEY", "test-secret-key")
    client = _FakeClient()
    _install_fake_langfuse(client=client)
    assert tracing.setup() is True

    tracing.flush()
    assert client.flushed == 1


def test_turn_context_yields_once_when_propagate_exit_raises(monkeypatch):
    """propagate_attributes.__exit__ raises in async contexts (OTel contextvars
    token detached in a different context). turn_context must still yield exactly
    once and must not propagate the error — otherwise the generator crashes the
    caller with 'generator didn't stop' and the agent turn is falsely failed."""
    monkeypatch.setenv("LANGFUSE_PUBLIC_KEY", "test-public-key")
    monkeypatch.setenv("LANGFUSE_SECRET_KEY", "test-secret-key")

    class RaisingExitPropagate:
        def __init__(self, **kwargs):
            self.kwargs = kwargs

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            raise ValueError("Token was created in a different Context")

    client = _FakeClient()
    _install_fake_langfuse(client=client, propagate_factory=RaisingExitPropagate)
    assert tracing.setup() is True

    ran = []
    # Must not raise, and the body must execute exactly once.
    with tracing.turn_context(session_id="shim-xyz", turn_id="turn-1"):
        ran.append(True)
    assert ran == [True]


def test_turn_context_yields_once_when_propagate_enter_raises(monkeypatch):
    """If propagate_attributes.__enter__ raises, turn_context degrades to an
    untraced passthrough: body runs once, no error escapes."""
    monkeypatch.setenv("LANGFUSE_PUBLIC_KEY", "test-public-key")
    monkeypatch.setenv("LANGFUSE_SECRET_KEY", "test-secret-key")

    class RaisingEnterPropagate:
        def __init__(self, **kwargs):
            pass

        def __enter__(self):
            raise RuntimeError("enter boom")

        def __exit__(self, *exc):
            return False

    client = _FakeClient()
    _install_fake_langfuse(client=client, propagate_factory=RaisingEnterPropagate)
    assert tracing.setup() is True

    ran = []
    with tracing.turn_context(session_id="shim-xyz", turn_id="turn-1"):
        ran.append(True)
    assert ran == [True]
