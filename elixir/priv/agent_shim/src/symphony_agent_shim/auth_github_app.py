"""GitHub App authentication.

Mints short-lived installation tokens for the orchestrator's `symphony-orchestrator`
App so the agent's git/gh subprocesses author commits and PRs as
`symphony-orchestrator[bot]` instead of the operator's personal identity.

Flow:
1. Read APP_ID + private key + INSTALLATION_ID from env (or arguments).
2. Sign an App-level JWT (RS256, 10min expiry, ``iss`` = APP_ID).
3. Exchange the JWT for an installation token via
   ``POST /app/installations/{id}/access_tokens``.
4. Cache the resulting token in-memory until 5min before its real expiry
   (GitHub gives 1h; we serve a fresh one at 55min to leave slack).

Fallback: if any of the three env vars is missing, ``resolve_git_env`` returns
the operator's existing ``GH_TOKEN`` (or empty), so older runs keep working
without requiring the App.
"""

from __future__ import annotations

import json
import os
import threading
import time
import urllib.error
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

import jwt

_HttpPost = Callable[[str, dict[str, str], bytes], tuple[str, int]]
_HttpGet = Callable[[str, dict[str, str]], tuple[str, int]]

GITHUB_API = "https://api.github.com"

APP_ID_ENV = "SYMPHONY_GITHUB_APP_ID"
INSTALLATION_ID_ENV = "SYMPHONY_GITHUB_APP_INSTALLATION_ID"
PRIVATE_KEY_PATH_ENV = "SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH"

# GitHub installation tokens live 1h. Refresh at 55min so callers never see
# a token within 5min of expiry — buys headroom for slow git pushes.
INSTALLATION_TOKEN_TTL_SECONDS = 55 * 60

# App JWTs may live up to 10min; we use 9min to dodge clock skew rejections.
APP_JWT_TTL_SECONDS = 9 * 60


class GitHubAppAuthError(RuntimeError):
    pass


@dataclass(frozen=True)
class GitHubAppConfig:
    app_id: int
    installation_id: int
    private_key_pem: str

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> GitHubAppConfig | None:
        env = env if env is not None else dict(os.environ)
        app_id = env.get(APP_ID_ENV)
        installation_id = env.get(INSTALLATION_ID_ENV)
        key_path = env.get(PRIVATE_KEY_PATH_ENV)
        if not (app_id and installation_id and key_path):
            return None
        try:
            app_id_int = int(app_id)
            installation_id_int = int(installation_id)
        except ValueError as exc:
            raise GitHubAppAuthError(
                f"{APP_ID_ENV} and {INSTALLATION_ID_ENV} must be integers"
            ) from exc
        try:
            pem = Path(key_path).expanduser().read_text()
        except OSError as exc:
            raise GitHubAppAuthError(f"cannot read private key at {key_path}: {exc}") from exc
        if "BEGIN" not in pem or "PRIVATE KEY" not in pem:
            raise GitHubAppAuthError(f"{key_path} does not look like a PEM private key")
        return cls(
            app_id=app_id_int,
            installation_id=installation_id_int,
            private_key_pem=pem,
        )


def sign_app_jwt(
    config: GitHubAppConfig,
    *,
    now: int | None = None,
    ttl_seconds: int = APP_JWT_TTL_SECONDS,
) -> str:
    """Return a signed JWT identifying the App to GitHub."""

    issued_at = int(now) if now is not None else int(time.time())
    # iat backdated by 60s shields against clock skew; GitHub rejects iat in the future.
    payload = {
        "iat": issued_at - 60,
        "exp": issued_at + ttl_seconds,
        "iss": str(config.app_id),
    }
    return jwt.encode(payload, config.private_key_pem, algorithm="RS256")


def fetch_installation_token(
    config: GitHubAppConfig,
    *,
    http_post: _HttpPost | None = None,
    now: int | None = None,
) -> tuple[str, int]:
    """Exchange an App JWT for an installation token.

    Returns ``(token, expires_at_unix)``.

    ``http_post`` is injectable for tests. The default implementation uses
    ``urllib.request`` to avoid pulling httpx into the shim runtime path.
    """

    app_jwt = sign_app_jwt(config, now=now)
    url = f"{GITHUB_API}/app/installations/{config.installation_id}/access_tokens"
    headers = {
        "Authorization": f"Bearer {app_jwt}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "symphony-orchestrator-shim",
    }
    poster = http_post if http_post is not None else _default_post
    body, _status = poster(url, headers, b"")
    try:
        data = json.loads(body)
    except json.JSONDecodeError as exc:
        raise GitHubAppAuthError(
            f"GitHub returned non-JSON for installation token: {body[:200]!r}"
        ) from exc
    token = data.get("token")
    if not isinstance(token, str) or not token:
        raise GitHubAppAuthError(f"GitHub response missing 'token': {data}")
    base_now = int(now) if now is not None else int(time.time())
    return token, base_now + INSTALLATION_TOKEN_TTL_SECONDS


class InstallationTokenCache:
    """Process-local cache for the installation token.

    Thread-safe so concurrent agent turns don't each mint a fresh token. The
    shim is single-process, so there's no need to share across PIDs.
    """

    def __init__(
        self,
        config: GitHubAppConfig,
        *,
        fetcher=fetch_installation_token,
        clock=time.time,
    ) -> None:
        self._config = config
        self._fetcher = fetcher
        self._clock = clock
        self._lock = threading.Lock()
        self._token: str | None = None
        self._expires_at: int = 0

    def get_token(self) -> str:
        with self._lock:
            now = int(self._clock())
            if self._token is not None and now < self._expires_at:
                return self._token
            token, expires_at = self._fetcher(self._config, now=now)
            self._token = token
            self._expires_at = expires_at
            return token


def _default_post(url: str, headers: dict[str, str], body: bytes) -> tuple[str, int]:
    request = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            payload = response.read().decode("utf-8")
            return payload, response.status
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise GitHubAppAuthError(f"GitHub HTTP {exc.code} on {url}: {detail[:300]}") from exc
    except urllib.error.URLError as exc:
        raise GitHubAppAuthError(f"network error talking to GitHub: {exc}") from exc


def _default_get(url: str, headers: dict[str, str]) -> tuple[str, int]:
    request = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.read().decode("utf-8"), response.status
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise GitHubAppAuthError(f"GitHub HTTP {exc.code} on {url}: {detail[:300]}") from exc
    except urllib.error.URLError as exc:
        raise GitHubAppAuthError(f"network error talking to GitHub: {exc}") from exc


def discover_installation_id(
    config: GitHubAppConfig,
    *,
    org: str,
    repo: str | None = None,
    http_get: _HttpGet | None = None,
    now: int | None = None,
) -> int:
    """Return the installation_id for the App in ``org`` (optionally ``repo``).

    Used by the bootstrap CLI after the operator approves the install: we mint
    an App JWT, query GitHub for the installation that matches, and persist
    its id to the env file so subsequent runs do not need to rediscover.
    """

    if not org:
        raise ValueError("org is required")
    app_jwt = sign_app_jwt(config, now=now)
    if repo:
        url = f"{GITHUB_API}/repos/{org}/{repo}/installation"
    else:
        url = f"{GITHUB_API}/orgs/{org}/installation"
    headers = {
        "Authorization": f"Bearer {app_jwt}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "symphony-orchestrator-shim",
    }
    getter = http_get if http_get is not None else _default_get
    body, _status = getter(url, headers)
    try:
        data = json.loads(body)
    except json.JSONDecodeError as exc:
        raise GitHubAppAuthError(
            f"GitHub returned non-JSON for installation lookup: {body[:200]!r}"
        ) from exc
    install_id = data.get("id")
    if not isinstance(install_id, int):
        raise GitHubAppAuthError(f"GitHub response missing 'id': {data}")
    return install_id


# Process-level cache so successive resolve_git_env calls reuse the same
# InstallationTokenCache instance — otherwise each thread.start() would mint a
# fresh installation token from GitHub, defeating the 55min in-memory cache.
_INSTALLATION_TOKEN_CACHES: dict[tuple[int, int], InstallationTokenCache] = {}
_INSTALLATION_TOKEN_CACHES_LOCK = threading.Lock()


def _get_default_cache(config: GitHubAppConfig) -> InstallationTokenCache:
    key = (config.app_id, config.installation_id)
    with _INSTALLATION_TOKEN_CACHES_LOCK:
        cache = _INSTALLATION_TOKEN_CACHES.get(key)
        if cache is None:
            cache = InstallationTokenCache(config)
            _INSTALLATION_TOKEN_CACHES[key] = cache
        return cache


def resolve_git_env(
    env: dict[str, str] | None = None,
    *,
    cache_factory: Callable[[GitHubAppConfig], InstallationTokenCache] | None = None,
) -> dict[str, str]:
    """Build the env dict to inject into the agent subprocess.

    Order of resolution:
    1. App config present → mint installation token, set ``GH_TOKEN`` +
       ``GITHUB_TOKEN`` to it.
    2. App config absent → fall back to operator's ``GH_TOKEN`` /
       ``GITHUB_TOKEN`` if either is set.
    3. Neither → return ``{}``; the agent will run without git auth and any
       ``git push`` will rely on the operator's git credential helper.

    ``cache_factory`` is for tests; when omitted the module-level cache is
    used so successive calls share the in-memory token state.
    """

    env = env if env is not None else dict(os.environ)
    config = GitHubAppConfig.from_env(env)
    if config is not None:
        cache = cache_factory(config) if cache_factory is not None else _get_default_cache(config)
        token = cache.get_token()
        return {"GH_TOKEN": token, "GITHUB_TOKEN": token, "SYMPHONY_GITHUB_APP_ACTIVE": "1"}
    pat = env.get("GH_TOKEN") or env.get("GITHUB_TOKEN")
    if pat:
        return {"GH_TOKEN": pat, "GITHUB_TOKEN": pat}
    return {}
