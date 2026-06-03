from symphony_agent_shim.guardrails import build_default_hooks


def test_custom_hooks_disabled_by_default(monkeypatch):
    monkeypatch.delenv("SYMPHONY_ENABLE_AGENT_HOOKS", raising=False)

    assert build_default_hooks() == {}


def test_can_enable_one_custom_hook(monkeypatch):
    monkeypatch.setenv("SYMPHONY_ENABLE_AGENT_HOOKS", "bash_policy")

    hooks = build_default_hooks()

    assert list(hooks) == ["PreToolUse"]
    assert len(hooks["PreToolUse"]) == 1
    assert hooks["PreToolUse"][0].matcher == "Bash"


def test_can_enable_all_custom_hooks(monkeypatch):
    monkeypatch.setenv("SYMPHONY_ENABLE_AGENT_HOOKS", "all")

    hooks = build_default_hooks()

    assert len(hooks["PreToolUse"]) == 8
    assert len(hooks["PostToolUse"]) == 2
