import pytest

from symphony_agent_shim.auth import AuthError, resolve_auth_env


def test_oauth_token_takes_precedence(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_OAUTH_TOKEN", "sk-oauth-xyz")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-api-abc")
    env = resolve_auth_env()
    assert env["ANTHROPIC_OAUTH_TOKEN"] == "sk-oauth-xyz"
    assert "ANTHROPIC_API_KEY" not in env


def test_api_key_used_when_no_oauth(monkeypatch):
    monkeypatch.delenv("ANTHROPIC_OAUTH_TOKEN", raising=False)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-api-abc")
    env = resolve_auth_env()
    assert env["ANTHROPIC_API_KEY"] == "sk-api-abc"
    assert "ANTHROPIC_OAUTH_TOKEN" not in env


def test_no_creds_raises(monkeypatch):
    monkeypatch.delenv("ANTHROPIC_OAUTH_TOKEN", raising=False)
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    with pytest.raises(AuthError, match="no Anthropic credentials"):
        resolve_auth_env()
