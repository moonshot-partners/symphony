"""Tests for scripts/smoke_real.py.

The script is an operator-driven end-to-end probe; we keep coverage to the
deterministic branches (auth resolution, env handling) — the actual subprocess
round-trip is exercised manually with real Anthropic credentials.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

SCRIPT_PATH = Path(__file__).resolve().parent / "smoke_real.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("smoke_real", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_main_returns_2_when_no_credentials(monkeypatch):
    monkeypatch.delenv("ANTHROPIC_OAUTH_TOKEN", raising=False)
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)

    smoke_real = _load_module()
    assert smoke_real.main() == 2


def test_main_imports_cleanly():
    smoke_real = _load_module()
    assert hasattr(smoke_real, "main")
    assert callable(smoke_real.main)


def test_thread_start_request_uses_camelcase_keys_and_carries_cwd():
    smoke_real = _load_module()
    req = smoke_real.build_thread_start_request(request_id=2, cwd="/tmp/work-x")

    assert req["jsonrpc"] == "2.0"
    assert req["id"] == 2
    assert req["method"] == "thread/start"
    params = req["params"]
    assert params["cwd"] == "/tmp/work-x"
    assert params["sandbox"] == "danger-full-access"
    assert params["approvalPolicy"] == "never"
    assert params["dynamicTools"] == []
    assert "approval_policy" not in params
    assert "dynamic_tools" not in params


def test_turn_start_request_uses_threadid_and_input_blocks():
    smoke_real = _load_module()
    req = smoke_real.build_turn_start_request(request_id=3, thread_id="shim-abc123", prompt="hi")

    assert req["method"] == "turn/start"
    params = req["params"]
    assert params["threadId"] == "shim-abc123"
    assert params["input"] == [{"type": "text", "text": "hi"}]
    assert "thread_id" not in params
    assert "prompt" not in params


def teardown_module(_module):
    sys.modules.pop("smoke_real", None)
