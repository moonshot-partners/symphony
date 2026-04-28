import pytest

from symphony_agent_shim.server import run


def test_run_raises_not_implemented():
    with pytest.raises(NotImplementedError):
        run()
