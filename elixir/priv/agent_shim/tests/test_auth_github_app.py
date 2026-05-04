"""Tests for GitHub App auth: JWT signing, token cache, env resolution."""

from __future__ import annotations

import json
from pathlib import Path

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

from symphony_agent_shim import auth_github_app as gha


@pytest.fixture
def rsa_private_pem() -> str:
    """Generate an ephemeral 2048-bit RSA private key in PEM."""
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    return pem.decode("utf-8")


@pytest.fixture
def rsa_public_pem(rsa_private_pem: str) -> str:
    private = serialization.load_pem_private_key(rsa_private_pem.encode("utf-8"), password=None)
    public = private.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    return public.decode("utf-8")


@pytest.fixture
def app_config(rsa_private_pem: str) -> gha.GitHubAppConfig:
    return gha.GitHubAppConfig(
        app_id=12345,
        installation_id=67890,
        private_key_pem=rsa_private_pem,
    )


@pytest.fixture
def key_file(tmp_path: Path, rsa_private_pem: str) -> Path:
    path = tmp_path / "github-app.pem"
    path.write_text(rsa_private_pem)
    path.chmod(0o600)
    return path


# --- GitHubAppConfig.from_env ---


def test_from_env_returns_config_when_all_vars_set(key_file: Path) -> None:
    env = {
        gha.APP_ID_ENV: "12345",
        gha.INSTALLATION_ID_ENV: "67890",
        gha.PRIVATE_KEY_PATH_ENV: str(key_file),
    }
    cfg = gha.GitHubAppConfig.from_env(env)
    assert cfg is not None
    assert cfg.app_id == 12345
    assert cfg.installation_id == 67890
    assert "PRIVATE KEY" in cfg.private_key_pem


def test_from_env_returns_none_when_any_var_missing(key_file: Path) -> None:
    base = {
        gha.APP_ID_ENV: "12345",
        gha.INSTALLATION_ID_ENV: "67890",
        gha.PRIVATE_KEY_PATH_ENV: str(key_file),
    }
    for missing in base:
        partial = {k: v for k, v in base.items() if k != missing}
        assert gha.GitHubAppConfig.from_env(partial) is None


def test_from_env_rejects_non_integer_ids(key_file: Path) -> None:
    env = {
        gha.APP_ID_ENV: "not-a-number",
        gha.INSTALLATION_ID_ENV: "67890",
        gha.PRIVATE_KEY_PATH_ENV: str(key_file),
    }
    with pytest.raises(gha.GitHubAppAuthError, match="must be integers"):
        gha.GitHubAppConfig.from_env(env)


def test_from_env_rejects_unreadable_key(tmp_path: Path) -> None:
    env = {
        gha.APP_ID_ENV: "1",
        gha.INSTALLATION_ID_ENV: "2",
        gha.PRIVATE_KEY_PATH_ENV: str(tmp_path / "missing.pem"),
    }
    with pytest.raises(gha.GitHubAppAuthError, match="cannot read private key"):
        gha.GitHubAppConfig.from_env(env)


def test_from_env_rejects_non_pem_content(tmp_path: Path) -> None:
    bad = tmp_path / "not-a-key.pem"
    bad.write_text("just some text")
    env = {
        gha.APP_ID_ENV: "1",
        gha.INSTALLATION_ID_ENV: "2",
        gha.PRIVATE_KEY_PATH_ENV: str(bad),
    }
    with pytest.raises(gha.GitHubAppAuthError, match="does not look like a PEM"):
        gha.GitHubAppConfig.from_env(env)


# --- sign_app_jwt ---


def test_sign_app_jwt_has_correct_claims(
    app_config: gha.GitHubAppConfig, rsa_public_pem: str
) -> None:
    token = gha.sign_app_jwt(app_config, now=1_700_000_000)
    decoded = jwt.decode(
        token,
        rsa_public_pem,
        algorithms=["RS256"],
        options={"verify_exp": False, "verify_iat": False},
    )
    assert decoded["iss"] == "12345"
    assert decoded["iat"] == 1_700_000_000 - 60  # backdated for clock skew
    assert decoded["exp"] == 1_700_000_000 + gha.APP_JWT_TTL_SECONDS


def test_sign_app_jwt_uses_current_time_when_now_omitted(
    app_config: gha.GitHubAppConfig, rsa_public_pem: str
) -> None:
    token = gha.sign_app_jwt(app_config)
    decoded = jwt.decode(token, rsa_public_pem, algorithms=["RS256"])
    # iat is now-60, exp is now+9min: just verify the spread is ~ttl+60
    spread = decoded["exp"] - decoded["iat"]
    assert spread == gha.APP_JWT_TTL_SECONDS + 60


# --- fetch_installation_token ---


def test_fetch_installation_token_posts_to_correct_url_with_jwt_auth(
    app_config: gha.GitHubAppConfig, rsa_public_pem: str
) -> None:
    captured: dict = {}

    def fake_post(url: str, headers: dict, body: bytes) -> tuple[str, int]:
        captured["url"] = url
        captured["headers"] = headers
        captured["body"] = body
        return json.dumps({"token": "ghs_fake", "expires_at": "..."}), 201

    token, expires_at = gha.fetch_installation_token(
        app_config, http_post=fake_post, now=1_700_000_000
    )

    assert token == "ghs_fake"
    assert expires_at == 1_700_000_000 + gha.INSTALLATION_TOKEN_TTL_SECONDS
    assert captured["url"].endswith("/app/installations/67890/access_tokens")
    auth = captured["headers"]["Authorization"]
    assert auth.startswith("Bearer ")
    decoded = jwt.decode(
        auth.removeprefix("Bearer "),
        rsa_public_pem,
        algorithms=["RS256"],
        options={"verify_exp": False, "verify_iat": False},
    )
    assert decoded["iss"] == "12345"


def test_fetch_installation_token_rejects_non_json(app_config: gha.GitHubAppConfig) -> None:
    def fake_post(url: str, headers: dict, body: bytes) -> tuple[str, int]:
        return "<html>down</html>", 502

    with pytest.raises(gha.GitHubAppAuthError, match="non-JSON"):
        gha.fetch_installation_token(app_config, http_post=fake_post)


def test_fetch_installation_token_rejects_missing_token_field(
    app_config: gha.GitHubAppConfig,
) -> None:
    def fake_post(url: str, headers: dict, body: bytes) -> tuple[str, int]:
        return json.dumps({"message": "bad credentials"}), 401

    with pytest.raises(gha.GitHubAppAuthError, match="missing 'token'"):
        gha.fetch_installation_token(app_config, http_post=fake_post)


# --- InstallationTokenCache ---


def test_token_cache_serves_cached_token_within_ttl(
    app_config: gha.GitHubAppConfig,
) -> None:
    calls = {"n": 0}

    def fake_fetch(config, *, now):
        calls["n"] += 1
        return f"ghs_v{calls['n']}", now + gha.INSTALLATION_TOKEN_TTL_SECONDS

    fake_clock = lambda: 1_700_000_000  # noqa: E731
    cache = gha.InstallationTokenCache(app_config, fetcher=fake_fetch, clock=fake_clock)

    assert cache.get_token() == "ghs_v1"
    assert cache.get_token() == "ghs_v1"
    assert cache.get_token() == "ghs_v1"
    assert calls["n"] == 1


def test_token_cache_refreshes_after_ttl_expires(
    app_config: gha.GitHubAppConfig,
) -> None:
    calls = {"n": 0}
    clock = {"t": 1_700_000_000}

    def fake_fetch(config, *, now):
        calls["n"] += 1
        return f"ghs_v{calls['n']}", now + 60  # short TTL for test

    cache = gha.InstallationTokenCache(app_config, fetcher=fake_fetch, clock=lambda: clock["t"])

    assert cache.get_token() == "ghs_v1"
    clock["t"] += 30
    assert cache.get_token() == "ghs_v1"
    clock["t"] += 60  # past expiry
    assert cache.get_token() == "ghs_v2"
    assert calls["n"] == 2


# --- resolve_git_env ---


def test_resolve_git_env_uses_app_token_when_configured(key_file: Path) -> None:
    env = {
        gha.APP_ID_ENV: "12345",
        gha.INSTALLATION_ID_ENV: "67890",
        gha.PRIVATE_KEY_PATH_ENV: str(key_file),
        "GH_TOKEN": "user_pat_should_be_overridden",
    }

    class FakeCache:
        def __init__(self, config):
            self.config = config

        def get_token(self) -> str:
            return "ghs_app_token"

    out = gha.resolve_git_env(env, cache_factory=FakeCache)
    assert out["GH_TOKEN"] == "ghs_app_token"
    assert out["GITHUB_TOKEN"] == "ghs_app_token"
    assert out["SYMPHONY_GITHUB_APP_ACTIVE"] == "1"


def test_resolve_git_env_falls_back_to_pat_when_app_absent() -> None:
    env = {"GH_TOKEN": "ghp_user_pat"}
    out = gha.resolve_git_env(env)
    assert out == {"GH_TOKEN": "ghp_user_pat", "GITHUB_TOKEN": "ghp_user_pat"}


def test_resolve_git_env_falls_back_to_github_token_when_only_that_set() -> None:
    env = {"GITHUB_TOKEN": "ghp_legacy"}
    out = gha.resolve_git_env(env)
    assert out == {"GH_TOKEN": "ghp_legacy", "GITHUB_TOKEN": "ghp_legacy"}


def test_resolve_git_env_returns_empty_when_nothing_configured() -> None:
    assert gha.resolve_git_env({}) == {}


def test_resolve_git_env_does_not_set_active_flag_for_pat_fallback() -> None:
    out = gha.resolve_git_env({"GH_TOKEN": "ghp_pat"})
    assert "SYMPHONY_GITHUB_APP_ACTIVE" not in out


def test_resolve_git_env_propagates_auth_error_when_app_vars_invalid(
    tmp_path: Path,
) -> None:
    bad_pem = tmp_path / "bad.pem"
    bad_pem.write_text("not a key")
    env = {
        gha.APP_ID_ENV: "12345",
        gha.INSTALLATION_ID_ENV: "67890",
        gha.PRIVATE_KEY_PATH_ENV: str(bad_pem),
    }
    with pytest.raises(gha.GitHubAppAuthError, match="does not look like a PEM"):
        gha.resolve_git_env(env)


def test_resolve_git_env_reuses_cache_across_calls(key_file: Path, monkeypatch) -> None:
    """Successive calls must share the same InstallationTokenCache, otherwise
    each thread.start() would mint a fresh installation token from GitHub."""

    monkeypatch.setattr(gha, "_INSTALLATION_TOKEN_CACHES", {})
    env = {
        gha.APP_ID_ENV: "12345",
        gha.INSTALLATION_ID_ENV: "67890",
        gha.PRIVATE_KEY_PATH_ENV: str(key_file),
    }
    calls = {"n": 0}

    def fake_fetch(config, *, now):
        calls["n"] += 1
        return f"ghs_v{calls['n']}", now + gha.INSTALLATION_TOKEN_TTL_SECONDS

    # Pre-seed the module cache with an InstallationTokenCache wired to our
    # fake fetcher; default _get_default_cache returns it on key match.
    cfg = gha.GitHubAppConfig.from_env(env)
    assert cfg is not None
    seeded = gha.InstallationTokenCache(cfg, fetcher=fake_fetch)
    gha._INSTALLATION_TOKEN_CACHES[(cfg.app_id, cfg.installation_id)] = seeded

    first = gha.resolve_git_env(env)
    second = gha.resolve_git_env(env)
    assert first["GH_TOKEN"] == second["GH_TOKEN"] == "ghs_v1"
    assert calls["n"] == 1


# --- discover_installation_id ---


def test_discover_installation_id_for_org(app_config: gha.GitHubAppConfig) -> None:
    captured: dict = {}

    def fake_get(url: str, headers: dict) -> tuple[str, int]:
        captured["url"] = url
        captured["headers"] = headers
        return json.dumps({"id": 99999}), 200

    install_id = gha.discover_installation_id(app_config, org="schoolsoutapp", http_get=fake_get)
    assert install_id == 99999
    assert captured["url"].endswith("/orgs/schoolsoutapp/installation")
    assert captured["headers"]["Authorization"].startswith("Bearer ")


def test_discover_installation_id_for_repo(app_config: gha.GitHubAppConfig) -> None:
    def fake_get(url: str, headers: dict) -> tuple[str, int]:
        assert url.endswith("/repos/schoolsoutapp/schools-out/installation")
        return json.dumps({"id": 11111}), 200

    install_id = gha.discover_installation_id(
        app_config, org="schoolsoutapp", repo="schools-out", http_get=fake_get
    )
    assert install_id == 11111


def test_discover_installation_id_rejects_missing_id_in_response(
    app_config: gha.GitHubAppConfig,
) -> None:
    def fake_get(url: str, headers: dict) -> tuple[str, int]:
        return json.dumps({"message": "Not Found"}), 404

    with pytest.raises(gha.GitHubAppAuthError, match="missing 'id'"):
        gha.discover_installation_id(app_config, org="acme", http_get=fake_get)


def test_discover_installation_id_requires_org() -> None:
    with pytest.raises(ValueError, match="org is required"):
        gha.discover_installation_id(
            gha.GitHubAppConfig(app_id=1, installation_id=2, private_key_pem="x"),
            org="",
        )
