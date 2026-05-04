"""Anthropic auth resolution.

Precedence:
1. ``ANTHROPIC_OAUTH_TOKEN`` — Claude Code subscription token (local only)
2. ``ANTHROPIC_API_KEY`` — standard API key

The SDK reads these from the subprocess environment. We forward whichever
is set so the SDK's internal CLI subprocess inherits it.
"""

import os


class AuthError(RuntimeError):
    pass


def resolve_auth_env() -> dict[str, str]:
    oauth = os.environ.get("ANTHROPIC_OAUTH_TOKEN")
    if oauth:
        return {"ANTHROPIC_OAUTH_TOKEN": oauth}
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if api_key:
        return {"ANTHROPIC_API_KEY": api_key}
    raise AuthError("no Anthropic credentials: set ANTHROPIC_OAUTH_TOKEN or ANTHROPIC_API_KEY")
