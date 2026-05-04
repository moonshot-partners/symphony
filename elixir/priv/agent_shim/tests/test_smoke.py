def test_package_imports():
    import symphony_agent_shim

    assert symphony_agent_shim.__version__ == "0.1.0"
