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


def teardown_module(_module):
    sys.modules.pop("smoke_real", None)
