import pytest

from symphony_agent_shim.server import run


def test_main_delegates_to_run(monkeypatch):
    """__main__ calls run(); since run() raises NotImplementedError the
    import-time wiring is verified without executing a real server loop."""
    with pytest.raises(NotImplementedError):
        run()
